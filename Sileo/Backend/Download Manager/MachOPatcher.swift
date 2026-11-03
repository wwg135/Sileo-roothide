//
//  MachOPatcher.swift
//  Sileo
//
//  Rewrites the dylib / rpath load commands of a Mach-O file in place of
//  install_name_tool, so that packages can be converted without any
//  external tool except ldid (used afterwards to sign).
//

import Foundation

enum MachOPatcher {
    enum Mode {
        case rootless
        case rootful
    }

    enum Failure: LocalizedError {
        case malformed
        case noRoom

        var errorDescription: String? {
            switch self {
            case .malformed: return String(localizationKey: "Compat_MachO_Malformed")
            case .noRoom: return String(localizationKey: "Compat_MachO_No_Room")
            }
        }
    }

    struct Result {
        /// nil when nothing had to change
        let data: Data?
        let isExecutable: Bool
    }

    private static let lcSegment64: UInt32 = 0x19
    private static let lcCodeSignature: UInt32 = 0x1D
    private static let lcRpath: UInt32 = 0x8000001C
    private static let dylibCommands: Set<UInt32> = [0x0C, 0x80000018, 0x8000001F, 0x20, 0x80000023]
    private static let rootfulRpaths = ["/usr/lib", "@loader_path/.jbroot/usr/lib", "/Library/Frameworks", "@loader_path/.jbroot/Library/Frameworks"]

