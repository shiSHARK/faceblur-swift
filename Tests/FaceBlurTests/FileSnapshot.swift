// SPDX-License-Identifier: Apache-2.0
// The same file is in Tests/FaceBlurTests and Tests/FaceBlurOnnxRuntimeTests (the two test bundles share no target);
// keep both copies identical.
import Foundation
import XCTest

/// The test process's own temporary directory. The XCTest host is not sandboxed, so `NSTemporaryDirectory()` would
/// be the simulator device's shared `tmp`, where other processes write at any time. ``install()`` creates a new, empty
/// folder in the device's home and points `TMPDIR` at it before the process's first `NSTemporaryDirectory()` call
/// (Foundation keeps the first value it returns, so every test class installs it in its class `setUp`).
/// ``assertActive(file:line:)`` fails the test when `NSTemporaryDirectory()` is not that folder. The folder is removed
/// when the process exits.
enum PrivateTemp {
    private static let paths: (shared: String, folder: String, created: Bool) = {
        let shared = ProcessInfo.processInfo.environment["TMPDIR"] ?? (NSHomeDirectory() + "/tmp/")
        let folder = NSHomeDirectory() + "/faceblur-private-tmp-\(UUID().uuidString)/"
        // withIntermediateDirectories: false fails if the folder exists, so it is new and empty.
        let created = (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false))
            != nil
        if created {
            setenv("TMPDIR", folder, 1)
            atexit { try? FileManager.default.removeItem(atPath: PrivateTemp.folder) }
        }
        return (shared, folder, created)
    }()

    /// The simulator's shared `tmp` as the process received it.
    static var shared: String { paths.shared }
    /// The private folder (with a trailing slash, as `NSTemporaryDirectory()` returns it).
    static var folder: String { paths.folder }

    static func install() { _ = paths }

    static func assertActive(file: StaticString = #filePath, line: UInt = #line) {
        install()
        let now = NSTemporaryDirectory()
        let std = { (p: String) in (p as NSString).standardizingPath }
        XCTAssertTrue(paths.created, "the private temporary folder was created: \(folder)", file: file, line: line)
        XCTAssertEqual(now, folder, "NSTemporaryDirectory() is the private folder", file: file, line: line)
        XCTAssertNotEqual(std(now), std(shared), "NSTemporaryDirectory() is not the shared tmp", file: file, line: line)
        XCTAssertFalse(std(now).hasPrefix(std(shared) + "/"), "and not inside it", file: file, line: line)
    }
}

/// Names and sizes (folders: -2) of the files this test process could leave behind, for the nothing-written check.
/// Recorded:
/// 1. everything, at any depth, in the private temporary folder (``PrivateTemp``) and in the `extra` folders (the
///    test's own output folders);
/// 2. everything, at any depth, below a path component named exactly after the host's or the test bundle's
///    identifier, or `<id>.<suffix>`, in the shared `tmp`, `Library`, `Library/Caches` and `Documents`;
/// 3. in the shared `tmp`, `Library/Caches`, `Library/Application Support` and `Documents` (any depth), every entry
///    that looks like a photo or a FaceBlur file: a path component containing "faceblur" (any case; this includes
///    the library's own temporary names `.<name>.faceblur-<random>.tmp`), an image extension, or a regular file that
///    starts with JPEG, PNG or HEIF magic bytes. Other processes' files there are ignored only because they match
///    none of these rules (no name list). A rule-3 entry that only disappears is not a difference (system services
///    purge their caches; a removed file is not a copy left behind); added or resized ones are.
/// The positive and negative controls in ``assertSeesHostFolders(extra:)`` prove each rule on every run.
struct FileSnapshot {
    private(set) var entries: [String: Int] = [:]
    private var watchedOnly: Set<String> = []

    subscript(path: String) -> Int? { entries[path] }

    static var ownIdentifiers: [String] {
        [Bundle.main.bundleIdentifier, Bundle(for: SnapshotAnchor.self).bundleIdentifier].compactMap { $0 }
    }

