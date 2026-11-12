// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Looks into the demo app's own data container on the simulator (the UI-test process runs on the same Mac, so the
/// simulator's data folder is readable). Used to prove that the system photo picker and the file exporter leave no
/// file of the photo behind in the app's storage. Paths are always reported relative to the container.
enum AppContainer {
    struct Entry: Equatable, CustomStringConvertible {
        let path: String
        let size: Int
        var description: String { "\(path) (\(size) bytes)" }
    }

    /// Files the system itself creates for every app. They hold no photo data: the container manager's metadata,
    /// the app's preference domain, the SplashBoard launch snapshots and the small UI state-restoration records.
    static func isSystemFile(_ entry: Entry, bundleID: String) -> Bool {
        entry.path == ".com.apple.mobile_container_manager.metadata.plist"
            || entry.path == "Library/Preferences/\(bundleID).plist"
            || entry.path.hasPrefix("Library/SplashBoard/")
            || entry.path.hasPrefix("Library/Saved Application State/")
    }

    /// The data container of `bundleID` on the simulator this process runs on, or nil.
    static func root(bundleID: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard let udid = env["SIMULATOR_UDID"], let host = env["SIMULATOR_HOST_HOME"] else { return nil }
        let apps = URL(fileURLWithPath: host)
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Data/Application")
        let folders = (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
        return folders.first { folder in
            let metadata = folder.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return plist["MCMMetadataIdentifier"] as? String == bundleID
        }
    }

    /// Deletes the files the system exporter wrote for `name` (a base name such as "masked-photo") into the
    /// simulator's "On My iPhone" storage on an earlier run. The simulator cannot replace an existing file (it fails
    /// moving it to the trash), so a save would otherwise stop at the system's "Replace Existing Items?" prompt.
    static func removeEarlierExports(named name: String) {
        let env = ProcessInfo.processInfo.environment
        guard let udid = env["SIMULATOR_UDID"], let host = env["SIMULATOR_HOST_HOME"] else { return }
        let groups = URL(fileURLWithPath: host)
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Shared/AppGroup")
        for group in (try? FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let storage = group.appendingPathComponent("File Provider Storage")
            for file in (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix(name) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Every regular file in the container at any depth, relative path and size, sorted. Empty folders are not listed.
    static func listing(of root: URL) -> [Entry] {
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(
            at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return [] }
        var entries: [Entry] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            entries.append(Entry(path: String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)),
                                 size: values?.fileSize ?? 0))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// What is in the container besides the system's own files: after a full cycle this must be empty.
    static func leftovers(in root: URL, bundleID: String) -> [Entry] {
        listing(of: root).filter { !isSystemFile($0, bundleID: bundleID) }
    }
}
