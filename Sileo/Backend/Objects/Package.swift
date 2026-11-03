//
//  Package.swift
//  Sileo
//
//  Created by CoolStar on 7/3/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//
import UIKit

final class Package: PackageProtocol {
    
    public var package: String
    public var name: String
    public var version: String
    public var architecture: String?
    public var author: Maintainer?
    public var maintainer: Maintainer?
    public var section: String?
    public var rawSection: String?
    public var description: String?
    public var legacyDepiction: URL?
    public var nativeDepiction: URL?
    public var sileoDepiction: URL?
    public var icon: URL?
    public var sourceFile: String?
    public var source: ProvisionalRepo?
    public var isProvisional: Bool?
    public var sourceFileURL: URL?
    public var rawControl: [String: String] = [:]
    public var rawData: Data?
    public var essential: String?
    public var commercial: Bool = false
    public var installedSize: Int?
    public var tags: PackageTags = .none
    public var origArchitecture: String?
    // source a locally converted package was originally downloaded from
    public var originalSourceFile: String?
    
    public func allVersions(ignoreArch: Bool = false) -> [Package] {
        if let repo = self.sourceRepo {
            return repo.allVersions(identifier: self.package, ignoreArch: ignoreArch)
        }
        return [self]
    }
    
    public var fromStatusFile = false
    public var wantInfo: pkgwant = .unknown
    public var eFlag: pkgeflag = .ok
    public var status: pkgstatus = .installed
    public var installDate: Date?
    public var local_deb: String?
    
    public var filename: String?
    public var size: String?
    public var userRead = false
    
    public var defaultIcon: UIImage {
        if let rawSection = rawSection {
            
            // we have to do this because some repos have various Addons sections
            // ie, Addons (activator), Addons (youtube), etc
            if rawSection.lowercased().contains("addons") {
                return UIImage(named: "Category_addons") ?? UIImage(named: "Category_tweak")!
            } else if rawSection.lowercased().contains("themes") {
                // same case for themes
                return UIImage(named: "Category_themes") ?? UIImage(named: "Category_tweak")!
            }
            
            return UIImage(named: "Category_\(rawSection)") ?? UIImage(named: "Category_\(rawSection)s") ?? UIImage(named: "Category_tweak")!
        }
        return UIImage(named: "Category_tweak")!
    }
    
    var sourceRepo: Repo? {
        guard let sourceFileSafe = sourceFile else {
            return nil
        }
        return RepoManager.shared.repo(withSourceFile: sourceFileSafe)
    }
    
    var guid: String {
        String(format: "%@|-|%@", package, version)
    }
    
    init(package: String, version: String) {
        self.package = package
        self.version = version
        self.name = self.package
    }
    
    func hash(into hasher: inout Hasher) {
        //NSLog("SileoLog: Package.hash \(packageID) \(version) \(package) \(sourceRepo?.url)")
        hasher.combine(package)
        hasher.combine(version)
    }
    
    public func hasIcon() -> Bool {
        icon != nil
    }
}


// Remembers which source an installed package was installed from, since dpkg's status file doesn't
enum InstalledSourceStore {
    private static let key = "InstalledPackageSources"

    private static var records: [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }

    static func record(_ package: Package) {
        guard let source = package.sourceFile ?? package.originalSourceFile else { return }
        var all = records
        all[package.package] = ["version": package.version, "source": source]
        UserDefaults.standard.set(all, forKey: key)
    }

    static func remove(identifier: String) {
        var all = records
        guard all.removeValue(forKey: identifier) != nil else { return }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func source(identifier: String, version: String) -> String? {
        guard let entry = records[identifier], entry["version"] == version else { return nil }
        return entry["source"]
    }
}
