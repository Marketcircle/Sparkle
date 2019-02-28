//
//  Created by Kornel on 22/12/2016.
//  Copyright © 2016 Sparkle Project. All rights reserved.
//

import Foundation

class DeltaUpdate {
    let fromVersion: String;
    let archivePath: URL;
    var dsaSignature: String?;
    var edSignature: String?;

    init(fromVersion: String, archivePath: URL) {
        self.archivePath = archivePath;
        self.fromVersion = fromVersion;
    }

    var fileSize : Int64 {
        let archiveFileAttributes = try! FileManager.default.attributesOfItem(atPath: self.archivePath.path);
        return (archiveFileAttributes[.size] as! NSNumber).int64Value;
    }

    class func create(from: ArchiveItem, to: ArchiveItem, archivePath: URL) throws -> DeltaUpdate {
        var applyDiffError: NSError? = nil;

        if (!createBinaryDelta(from.appPath.path, to.appPath.path, archivePath.path, .beigeMajorVersion, false, &applyDiffError)) {
            throw applyDiffError!;
        }

        return DeltaUpdate(fromVersion: from.version, archivePath: archivePath);
    }
}

class ArchiveItem: CustomStringConvertible {
    let version: String;
    let _shortVersion: String?;
    let minimumSystemVersion: String;
    let archivePath: URL;
    let appPath: URL;
    let feedURL: URL?;
    let publicEdKey: Data?;
    let supportsDSA: Bool;
    let archiveFileAttributes: [FileAttributeKey:Any];
    var deltas: [DeltaUpdate];

    var dsaSignature: String?;
    var edSignature: String?;

    init(version: String, shortVersion: String?, feedURL: URL?, minimumSystemVersion: String?, publicEdKey: String?, supportsDSA: Bool, appPath: URL, archivePath: URL) throws {
        self.version = version;
        self._shortVersion = shortVersion;
        self.feedURL = feedURL;
        self.minimumSystemVersion = minimumSystemVersion ?? "10.7";
        self.archivePath = archivePath;
        self.appPath = appPath;
        self.supportsDSA = supportsDSA;
        if let publicEdKey = publicEdKey {
            self.publicEdKey = Data(base64Encoded: publicEdKey);
        } else {
            self.publicEdKey = nil;
        }
        self.archiveFileAttributes = try FileManager.default.attributesOfItem(atPath: self.archivePath.path);
        self.deltas = [];
    }

    convenience init(fromArchive archivePath: URL, unarchivedDir: URL) throws {
        let resourceKeys = [URLResourceKey.typeIdentifierKey]
        let items = try FileManager.default.contentsOfDirectory(at: unarchivedDir, includingPropertiesForKeys: resourceKeys, options: .skipsHiddenFiles)

        let bundles = items.filter({
            if let resourceValues = try? $0.resourceValues(forKeys: Set(resourceKeys)) {
                return UTTypeConformsTo(resourceValues.typeIdentifier! as CFString, kUTTypeBundle)
            } else {
                return false
            }
        });
        if bundles.count > 0 {
            if bundles.count > 1 {
                throw makeError(code: .unarchivingError, "Too many bundles in \(unarchivedDir.path) \(bundles)");
            }

            let appPath = bundles[0];
            guard let infoPlist = NSDictionary(contentsOf: appPath.appendingPathComponent("Contents/Info.plist")) else {
                throw makeError(code: .unarchivingError, "No plist \(appPath.path)");
            }
            guard let version = infoPlist[kCFBundleVersionKey] as? String else {
                throw makeError(code: .unarchivingError, "No Version \(kCFBundleVersionKey as String? ?? "missing kCFBundleVersionKey") \(appPath)");
            }
            let shortVersion = infoPlist["CFBundleShortVersionString"] as? String;
            let publicEdKey = infoPlist[SUPublicEDKeyKey] as? String;
            let supportsDSA = infoPlist[SUPublicDSAKeyKey] != nil || infoPlist[SUPublicDSAKeyFileKey] != nil;

            var feedURL:URL? = nil;
            if let feedURLStr = infoPlist["SUFeedURL"] as? String {
                feedURL = URL(string: feedURLStr)
                if feedURL?.pathExtension == "php" {
                    feedURL = feedURL!.deletingLastPathComponent()
                    feedURL = feedURL!.appendingPathComponent("appcast.xml")
                }
            }

            try self.init(version: version,
                           shortVersion: shortVersion,
                           feedURL: feedURL,
                           minimumSystemVersion: infoPlist["LSMinimumSystemVersion"] as? String,
                           publicEdKey: publicEdKey,
                           supportsDSA: supportsDSA,
                           appPath: appPath,
                           archivePath: archivePath);
        } else {
            //init(fromArchive archivePath: URL, unarchivedDir: URL)
            do {
                try self.init(fromArchive: archivePath, unarchivedDir: unarchivedDir, special: "yes")
            }
            catch {
                throw makeError(code: .missingUpdateError, "No supported items in \(unarchivedDir) \(items) [note: only .app bundles are supported]");
            }
        }
    }

