// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
//
// FaceBlur for Swift apps (ADR 0001, ADR 0010, ADR 0011 decision 7). The only dependency is ONNX Runtime 1.20.0,
// pinned exactly.
// Build with xcodebuild and an iOS destination: the XCFramework has no macOS slice, so host `swift build` cannot link.
//
// The Kotlin XCFramework comes from one of two places:
//  - Released form (the default, what apps get through Swift Package Manager): the FaceBlurCore.xcframework.zip
//    attached to the GitHub Release of the same version, pinned by its SwiftPM checksum.
//  - Development form: Binaries/FaceBlurCore.xcframework, built locally from the faceblur repository and never
//    committed (ignored by git). Select it by setting FACEBLUR_LOCAL_XCFRAMEWORK=1 in the environment of swift /
//    xcodebuild (Xcode: launch it from a shell with the variable set). SwiftPM includes the variable in its manifest
//    cache key, so switching it takes effect without clearing caches.
import Foundation
import PackageDescription

let useLocalXCFramework = ProcessInfo.processInfo.environment["FACEBLUR_LOCAL_XCFRAMEWORK"] == "1"

let faceBlurCore: Target =
    useLocalXCFramework
    ? .binaryTarget(name: "FaceBlurCore", path: "Binaries/FaceBlurCore.xcframework")
    : .binaryTarget(
        name: "FaceBlurCore",
        url: "https://github.com/shiSHARK/faceblur-swift/releases/download/0.1.0/FaceBlurCore.xcframework.zip",
        checksum: "3bc9232179ae576baec934f489ca780dc571a71bb1c4e253d363b7035817677e"
    )

let package = Package(
    name: "FaceBlur",
    platforms: [.iOS(.v18)],
    products: [
        // The product for Swift apps: the hand-written facade (no Kotlin type in its public API).
        .library(name: "FaceBlur", targets: ["FaceBlur"]),
        // The C shim for KMP apps (ADR 0010): an integration seam with no compatibility promise beyond the same
        // FaceBlur version.
        .library(name: "FaceBlurOrtShim", targets: ["FaceBlurOrtShim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.20.0"),
    ],
    targets: [
        faceBlurCore,
        // Every ONNX Runtime C API call (session from model bytes in memory; no model file is ever written).
        .target(
            name: "FaceBlurOrtShim",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),
        // The Swift glue behind the Kotlin OnnxBridge; not a product.
        .target(
            name: "FaceBlurOnnxRuntime",
            dependencies: ["FaceBlurCore", "FaceBlurOrtShim"]
        ),
        // The facade; it imports FaceBlurCore with `internal import`.
        .target(
            name: "FaceBlur",
            dependencies: ["FaceBlurCore", "FaceBlurOnnxRuntime"],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        // Test support only (not a product): runs the shim's environment creation with a modified runtime API table.
        .target(
            name: "FaceBlurOrtShimTestSupport",
            dependencies: [
                "FaceBlurOrtShim",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Tests/FaceBlurOrtShimTestSupport"
        ),
        .testTarget(
            name: "FaceBlurOnnxRuntimeTests",
            dependencies: ["FaceBlurOnnxRuntime", "FaceBlurOrtShim", "FaceBlurCore", "FaceBlurOrtShimTestSupport"]
        ),
        .testTarget(
            name: "FaceBlurTests",
            dependencies: ["FaceBlur", "FaceBlurCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
