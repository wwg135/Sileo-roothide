//
//  RootlessConverter.swift
//  Sileo
//
//  Converts rootless (iphoneos-arm64) and rootful (iphoneos-arm) packages to
//  roothide (iphoneos-arm64e) on device. This is a native port of the
//  roothide Patcher's patch.sh (Compat Layer / AutoPatches mode).
//

import Foundation

enum RootlessConverter {
    private struct FileMetadata {
        let relativePath: String
        let permissions: Int
        let owner: UInt32
        let group: UInt32
        let isDirectory: Bool
        let isSymbolicLink: Bool
    }

    enum Failure: LocalizedError {
        case notConvertible
        case unsupportedArchitecture(String)
        case missingTool(String)
        case step(String, String)
        case binary(String, String)

        var errorDescription: String? {
            switch self {
            case .notConvertible:
                return String(localizationKey: "Compat_Not_Convertible")
            case .unsupportedArchitecture(let arch):
                return String(format: String(localizationKey: "Compat_Unsupported_Arch"), arch)
            case .missingTool(let tool):
                return String(format: String(localizationKey: "Compat_Tool_Missing"), tool)
            case .step(let step, let detail):
                return detail.isEmpty ? step : "\(step): \(detail)"
            case .binary(let path, let detail):
                return "\(path): \(detail)"
            }
        }
    }