    convenience init(fromArchive archivePath: URL, unarchivedDir: URL, special: String) throws {

        print("GOING DEEPER!!!!!!!!!!!!!!!!!!")

        let items = try FileManager.default.contentsOfDirectory(atPath: unarchivedDir.path)
            .filter({ !$0.hasPrefix(".") })
            .map({ unarchivedDir.appendingPathComponent($0) })

        print("items", items)

        let apps = items.filter({ $0.pathExtension == "pkg" });
        print("AppCount", apps)
        if apps.count > 0 {
            if apps.count > 1 {
                throw makeError(code: .unarchivingError, "Too many apps in \(unarchivedDir.path) \(apps)");
            }

            //Create tmp dir so we can unpackage and work while not touching the appcast dir
            let directory = NSTemporaryDirectory()
            let fileName = NSUUID().uuidString
            let fullURL = NSURL.fileURL(withPathComponents: [directory, fileName])

            print("TEMP DIR:", fullURL?.absoluteString as Any)
            let fileManager = FileManager.default


            let pathOfPKGContent = unarchivedDir.appendingPathComponent("PKGContent", isDirectory:true).path
            do {
                try fileManager.createDirectory(atPath: pathOfPKGContent, withIntermediateDirectories: true, attributes: nil)
            }
            catch let error as NSError {
                print("Could not create folder!!!: \(error)")
            }

            let unzipResult = shell(launchPath: "/usr/bin/xar", arguments: ["-xf", apps[0].path, "-C", pathOfPKGContent])

            print("Unzip result", unzipResult)

            //there can be more than one payload
            let payloadPaths = findFiles(path: pathOfPKGContent, filename: "Payload")
            print("Payload Paths", payloadPaths)

            var infoPlistWithSignature: Dictionary<String, Any> = [:]
            var appPath:URL? = nil;
            for aPayloadPath in payloadPaths {

                let pathOfPKGContentUnique = unarchivedDir.appendingPathComponent("PKGContent" +  UUID().uuidString, isDirectory:true).path
                do {
                    try fileManager.createDirectory(atPath: pathOfPKGContentUnique, withIntermediateDirectories: true, attributes: nil)
                }
                catch let error as NSError {
                    print("Ooops! Something went wrong: \(error)")
                }

                let newPayloadPath = aPayloadPath + UUID().uuidString
                print("Payload Path", newPayloadPath)

                do {
                    try fileManager.moveItem(at: URL(fileURLWithPath: aPayloadPath), to: URL(fileURLWithPath: newPayloadPath))
                }
                catch let error as NSError {
                    print("Could not rename: \(error)")

                }

                let unpackagePKG = shellFromString("(cd " + pathOfPKGContentUnique + " && cat " + newPayloadPath + " | gunzip -dc | cpio -i)")
                print("UPKG",newPayloadPath)

                let pathToInfoPlist = findFile(path: pathOfPKGContentUnique, filename: "Info.plist")

                appPath = apps[0];
                guard let infoPlist = NSDictionary(contentsOf: URL(fileURLWithPath: pathToInfoPlist)) else {
                    throw makeError(code: .unarchivingError, "No plist \(appPath!.path)");
                }
                print("PayloadPlist", infoPlist)

                let publicEdKey = infoPlist[SUPublicEDKeyKey] as? String;

                if((publicEdKey) != nil) {
                    infoPlistWithSignature = infoPlist as! Dictionary<String, Any>
                    break
                }

            }

            guard let version = infoPlistWithSignature[kCFBundleVersionKey as String] as? String else {
                throw makeError(code: .unarchivingError, "No Version \("kCFBundleVersionKey" as String? ?? "missing kCFBundleVersionKey") \(appPath?.absoluteString ?? "")");
            }

            let shortVersion = infoPlistWithSignature["CFBundleShortVersionString"] as? String;
            let publicEdKey = infoPlistWithSignature[SUPublicEDKeyKey] as? String;
            let supportsDSA = infoPlistWithSignature[SUPublicDSAKeyKey] != nil || infoPlistWithSignature[SUPublicDSAKeyFileKey] != nil;

            var feedURL:URL? = nil;
            if let feedURLStr = infoPlistWithSignature["SUFeedURL"] as? String {
                feedURL = URL(string: feedURLStr);
            }

            try self.init(version: version,
                          shortVersion: shortVersion,
                          feedURL: feedURL,
                          minimumSystemVersion: infoPlistWithSignature["LSMinimumSystemVersion"] as? String,
                          publicEdKey: publicEdKey,
                          supportsDSA: supportsDSA,
                          appPath: appPath!,
                          archivePath: archivePath);
        } else {
            throw makeError(code: .missingUpdateError, "No supported items in \(unarchivedDir) \(items) [note: only .app bundles are supported]");
        }
    }

