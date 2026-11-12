// SPDX-License-Identifier: Apache-2.0
import XCTest

@testable import SwiftUIDemo

/// The unit-test bundle runs inside the app, so `temporaryDirectory` is the app's own tmp folder.
final class StagedFilesTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory

    func testTheStagedExportIsRemovedAndOtherFilesAreLeftAlone() throws {
        let staged = folder.appendingPathComponent("\(StagedFiles.exportName).jpeg")
        let other = folder.appendingPathComponent("unrelated-test-file.bin")
        try Data(repeating: 1, count: 8).write(to: staged)
        try Data(repeating: 2, count: 8).write(to: other)
        defer { try? FileManager.default.removeItem(at: other) }

        StagedFiles.removeExport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the staged export is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "only the export's files are removed")
    }

    func testTheStagedExportInsideAUUIDFolderIsRemovedWithItsFolder() throws {
        let staging = folder.appendingPathComponent(UUID().uuidString)
        let unrelated = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: staging.appendingPathComponent("\(StagedFiles.exportName).jpeg"))
        try Data(repeating: 2, count: 8).write(to: unrelated.appendingPathComponent("other.bin"))
        defer { try? FileManager.default.removeItem(at: unrelated) }

        StagedFiles.removeExport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the staged export and its folder are gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "a folder without the export is left alone")
    }

    func testRemovingWhenNothingIsStagedIsHarmless() {
        StagedFiles.removeExport()
        StagedFiles.removeExport()
    }
}
