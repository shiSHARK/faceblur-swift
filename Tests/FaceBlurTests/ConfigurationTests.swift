// SPDX-License-Identifier: Apache-2.0
@testable import FaceBlur
import XCTest

/// ADR 0011 decision 2: every range is checked in Swift first; the internal unchecked path skips the Swift check and
/// gets the same case from the library, bound by bound.
final class ConfigurationTests: XCTestCase {
    // Before any NSTemporaryDirectory() call of this process (see PrivateTemp).
    override class func setUp() {
        super.setUp()
        PrivateTemp.install()
    }

    private func swiftError(_ body: () throws -> Void) -> FaceMaskError? {
        do {
            try body()
            return nil
        } catch let e as FaceMaskError {
            return e
        } catch {
            XCTFail("only FaceMaskError may cross, got \(type(of: error))")
            return nil
        }
    }

    func testMaskingBoundsMatchTheLibrary() {
        let rows: [(Float, Float, Float, String?)] = [
            (1.6, 1.8, 0.10, nil), (3.0, 3.0, 0.5, nil), (1.6, 1.8, 0, nil),
            (1.59, 1.8, 0.10, "expandX"), (Float(1.6).nextDown, 1.8, 0.10, "expandX"), (1.35, 1.55, 0.10, "expandX"),
            (3.01, 1.8, 0.10, "expandX"), (.nan, 1.8, 0.10, "expandX"),
            (1.6, Float(1.8).nextDown, 0.10, "expandY"), (1.6, 3.01, 0.10, "expandY"),
            (1.6, 1.8, -0.01, "feather"), (1.6, 1.8, 0.51, "feather"),
        ]
        for (x, y, f, parameter) in rows {
            let expected = parameter.map { FaceMaskError.invalidConfiguration(parameter: $0) }
            XCTAssertEqual(swiftError { _ = try MaskingConfiguration(expandX: x, expandY: y, feather: f) }, expected)
            let unchecked = MaskingConfiguration(unchecked: .solid, .rectangle, x, y, f, .neutralGray)
            XCTAssertEqual(swiftError { _ = try unchecked.kotlin() }, expected, "library, \(x) \(y) \(f)")
        }
    }

    /// The mask expansion: default 1.6 / 1.8, which is also the smallest accepted value, for the masking and for the
    /// profile's raise-only floor. Each value passes the facade's check and then the library's (`kotlin()` in the
    /// initialisers); the library side alone is in ErrorMappingTests.
    func testMaskExpansionDefaultsAndFloors() throws {
        XCTAssertEqual(MaskingConfiguration.default.expandX, 1.6)
        XCTAssertEqual(MaskingConfiguration.default.expandY, 1.8)
        XCTAssertEqual(try MaskingConfiguration(), MaskingConfiguration.default)
        let profile = try DetectorProfile(format: .yuNetLayout, inputWidth: 640, inputHeight: 640, scoreThreshold: 0.5,
                                          expectedSHA256: Fixture.yunetSha256)
        XCTAssertEqual(profile.minMaskExpandX, 1.6)
        XCTAssertEqual(profile.minMaskExpandY, 1.8)
        XCTAssertEqual(profile.minMaskExpandX, MaskingConfiguration.default.expandX)
        XCTAssertEqual(profile.minMaskExpandY, MaskingConfiguration.default.expandY)

        let rows: [(Float, Float, String?)] = [
            (1.6, 1.8, nil), (3.0, 3.0, nil),
            (1.59, 1.8, "minMaskExpandX"), (Float(1.6).nextDown, 1.8, "minMaskExpandX"),
            (1.35, 1.55, "minMaskExpandX"), (3.01, 1.8, "minMaskExpandX"),
            (1.6, Float(1.8).nextDown, "minMaskExpandY"), (1.6, 3.01, "minMaskExpandY"),
        ]
        for (x, y, parameter) in rows {
            let expected = parameter.map { FaceMaskError.invalidConfiguration(parameter: $0) }
            XCTAssertEqual(swiftError {
                _ = try DetectorProfile(format: .yuNetLayout, inputWidth: 640, inputHeight: 640, scoreThreshold: 0.5,
                                        expectedSHA256: Fixture.yunetSha256, minMaskExpandX: x, minMaskExpandY: y)
            }, expected, "\(x) \(y)")
        }
    }

    func testThreadsBoundsMatchTheLibrary() {
        for (threads, ok) in [(0, true), (4, true), (-1, false), (5, false)] {
            let expected: FaceMaskError? = ok ? nil : .invalidConfiguration(parameter: "onnxThreads")
            XCTAssertEqual(swiftError { _ = try FaceMaskerConfiguration(onnxThreads: threads) }, expected)
            XCTAssertEqual(swiftError { _ = try FaceMaskerConfiguration(unchecked: .default, threads).kotlin() },
                           expected)
        }
    }