    static func directory(_ d: FileManager.SearchPathDirectory) -> String? {
        NSSearchPathForDirectoriesInDomains(d, .userDomainMask, true).first
    }

    static var ownRoots: [String] {
        [PrivateTemp.shared] + [.cachesDirectory, .libraryDirectory, .documentDirectory].compactMap(directory)
    }

    static var watchedRoots: [String] {
        [PrivateTemp.shared] + [.cachesDirectory, .applicationSupportDirectory, .documentDirectory].compactMap(directory)
    }

    /// True when a component of `relative` is one of the host's own names (an identifier, or an identifier plus a
    /// suffix).
    static func isOwn(_ relative: String, _ ids: [String]) -> Bool {
        relative.split(separator: "/").contains { c in ids.contains { c == $0 || c.hasPrefix($0 + ".") } }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "hif", "png", "tif", "tiff", "dng"]
    static let heifBrands: Set<String> = ["heic", "heix", "mif1", "msf1", "hevc", "hevx", "heim", "heis"]

    /// JPEG (FF D8 FF), PNG (89 50 4E 47 0D 0A 1A 0A) or HEIF (`ftyp` + a HEIF brand) magic bytes.
    static func hasImageMagic(_ b: [UInt8]) -> Bool {
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        if b.count >= 8, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        return b.count >= 12 && b[4..<8].elementsEqual(Array("ftyp".utf8))
            && heifBrands.contains(String(decoding: b[8..<12], as: UTF8.self))
    }

    /// Rule 3.
    static func isWatched(_ relative: String, path: String, regularFile: Bool) -> Bool {
        if relative.lowercased().contains("faceblur") { return true }
        if imageExtensions.contains((relative as NSString).pathExtension.lowercased()) { return true }
        guard regularFile, let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        return hasImageMagic([UInt8]((try? h.read(upToCount: 12)) ?? Data()))
    }

    static func take(extra: [String] = []) -> FileSnapshot {
        PrivateTemp.assertActive()
        let fm = FileManager.default
        let ids = ownIdentifiers
        var full: [String: Int] = [:], watched: [String: Int] = [:]
        func walk(_ root: String, _ rule: (String, String, Bool) -> (record: Bool, watched: Bool)) {
            guard let e = fm.enumerator(atPath: root) else { return }
            while let rel = e.nextObject() as? String {
                let path = (root as NSString).appendingPathComponent(rel)
                let attributes = e.fileAttributes
                let r = rule(rel, path, attributes?[.type] as? FileAttributeType == .typeRegular)
                guard r.record || r.watched else { continue }
                // A folder's own size changes with its entries, which are recorded themselves: folders count as -2.
                let size = attributes?[.type] as? FileAttributeType == .typeDirectory
                    ? -2 : (attributes?[.size] as? NSNumber)?.intValue ?? -1
                if r.record { full[path] = size } else { watched[path] = size }
            }
        }
        let own = Set(ownRoots), watch = Set(watchedRoots)
        for root in own.union(watch) {
            walk(root) { rel, path, regular in
                if own.contains(root), isOwn(rel, ids) { return (true, false) }
                return (false, watch.contains(root) && isWatched(rel, path: path, regularFile: regular))
            }
        }
        for root in Set(extra + [PrivateTemp.folder]) { walk(root) { _, _, _ in (true, false) } }
        var s = FileSnapshot()
        s.entries = watched.merging(full) { _, f in f }
        s.watchedOnly = Set(watched.keys).subtracting(full.keys)
        return s
    }

    /// The paths that differ (added, removed or resized; for rule-3-only entries: added or resized), sorted.
    static func difference(_ a: FileSnapshot, _ b: FileSnapshot) -> [String] {
        Set(a.entries.keys).union(b.entries.keys).filter { k in
            a.entries[k] != b.entries[k] && !(b.entries[k] == nil && a.watchedOnly.contains(k))
        }.sorted()
    }