    var shortVersion: String {
        return self._shortVersion ?? self.version;
    }

    var description : String {
        return "\(self.archivePath) \(self.version)"
    }

    var archiveURL: URL? {
        guard let escapedFilename = self.archivePath.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil;
        }
        if let relative = self.feedURL {
            return URL(string: escapedFilename, relativeTo: relative)
        }
        return URL(string: escapedFilename)
    }

    var pubDate : String {
        let date = self.archiveFileAttributes[.creationDate] as! Date;
        let formatter = DateFormatter();
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZ";
        return formatter.string(from: date);
    }

    var fileSize : Int64 {
        return (self.archiveFileAttributes[.size] as! NSNumber).int64Value;
    }
    
    private var releaseNotesPath : URL? {
        var basename = self.archivePath.deletingPathExtension();
        if basename.pathExtension == "tar" { // tar.gz
            basename = basename.deletingPathExtension();
        }
        let releaseNotes = basename.appendingPathExtension("html");
        if !FileManager.default.fileExists(atPath: releaseNotes.path) {
            return nil;
        }
        return releaseNotes;
    }

    private func getReleaseNotesAsHTMLFragment(_ path: URL) -> String?  {
        if let html = try? String(contentsOf: path) {
            if html.utf8.count < 1000 &&
                !html.localizedCaseInsensitiveContains("<!DOCTYPE") &&
                !html.localizedCaseInsensitiveContains("<body") {
                return html;
            }
        }
        return nil;
    }

    var releaseNotesHTML : String? {
        if let path = self.releaseNotesPath {
            return self.getReleaseNotesAsHTMLFragment(path);
        }
        return nil;
    }

    var releaseNotesURL : URL? {
        guard let path = self.releaseNotesPath else {
            return nil;
        }
        // The file is already used as inline description
        if self.getReleaseNotesAsHTMLFragment(path) != nil {
            return nil;
        }
        guard let escapedFilename = path.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil;
        }
        if let relative = self.feedURL {
            return URL(string: escapedFilename, relativeTo: relative)
        }
        return URL(string: escapedFilename)
    }

    let mimeType = "application/octet-stream";


}

func shell(launchPath: String, arguments: [String] = []) -> (String? , Int32) {
    let task = Process()
    task.launchPath = launchPath
    task.arguments = arguments

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.launch()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)
    task.waitUntilExit()
    return (output, task.terminationStatus)
}

func shellFromString(_ command: String) -> String {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output: String = NSString(data: data, encoding: String.Encoding.utf8.rawValue)! as String
    task.waitUntilExit()
    return output
}

func findFile(path: String, filename: String) -> String {

    var payloadPath = "";

    let resourceKeys : [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
    let pkgURL = URL(fileURLWithPath: path)
    let enumerator = FileManager.default.enumerator(at: pkgURL,
                                                    includingPropertiesForKeys: resourceKeys,
                                                    options: [.skipsHiddenFiles], errorHandler: { (url, error) -> Bool in
                                                        print("directoryEnumerator error at \(url): ", error)
                                                        return true
    })!


    var payloadPaths: Array<Any>?;

    for case let fileURL as URL in enumerator {

        if(fileURL.path.contains(filename)) {
            print("Found Path:", fileURL.path)
            payloadPath = fileURL.path
        }
    }

    return payloadPath

}

func findFiles(path: String, filename: String) -> Array<String> {


    let resourceKeys : [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
    let pkgURL = URL(fileURLWithPath: path)
    let enumerator = FileManager.default.enumerator(at: pkgURL,
                                                    includingPropertiesForKeys: resourceKeys,
                                                    options: [.skipsHiddenFiles], errorHandler: { (url, error) -> Bool in
                                                        print("directoryEnumerator error at \(url): ", error)
                                                        return true
    })!


    var payloadPaths: Array<String> = []

    for case let fileURL as URL in enumerator {

        if(fileURL.path.contains(filename)) {
            print("Found Path:", fileURL.path)
            payloadPaths.append(fileURL.path)
        }
    }

    return payloadPaths

}