    func testFileOptionsBoundsMatchTheLibrary() {
        let rows: [(Int, Int, Int, Int, String?)] = [
            (3_500, 0, 25_000_000, 90, nil), (0, 64, 13_000_000, 1, nil), (9_000, 0, 100_000_000, 100, nil),
            (3_499, 0, 25_000_000, 90, "maxLongSide"), (1, 0, 25_000_000, 90, "maxLongSide"),
            (3_500, 63, 25_000_000, 90, "maxOutputLongSide"),
            (3_500, 0, 12_999_999, 90, "maxDecodedPixels"), (3_500, 0, 100_000_001, 90, "maxDecodedPixels"),
            (3_500, 0, 25_000_000, 0, "quality"), (3_500, 0, 25_000_000, 101, "quality"),
        ]
        for (side, out, pixels, quality, parameter) in rows {
            let expected = parameter.map { FaceMaskError.invalidConfiguration(parameter: $0) }
            XCTAssertEqual(swiftError {
                _ = try FileOptions(maxLongSide: side, maxOutputLongSide: out, maxDecodedPixels: pixels,
                                    format: .jpeg(quality: quality))
            }, expected)
            let unchecked = FileOptions(unchecked: side, out, pixels, .jpeg(quality: quality), .stripAll)
            XCTAssertEqual(swiftError { _ = try unchecked.kotlin() }, expected, "library, \(side) \(out) \(pixels)")
        }
        XCTAssertEqual(swiftError { _ = try FileOptions(metadata: .keepAllowlist()) },
                       .invalidConfiguration(parameter: "metadata"))
        XCTAssertNil(swiftError { _ = try FileOptions(metadata: .keepAllowlist(dateTime: true)) })
    }

    func testProfileHasNoDefaultHashAndChecksIt() {
        func make(_ sha: String, w: Int = 640, t: Float = 0.5) -> FaceMaskError? {
            swiftError { _ = try DetectorProfile(format: .yuNetLayout, inputWidth: w, inputHeight: 640,
                                                 scoreThreshold: t, expectedSHA256: sha) }
        }
        XCTAssertNil(make(Fixture.yunetSha256.uppercased()))
        XCTAssertEqual(make(String(Fixture.yunetSha256.dropLast())), .invalidConfiguration(parameter: "expectedSha256"))
        XCTAssertEqual(make(String(repeating: "g", count: 64)), .invalidConfiguration(parameter: "expectedSha256"))
        XCTAssertEqual(make(Fixture.yunetSha256, w: 650), .invalidConfiguration(parameter: "inputWidth"))
        XCTAssertEqual(make(Fixture.yunetSha256, t: 1), .invalidConfiguration(parameter: "scoreThreshold"))
        XCTAssertEqual(try? DetectorProfile(format: .yuNetLayout, inputWidth: 640, inputHeight: 640,
                                            scoreThreshold: 0.5, expectedSHA256: Fixture.yunetSha256.uppercased())
            .expectedSHA256, Fixture.yunetSha256)
    }

    func testColourIsOpaqueByConstruction() throws {
        XCTAssertEqual(MaskColor.neutralGray.argb, Int32(bitPattern: 0xFF7F_7F7F))
        XCTAssertEqual(MaskColor(red: 1, green: 2, blue: 3).argb, Int32(bitPattern: 0xFF01_0203))
        let k = try MaskingConfiguration(color: MaskColor(red: 1, green: 2, blue: 3)).kotlin()
        XCTAssertEqual(k.color, Int32(bitPattern: 0xFF01_0203))
        XCTAssertEqual(MaskingConfiguration.default, try MaskingConfiguration())
        XCTAssertEqual(FileOptions.default, try FileOptions())
        XCTAssertEqual(FaceMaskerConfiguration.default, try FaceMaskerConfiguration())
    }

    /// ADR 0011 decision 4: the facade never runs a bridge it does not know.
    func testRegistrationAndVersionRule() {
        var calls = 0
        XCTAssertTrue(Runtime.decide(register: { calls += 1; return true },
                                     libraryVersion: Runtime.expectedLibraryVersion))
        XCTAssertFalse(Runtime.decide(register: { calls += 1; return false },
                                      libraryVersion: Runtime.expectedLibraryVersion), "another factory first")
        XCTAssertFalse(Runtime.decide(register: { calls += 1; return true }, libraryVersion: "0.0.0"))
        XCTAssertEqual(calls, 2, "no registration for a library of another version")
    }
}