    /// Positive controls (each must be seen, with its size): a file in `Caches/<identifier>/` and one named
    /// `Caches/<identifier>.<suffix>` for the host's (`com.apple.dt.xctest.tool`) and the test bundle's identifiers; one
    /// in each extra folder and two levels deep in the private temporary folder; in each rule-3 root a file named
    /// `faceblur-snapshot-control-*` and, one level deep under a neutral name, a file with JPEG magic bytes; in the
    /// shared `tmp` also PNG and HEIF magic bytes and an image extension. Negative control: a neutral file next to them
    /// is not seen. Their removal is a difference for rules 1-2, and not for rule-3-only entries.
    static func assertSeesHostFolders(extra: [String] = []) throws {
        XCTAssertTrue(ownIdentifiers.contains("com.apple.dt.xctest.tool"), "the XCTest host: \(ownIdentifiers)")
        XCTAssertEqual(ownIdentifiers.count, 2, "the host's and the test bundle's identifiers: \(ownIdentifiers)")
        XCTAssertEqual(Set(watchedRoots).count, 4, "shared tmp, Caches, Application Support, Documents: \(watchedRoots)")
        let fm = FileManager.default
        let caches = try XCTUnwrap(directory(.cachesDirectory))
        let tag = UUID().uuidString
        let control = "faceblur-snapshot-control-\(tag)"
        let neutral = "snapctl-\(tag)"
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        var full: [String: Data] = [:], watched: [String: Data] = [:], unseen: [String] = []
        var created: [String] = []
        func folder(_ path: String) throws {
            guard !fm.fileExists(atPath: path) else { return }
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
            created.append(path)
        }
        for id in ownIdentifiers {
            try folder(caches + "/" + id)
            full[caches + "/" + id + "/" + control] = Data([1])
            full[caches + "/" + id + "." + control] = Data([1])
        }
        for e in extra { full[e + "/" + control] = Data([1]) }
        let join = { (root: String, rel: String) in (root as NSString).appendingPathComponent(rel) }
        let privateDeep = join(PrivateTemp.folder, neutral)
        try folder(privateDeep)
        try folder(join(privateDeep, "inner"))
        full[join(privateDeep, "inner/control")] = Data([1])
        for root in Set(watchedRoots) {
            try folder(join(root, neutral))
            watched[join(root, control)] = Data([1])
            watched[join(root, neutral + "/control.bin")] = jpeg
            unseen.append(join(root, neutral + "/neutral.bin"))
        }
        let sharedDeep = join(PrivateTemp.shared, neutral)
        watched[join(sharedDeep, "control-png.bin")] = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])
        watched[join(sharedDeep, "control-heif.bin")] = Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))
        watched[join(sharedDeep, "control.heic")] = Data([1])
        defer {
            for p in Array(full.keys) + Array(watched.keys) + unseen { try? fm.removeItem(atPath: p) }
            for f in created.reversed() { try? fm.removeItem(atPath: f) }
        }
        for (p, d) in full.merging(watched, uniquingKeysWith: { a, _ in a }) {
            XCTAssertTrue(fm.createFile(atPath: p, contents: d), p)
        }
        for p in unseen { XCTAssertTrue(fm.createFile(atPath: p, contents: Data([1, 2, 3])), p) }
        let seen = take(extra: extra)
        for (p, d) in full.merging(watched, uniquingKeysWith: { a, _ in a }) {
            XCTAssertEqual(seen[p], d.count, "the snapshot sees \(p)")
        }
        for p in unseen { XCTAssertNil(seen[p], "a neutral file is not recorded: \(p)") }
        for p in Array(full.keys) + Array(watched.keys) + unseen { try? fm.removeItem(atPath: p) }
        let removed = Set(difference(seen, take(extra: extra)))
        for p in full.keys { XCTAssertTrue(removed.contains(p), "removal is a difference: \(p)") }
        for p in watched.keys { XCTAssertFalse(removed.contains(p), "removal of a rule-3 entry is not: \(p)") }
    }
}

final class SnapshotAnchor {}