    static func isMachO(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 4))
        guard head.count == 4 else { return false }
        let magic = head.le32(0)
        return magic == 0xFEEDFACF || magic == 0xFEEDFACE || magic == 0xBEBAFECA || magic == 0xBFBAFECA
    }

    /// Returns nil when `data` is not a (64-bit or fat) Mach-O.
    static func rewrite(_ data: Data, mode: Mode) throws -> Result? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let magic = bytes.le32(0)

        if magic == 0xFEEDFACF {
            let patched = try patchSlice(bytes, mode: mode)
            return Result(data: patched.changed ? Data(patched.bytes) : nil, isExecutable: patched.executable)
        }

        guard magic == 0xBEBAFECA || magic == 0xBFBAFECA else { return nil }
        let is64 = magic == 0xBFBAFECA
        let count = Int(bytes.be32(4))
        let entrySize = is64 ? 32 : 20
        guard count > 0, count <= 16, 8 + count * entrySize <= bytes.count else { return nil }

        var header = Array(bytes[0..<(8 + count * entrySize)])
        var body: [UInt8] = []
        var cursor = header.count
        var changed = false
        var executable = false

        for index in 0..<count {
            let entry = 8 + index * entrySize
            let offset: Int
            let size: Int
            let alignField: Int
            if is64 {
                offset = Int(bytes.be64(entry + 8))
                size = Int(bytes.be64(entry + 16))
                alignField = Int(bytes.be32(entry + 24))
            } else {
                offset = Int(bytes.be32(entry + 8))
                size = Int(bytes.be32(entry + 12))
                alignField = Int(bytes.be32(entry + 16))
            }
            guard offset >= 0, size >= 0, offset + size <= bytes.count, alignField < 32 else { throw Failure.malformed }

            var slice = Array(bytes[offset..<(offset + size)])
            if slice.count >= 32 && slice.le32(0) == 0xFEEDFACF {
                let patched = try patchSlice(slice, mode: mode)
                slice = patched.bytes
                changed = changed || patched.changed
                executable = executable || patched.executable
            }

            let align = 1 << alignField
            let pad = (align - cursor % align) % align
            body += [UInt8](repeating: 0, count: pad)
            cursor += pad
            if is64 {
                header.putBE64(entry + 8, UInt64(cursor))
                header.putBE64(entry + 16, UInt64(slice.count))
            } else {
                header.putBE32(entry + 8, UInt32(cursor))
                header.putBE32(entry + 12, UInt32(slice.count))
            }
            body += slice
            cursor += slice.count
        }

        return Result(data: changed ? Data(header + body) : nil, isExecutable: executable)
    }

    private static func patchSlice(_ slice: [UInt8], mode: Mode) throws -> (bytes: [UInt8], changed: Bool, executable: Bool) {
        guard slice.count >= 32 else { throw Failure.malformed }
        let filetype = slice.le32(12)
        let ncmds = Int(slice.le32(16))
        let sizeofcmds = Int(slice.le32(20))
        let cmdsEnd = 32 + sizeofcmds
        guard cmdsEnd <= slice.count else { throw Failure.malformed }

        var cmds: [[UInt8]] = []
        var offset = 32
        for _ in 0..<ncmds {
            guard offset + 8 <= cmdsEnd else { throw Failure.malformed }
            let size = Int(slice.le32(offset + 4))
            guard size >= 8, offset + size <= cmdsEnd else { throw Failure.malformed }
            cmds.append(Array(slice[offset..<(offset + size)]))
            offset += size
        }

        let executable = filetype == 2
        var changed = false
        var rpaths = Set<String>()

        for index in cmds.indices {
            let cmd = cmds[index].le32(0)
            if dylibCommands.contains(cmd) {
                if let rewritten = rewriteString(cmds[index], transform: { transformLibrary($0, mode: mode) }) {
                    cmds[index] = rewritten
                    changed = true
                }
            } else if cmd == lcRpath {
                if mode == .rootless, let rewritten = rewriteString(cmds[index], transform: { transformRpath($0) }) {
                    cmds[index] = rewritten
                    changed = true
                }
                if let value = readString(cmds[index]) {
                    rpaths.insert(value)
                }
            }
        }

        if mode == .rootful {
            for path in rootfulRpaths where !rpaths.contains(path) {
                cmds.append(makeRpath(path))
                rpaths.insert(path)
                changed = true
            }
        }

        guard changed else { return (slice, false, executable) }

        var firstContent = slice.count
        var minSegment = slice.count
        for cmd in cmds where cmd.le32(0) == lcSegment64 && cmd.count >= 72 {
            let fileoff = Int(cmd.le64(40))
            let filesize = Int(cmd.le64(48))
            if fileoff > 0 && filesize > 0 { minSegment = min(minSegment, fileoff) }
            let nsects = Int(cmd.le32(64))
            for sect in 0..<nsects {
                let base = 72 + sect * 80
                guard base + 80 <= cmd.count else { break }
                let sectOffset = Int(cmd.le32(base + 48))
                let type = cmd.le32(base + 64) & 0xFF
                if sectOffset > 0 && type != 0x1 && type != 0xC && type != 0x12 {
                    firstContent = min(firstContent, sectOffset)
                }
            }
        }
        if firstContent == slice.count { firstContent = minSegment }

        var output = slice
        var total = cmds.reduce(0) { $0 + $1.count }

        if 32 + total > firstContent {
            // Drop the signature (it is redone by ldid) to make room for it and the new commands.
            guard let sigIndex = cmds.firstIndex(where: { $0.le32(0) == lcCodeSignature }),
                  32 + total - cmds[sigIndex].count + 16 <= firstContent,
                  let linkeditIndex = cmds.firstIndex(where: { $0.le32(0) == lcSegment64 && segmentName($0) == "__LINKEDIT" })
            else { throw Failure.noRoom }

            let sig = cmds[sigIndex]
            let dataoff = Int(sig.le32(8))
            let datasize = Int(sig.le32(12))
            let linkeditOff = Int(cmds[linkeditIndex].le64(40))
            guard dataoff + datasize == slice.count, dataoff >= linkeditOff else { throw Failure.noRoom }

            let newFilesize = UInt64(dataoff - linkeditOff)
            cmds[linkeditIndex].putLE64(48, newFilesize)
            cmds[linkeditIndex].putLE64(32, (newFilesize + 0x3FFF) & ~UInt64(0x3FFF))
            cmds.remove(at: sigIndex)
            output = Array(slice[0..<dataoff])
            total = cmds.reduce(0) { $0 + $1.count }
        }

        var cursor = 32
        for cmd in cmds {
            output.replaceSubrange(cursor..<(cursor + cmd.count), with: cmd)
            cursor += cmd.count
        }
        if cursor < cmdsEnd {
            output.replaceSubrange(cursor..<cmdsEnd, with: [UInt8](repeating: 0, count: cmdsEnd - cursor))
        }
        output.putLE32(16, UInt32(cmds.count))
        output.putLE32(20, UInt32(total))
        return (output, true, executable)
    }

    private static func transformLibrary(_ path: String, mode: Mode) -> String? {
        switch mode {
        case .rootless:
            return transformRpath(path)
        case .rootful:
            if path.hasPrefix("/usr/lib/") {
                return "@rpath/" + path.dropFirst("/usr/lib/".count)
            }
            if path.hasPrefix("/Library/Frameworks/") {
                return "@rpath/" + path.dropFirst("/Library/Frameworks/".count)
            }
            return nil
        }
    }

    private static func transformRpath(_ path: String) -> String? {
        guard path.hasPrefix("/var/jb/") else { return nil }
        return "@loader_path/.jbroot/" + path.dropFirst("/var/jb/".count)
    }

    private static func segmentName(_ cmd: [UInt8]) -> String {
        let name = cmd[8..<24].prefix { $0 != 0 }
        return String(decoding: name, as: UTF8.self)
    }

    private static func readString(_ cmd: [UInt8]) -> String? {
        guard cmd.count > 12 else { return nil }
        let offset = Int(cmd.le32(8))
        guard offset >= 12, offset < cmd.count else { return nil }
        let raw = cmd[offset...].prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
    }

    private static func rewriteString(_ cmd: [UInt8], transform: (String) -> String?) -> [UInt8]? {
        guard let value = readString(cmd), let replaced = transform(value) else { return nil }
        let offset = Int(cmd.le32(8))
        var out = Array(cmd[0..<offset]) + Array(replaced.utf8) + [0]
        out += [UInt8](repeating: 0, count: (8 - out.count % 8) % 8)
        out.putLE32(4, UInt32(out.count))
        return out
    }

    private static func makeRpath(_ path: String) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12) + Array(path.utf8) + [0]
        out += [UInt8](repeating: 0, count: (8 - out.count % 8) % 8)
        out.putLE32(0, lcRpath)
        out.putLE32(4, UInt32(out.count))
        out.putLE32(8, 12)
        return out
    }
}