    private static let incompatiblePackages = [
        "xinam1ne", "xinamine", "legizmo", "vnodebypass", "voicechangerx-rootless", "appsyncunified",
        "choicy", "com.tigisoftware.filza", "sileo", "zebra", "com.opa334.ccsupport", "ws.hbang.common",
        "libsandy", "preferenceloader", "newterm3", "altlist"
    ]
    private static let notTweaks = ["ellekit", "oldabi"]
    private static let compatLayer = "rootless-compat(>= 0.9)"
    private static let mirrorRelativePath = "var/mobile/Library/pkgmirror"
    private static let maintainerScripts: Set<String> = ["preinst", "prerm", "postinst", "postrm", "extrainst_"]
    private static let excludedSuffixes = [".png", ".gif", ".jpg", ".jpeg", ".svg", ".strings", ".js", ".py", ".h", ".json", ".txt", ".xml"]
    private static let entitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>platform-application</key>
        <true/>
        <key>com.apple.private.security.no-sandbox</key>
        <true/>
        <key>com.apple.private.security.storage.AppBundles</key>
        <true/>
        <key>com.apple.private.security.storage.AppDataContainers</key>
        <true/>
    </dict>
    </plist>
    """

    static func isConvertible(package: Package) -> Bool {
        guard let architecture = package.architecture,
              [DPKGArchitecture.Architecture.rootless.rawValue, DPKGArchitecture.Architecture.rootful.rawValue].contains(architecture)
        else { return false }
        return isConvertible(identifier: package.package, maintainer: package.rawControl["maintainer"])
    }

    private static func isConvertible(identifier: String, maintainer: String?) -> Bool {
        if notTweaks.contains(identifier) || maintainer == "Procursus Team <support@procurs.us>" {
            return false
        }
        return !incompatiblePackages.contains { identifier.contains($0) }
    }

    /// Converts `deb` into a roothide package written to `output`. Blocking; call off the main thread.
    static func convert(deb: URL, to output: URL) throws {
        let fm = FileManager.default
        let ldid = CommandPath.prefix + "/usr/bin/ldid"
        guard fm.fileExists(atPath: ldid) else { throw Failure.missingTool("ldid") }

        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: nil)
        // the tree is root-owned when done, so it is removed as root
        defer { spawn(command: CommandPath.rm, args: ["rm", "-rf", rootfs(work.path)], root: true) }

        let old = work.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true, attributes: nil)

        try run(CommandPath.dpkgdeb, ["dpkg-deb", "-R", rootfs(deb.path), rootfs(old.path)], root: true)
        let originalMetadata = try readMetadata(at: old)
        let archiveOwners = readArchiveOwners(of: deb)
        let owner = "\(getuid()):\(getgid())"
        try run(CommandPath.chown, ["chown", "-R", owner, rootfs(old.path)], root: true)

        let controlURL = old.appendingPathComponent("DEBIAN/control")
        let control = try readText(controlURL)
        guard let identifier = field("Package", in: control), !identifier.isEmpty, !identifier.contains("/"),
              let architecture = field("Architecture", in: control)
        else { throw Failure.step("DEBIAN/control", "") }
        guard isConvertible(identifier: identifier, maintainer: field("Maintainer", in: control)) else {
            throw Failure.notConvertible
        }

        let mode: MachOPatcher.Mode
        switch architecture {
        case "iphoneos-arm64": mode = .rootless
        case "iphoneos-arm": mode = .rootful
        default: throw Failure.unsupportedArchitecture(architecture)
        }

        let root: URL
        if mode == .rootless {
            root = try relocateRootless(old: old, work: work, identifier: identifier)
        } else {
            root = old
        }

        // Temporarily make every entry writable while retaining the archive metadata above.
        if let enumerator = fm.enumerator(atPath: root.path) {
            while let relative = enumerator.nextObject() as? String {
                if relative == mirrorRelativePath {
                    enumerator.skipDescendants()
                    continue
                }
                let full = root.path + "/" + relative
                let attributes = try fm.attributesOfItem(atPath: full)
                guard let type = attributes[.type] as? FileAttributeType,
                      type == .typeRegular || type == .typeDirectory,
                      var current = (attributes[.posixPermissions] as? NSNumber)?.intValue
                else { continue }
                if relative == "DEBIAN" || relative.hasPrefix("DEBIAN/") {
                    current = (relative == "DEBIAN/control") ? 0o644 : 0o755
                }
                let relaxed = current | (type == .typeDirectory ? 0o700 : 0o600)
                try fm.setAttributes([.posixPermissions: relaxed], ofItemAtPath: full)
            }
        }

        let entitlementsURL = work.appendingPathComponent("roothide.entitlements")
        try Data(entitlements.utf8).write(to: entitlementsURL)

        var files: [String] = []
        if let enumerator = fm.enumerator(atPath: root.path) {
            while let relative = enumerator.nextObject() as? String {
                if relative == mirrorRelativePath {
                    enumerator.skipDescendants()
                    continue
                }
                if let attributes = try? fm.attributesOfItem(atPath: root.path + "/" + relative),
                   attributes[.type] as? FileAttributeType == .typeRegular,
                   (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 {
                    files.append(relative)
                }
            }
        }

        for relative in files where !isExcluded(relative) {
            let full = root.path + "/" + relative
            let name = (relative as NSString).lastPathComponent
            if MachOPatcher.isMachO(atPath: full) {
                try patchBinary(at: full, relative: relative, mode: mode, ldid: ldid, entitlements: entitlementsURL.path)
            } else if mode == .rootless {
                patchText(at: full, relative: relative, name: name)
            }
        }

        let newControl = convertControl(control, mode: mode)
        try Data(newControl.utf8).write(to: root.appendingPathComponent("DEBIAN/control"))

        if mode == .rootless {
            try convertConffiles(at: root.appendingPathComponent("DEBIAN/conffiles"))
        }

        if let enumerator = fm.enumerator(atPath: root.path) {
            while let relative = enumerator.nextObject() as? String {
                if (relative as NSString).lastPathComponent == ".DS_Store" {
                    try? fm.removeItem(atPath: root.path + "/" + relative)
                }
            }
        }

        try run(CommandPath.chown, ["chown", "-R", "0:0", rootfs(root.path)], root: true)
        try restoreOwnership(originalMetadata, archiveOwners: archiveOwners, in: root, mode: mode)
        // after the ownership: chown clears the set-id bits
        try restorePermissions(originalMetadata, in: root, mode: mode)
        try run(CommandPath.chmod, ["chmod", "0755", rootfs(root.path)], root: true)
        if mode == .rootless {
            let mirror = rootfs(root.appendingPathComponent(mirrorRelativePath).path)
            try run(CommandPath.chown, ["chown", "-R", "501:501", mirror], root: true)
            try run(CommandPath.chmod, ["chmod", "-R", "0755", mirror], root: true)
            // directories of the mirror, and the ones made up on the way to it, are root's in group mobile
            let known = Set(originalMetadata.compactMap { relocatedPath(for: $0.relativePath, mode: mode) })
            var directories = ["var", "var/mobile", "var/mobile/Library"].filter { !known.contains($0) }
            if let enumerator = fm.enumerator(atPath: root.appendingPathComponent(mirrorRelativePath).path) {
                directories.append(mirrorRelativePath)
                while let relative = enumerator.nextObject() as? String {
                    if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                        directories.append(mirrorRelativePath + "/" + relative)
                    }
                }
            }
            let paths = directories.map { rootfs(root.appendingPathComponent($0).path) }
            for start in stride(from: 0, to: paths.count, by: 64) {
                try run(CommandPath.chown, ["chown", "0:501"] + paths[start..<min(start + 64, paths.count)], root: true)
            }
        }

        try run(CommandPath.dpkgdeb, ["dpkg-deb", "-Zzstd", "-b", rootfs(root.path), rootfs(output.path)], root: true)
        try run(CommandPath.chown, ["chown", owner, rootfs(output.path)], root: true)

        // TEMPORARY (debugging safe mode): keep a copy of every converted deb; remove once fixed
        let keepDir = "/var/mobile/ConvertedDebs"
        let keepName = "\(identifier)_\(Int(Date().timeIntervalSince1970)).deb"
        _ = try? run(CommandPath.mkdir, ["mkdir", "-p", rootfs(keepDir)], root: true)
        _ = try? run(CommandPath.cp, ["cp", rootfs(output.path), rootfs(keepDir + "/" + keepName)], root: true)
        _ = try? run(CommandPath.chmod, ["chmod", "-R", "0777", rootfs(keepDir)], root: true)
    }

    // MARK: - Layout

    private static func readMetadata(at root: URL) throws -> [FileMetadata] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw Failure.step("Reading package metadata", "Unable to enumerate extracted package")
        }

        var metadata: [FileMetadata] = []
        while let relative = enumerator.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let type = attributes[.type] as? FileAttributeType else { continue }
            guard type == .typeRegular || type == .typeDirectory || type == .typeSymbolicLink else { continue }
            guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
                  let group = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value
            else {
                throw Failure.step("Reading package metadata", "Unable to read permissions or ownership for \(relative)")
            }

            metadata.append(FileMetadata(relativePath: relative,
                                         permissions: permissions,
                                         owner: owner,
                                         group: group,
                                         isDirectory: type == .typeDirectory,
                                         isSymbolicLink: type == .typeSymbolicLink))
        }
        return metadata
    }

    private static func relocatedPath(for relativePath: String, mode: MachOPatcher.Mode) -> String? {
        guard mode == .rootless else { return relativePath }
        if relativePath == "var/jb" || relativePath == "var" {
            return nil
        }
        if relativePath.hasPrefix("var/jb/") {
            return String(relativePath.dropFirst("var/jb/".count))
        }
        if relativePath == "DEBIAN" || relativePath.hasPrefix("DEBIAN/") {
            return relativePath
        }
        return "rootfs/" + relativePath
    }

    private static func restorePermissions(_ metadata: [FileMetadata], in root: URL, mode: MachOPatcher.Mode) throws {
        let fm = FileManager.default
        var groups: [Int: [String]] = [:]
        for item in metadata where !item.isSymbolicLink {
            guard let relativePath = relocatedPath(for: item.relativePath, mode: mode) else { continue }
            let path = root.appendingPathComponent(relativePath).path
            guard (try? fm.attributesOfItem(atPath: path)) != nil else { continue }
            var permissions = item.permissions & 0o7777
            // patch.sh makes the control directory 755 and its control file 644
            if relativePath == "DEBIAN" || relativePath.hasPrefix("DEBIAN/") {
                permissions = relativePath == "DEBIAN/control" ? 0o644 : 0o755
            }
            groups[permissions, default: []].append(rootfs(path))
        }
        for (permissions, paths) in groups {
            let value = String(permissions, radix: 8)
            for start in stride(from: 0, to: paths.count, by: 64) {
                try run(CommandPath.chmod, ["chmod", value] + paths[start..<min(start + 64, paths.count)], root: true)
            }
        }
    }

    private static func restoreOwnership(_ metadata: [FileMetadata], archiveOwners: [String: (user: String, group: String)], in root: URL, mode: MachOPatcher.Mode) throws {
        let fm = FileManager.default
        let owners = Dictionary(grouping: metadata.compactMap { item -> (String, UInt32, UInt32)? in
            guard let relativePath = relocatedPath(for: item.relativePath, mode: mode) else { return nil }
            let path = root.appendingPathComponent(relativePath).path
            guard (try? fm.attributesOfItem(atPath: path)) != nil else { return nil }
            var owner = item.owner
            var group = item.group
            // dpkg installs by the names an archive carries, not by the numbers beside them
            if let names = archiveOwners[item.relativePath] {
                owner = userID(named: names.user) ?? owner
                group = groupID(named: names.group) ?? group
            }
            return (path, owner, group)
        }, by: { "\($0.1):\($0.2)" })

        for (owner, entries) in owners {
            for start in stride(from: 0, to: entries.count, by: 64) {
                let paths = entries[start..<min(start + 64, entries.count)].map { rootfs($0.0) }
                try run(CommandPath.chown, ["chown", "-h", owner] + paths, root: true)
            }
        }
    }

    private static func userID(named name: String) -> UInt32? {
        if let number = UInt32(name) { return number }
        return getpwnam(name).map { $0.pointee.pw_uid }
    }

    private static func groupID(named name: String) -> UInt32? {
        if let number = UInt32(name) { return number }
        return getgrnam(name).map { $0.pointee.gr_gid }
    }

    /// The owner and group names of every entry, by path, from `dpkg-deb -c`.
    private static func readArchiveOwners(of deb: URL) -> [String: (user: String, group: String)] {
        guard let listing = try? run(CommandPath.dpkgdeb, ["dpkg-deb", "-c", rootfs(deb.path)], root: true) else { return [:] }
        var owners: [String: (user: String, group: String)] = [:]
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let kind = fields[0].first else { continue }
            let names = fields[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard names.count == 2 else { continue }
            var path = String(fields[5])
            if kind == "l", let range = path.range(of: " -> ") {
                path = String(path[..<range.lowerBound])
            } else if kind == "h", let range = path.range(of: " link to ") {
                path = String(path[..<range.lowerBound])
            }
            if path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path != "." else { continue }
            owners[path] = (String(names[0]), String(names[1]))
        }
        return owners
    }

    /// var/jb/* becomes the package root, anything else goes to /rootfs, and the original package is kept in pkgmirror.
    private static func relocateRootless(old: URL, work: URL, identifier: String) throws -> URL {
        let fm = FileManager.default
        let new = work.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true, attributes: nil)
        try fm.moveItem(at: old.appendingPathComponent("DEBIAN"), to: new.appendingPathComponent("DEBIAN"))

        let jb = old.appendingPathComponent("var/jb", isDirectory: true)
        if fm.fileExists(atPath: jb.path) {
            for item in try fm.contentsOfDirectory(atPath: jb.path) {
                try fm.moveItem(at: jb.appendingPathComponent(item), to: new.appendingPathComponent(item))
            }
            try fm.removeItem(at: jb)
        }
        let varDirectory = old.appendingPathComponent("var")
        if let contents = try? fm.contentsOfDirectory(atPath: varDirectory.path), contents.isEmpty {
            try? fm.removeItem(at: varDirectory)
        }

        let remaining = try fm.contentsOfDirectory(atPath: old.path)
        if !remaining.isEmpty {
            let rootfsDirectory = new.appendingPathComponent("rootfs", isDirectory: true)
            try fm.createDirectory(at: rootfsDirectory, withIntermediateDirectories: true, attributes: nil)
            for item in remaining {
                try fm.moveItem(at: old.appendingPathComponent(item), to: rootfsDirectory.appendingPathComponent(item))
            }
        }

        let mirror = work.appendingPathComponent("pkgmirror", isDirectory: true)
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true, attributes: nil)
        try run(CommandPath.cp, ["cp", "-a", rootfs(new.path) + "/.", rootfs(mirror.path)])
        try fm.moveItem(at: mirror.appendingPathComponent("DEBIAN"), to: mirror.appendingPathComponent("DEBIAN.\(identifier)"))
        let library = new.appendingPathComponent("var/mobile/Library", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true, attributes: nil)
        try fm.moveItem(at: mirror, to: library.appendingPathComponent("pkgmirror"))
        return new
    }

    // MARK: - Files

    private static func isExcluded(_ relative: String) -> Bool {
        if relative.contains(".lproj/") { return true }
        if excludedSuffixes.contains(where: { relative.hasSuffix($0) }) { return true }
        if relative.hasSuffix(".lua") && (relative as NSString).lastPathComponent != "EQE.lua" { return true }
        return false
    }

    private static func patchBinary(at path: String, relative: String, mode: MachOPatcher.Mode, ldid: String, entitlements: String) throws {
        let url = URL(fileURLWithPath: path)
        let result: MachOPatcher.Result?
        do {
            result = try MachOPatcher.rewrite(try Data(contentsOf: url), mode: mode)
        } catch {
            throw Failure.binary(relative, error.localizedDescription)
        }
        guard let result else { return }
        if let data = result.data {
            try data.write(to: url)
        }

        var args = ["ldid", "-Hsha256"]
        if result.isExecutable {
            args += ["-M", "-S" + rootfs(entitlements)]
        } else {
            args.append("-S")
        }
        args.append(rootfs(path))
        do {
            try run(ldid, args)
        } catch {
            throw Failure.binary(relative, error.localizedDescription)
        }

        if mode == .rootless {
            let link = path + ".roothidepatch"
            var existing = stat()
            if lstat(link, &existing) != 0 {
                try writeRawSymlink(target: "/usr/lib/DynamicPatches/AutoPatches.dylib", at: link)
            }
        }
    }

    /// roothide's libroot hooks symlink() and rewrites the target to
    /// `/rootfs/usr/lib/...`; patch.sh's `ln -s` leaves it as is, which is what
    /// PatchLoader needs (a dangling `.roothidepatch` makes SpringBoard abort).
    /// The system's own symlink is called, as dyld resolves it from libsystem_kernel.
    private static func writeRawSymlink(target: String, at link: String) throws {
        typealias SymlinkFunction = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        guard let handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "symlink")
        else { throw Failure.step("symlink", "libsystem_kernel") }
        let result = unsafeBitCast(symbol, to: SymlinkFunction.self)(target, link)
        guard result == 0 else { throw Failure.step("symlink", String(cString: strerror(errno))) }
    }

    private static func patchText(at path: String, relative: String, name: String) {
        let url = URL(fileURLWithPath: path)
        let ext = (name as NSString).pathExtension
        if maintainerScripts.contains(name), let data = try? Data(contentsOf: url) {
            // keep the file's own encoding so that no byte changes by the round trip
            let encoding: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .isoLatin1
            if let text = String(data: data, encoding: encoding), let converted = convertScript(text).data(using: encoding) {
                try? converted.write(to: url)
            }
        }
        guard ext == "plist", let data = try? Data(contentsOf: url),
              let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        else { return }

        let directory = (relative as NSString).deletingLastPathComponent
        var text = String(decoding: xml, as: UTF8.self)
        switch plistRule(forDirectory: directory) {
        case .daemon: text = text.replacingOccurrences(of: "/var/jb/", with: "/")
        case .sandbox: text = convertSandyProfile(text)
        case nil: break
        }
        try? Data(text.utf8).write(to: url)
    }

    private enum PlistRule { case daemon, sandbox }

    /// patch.sh matches the directory (with its leading `/`) as an unanchored
    /// pattern against `{/Library/LaunchDaemons}`, then `{/Library/libSandy}`, so a
    /// plist directly in `/Library` or at the root is treated as a daemon's too.
    private static func plistRule(forDirectory directory: String) -> PlistRule? {
        let path = "/" + directory
        guard path.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        var pattern = regex_t()
        guard regcomp(&pattern, path, REG_EXTENDED | REG_NOSUB) == 0 else { return nil }
        defer { regfree(&pattern) }
        func matches(_ text: String) -> Bool { regexec(&pattern, text, 0, nil, 0) == 0 }
        return matches("{/Library/LaunchDaemons}") ? .daemon : matches("{/Library/libSandy}") ? .sandbox : nil
    }

    // MARK: - Text conversion

    private static let rootfsPrefixes = [" /Applications/", " /Library/", " /private/", " /System/", " /sbin/", " /bin/", " /etc/", " /lib/", " /usr/", " /var/"]
    private static let sandyPrefixes = [">/Applications/", ">/Library/", ">/private/", ">/System/", ">/sbin/", ">/bin/", ">/etc/", ">/lib/", ">/usr/", ">/var/"]

    static func convertScript(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "iphoneos-arm64", with: "iphoneos-arm64e")
            .replacingOccurrences(of: "iphoneos-arm64ee", with: "iphoneos-arm64e")
            .replacingOccurrences(of: "/var/jb/", with: "/-var/jb/-")
            .replacingOccurrences(of: "/var/jb", with: "/-var/jb-")
        for prefix in rootfsPrefixes {
            text = text.replacingOccurrences(of: prefix, with: " /rootfs" + prefix.dropFirst())
        }
        text = text.replacingOccurrences(of: "DIR=\"/Library/", with: "DIR=\"/rootfs/Library/")
        if let regex = try? NSRegularExpression(pattern: "^#!\\s*/rootfs/", options: []) {
            let newline = text.firstIndex(of: "\n") ?? text.endIndex
            let firstLine = String(text[..<newline])
            let replaced = regex.stringByReplacingMatches(in: firstLine, options: [], range: NSRange(location: 0, length: (firstLine as NSString).length), withTemplate: "#! /")
            text = replaced + text[newline...]
        }
        return text.replacingOccurrences(of: "/-var/jb/-", with: "/")
            .replacingOccurrences(of: "/-var/jb-", with: "/var/jb")
    }

    private static func convertSandyProfile(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "/var/jb/", with: "/-var/jb/-")
            .replacingOccurrences(of: "/var/jb", with: "/-var/jb-")
            .replacingOccurrences(of: ">/<", with: ">/rootfs/<")
        for prefix in sandyPrefixes {
            text = text.replacingOccurrences(of: prefix, with: ">/rootfs" + prefix.dropFirst())
        }
        return text.replacingOccurrences(of: "/-var/jb/-", with: "/")
            .replacingOccurrences(of: "/-var/jb-", with: "/var/jb")
    }

    private static func convertControl(_ control: String, mode: MachOPatcher.Mode) -> String {
        let archPattern = mode == .rootless ? "iphoneos-arm64(?!e)" : "iphoneos-arm(?!64)"
        let regex = try? NSRegularExpression(pattern: archPattern, options: [])
        var lines = control.components(separatedBy: "\n").filter { !$0.isEmpty }
        var hasPreDepends = false

        for index in lines.indices {
            var line = lines[index]
            if let regex {
                line = regex.stringByReplacingMatches(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "iphoneos-arm64e")
            }
            if mode == .rootless {
                if line.hasPrefix("Conflicts: ") {
                    line = line.replacingOccurrences(of: "roothide", with: "r-o-o-t-l-e-s-s-")
                }
                if line.hasPrefix("Pre-Depends:") {
                    hasPreDepends = true
                    let rest = String(line.dropFirst("Pre-Depends:".count))
                    line = rest.trimmingCharacters(in: .whitespaces).isEmpty ? "Pre-Depends: \(compatLayer)" : "Pre-Depends: \(compatLayer),\(rest)"
                }
            }
            lines[index] = line
        }
        if mode == .rootless && !hasPreDepends {
            lines.append("Pre-Depends: \(compatLayer)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// rootless conffiles name /var/jb/..., which must become the paths the files now have
    private static func convertConffiles(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), let text = try? readText(url) else { return }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("/var/jb/") { return String(line.dropFirst("/var/jb".count)) }
            if line.hasPrefix("/") { return "/rootfs" + line }
            return line
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }

    // MARK: - Helpers

    private static func field(_ name: String, in control: String) -> String? {
        for line in control.components(separatedBy: "\n") where line.hasPrefix(name + ":") {
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    @discardableResult
    private static func run(_ command: String, _ args: [String], root: Bool = false) throws -> String {
        let (status, output, errorOutput) = spawn(command: command, args: args, root: root)
        guard status == 0 else {
            let detail = (errorOutput.isEmpty ? output : errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.step(args.first ?? command, detail)
        }
        return output
    }
}