private extension Array where Element == UInt8 {
    func le32(_ offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func le64(_ offset: Int) -> UInt64 {
        let low = UInt64(le32(offset))
        let high = UInt64(le32(offset + 4)) << 32
        return low | high
    }

    func be32(_ offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset]) << 24
        let b1 = UInt32(self[offset + 1]) << 16
        let b2 = UInt32(self[offset + 2]) << 8
        let b3 = UInt32(self[offset + 3])
        return b0 | b1 | b2 | b3
    }

    func be64(_ offset: Int) -> UInt64 {
        let high = UInt64(be32(offset)) << 32
        let low = UInt64(be32(offset + 4))
        return high | low
    }

    mutating func putLE32(_ offset: Int, _ value: UInt32) {
        for index in 0..<4 { self[offset + index] = UInt8((value >> UInt32(8 * index)) & 0xFF) }
    }

    mutating func putLE64(_ offset: Int, _ value: UInt64) {
        for index in 0..<8 { self[offset + index] = UInt8((value >> UInt64(8 * index)) & 0xFF) }
    }

    mutating func putBE32(_ offset: Int, _ value: UInt32) {
        for index in 0..<4 { self[offset + index] = UInt8((value >> UInt32(8 * (3 - index))) & 0xFF) }
    }

    mutating func putBE64(_ offset: Int, _ value: UInt64) {
        for index in 0..<8 { self[offset + index] = UInt8((value >> UInt64(8 * (7 - index))) & 0xFF) }
    }
}
