<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The project follows
[Semantic Versioning](https://semver.org/); the API is not stable before 1.0, and breaking changes are listed here.

## [0.1.0] - Unreleased

First release. It has the same version number as the Maven artifact `io.github.shishark:faceblur`, whose library is
packaged here as the `FaceBlurCore` framework.

### Added

- The Swift package `FaceBlur` for iOS 18 and newer (Swift 6.2): a hand-written Swift facade over the library with
  `async` methods and Swift errors, and no Kotlin type in its public API.
- `FaceMasker` (an actor): `detect`, `maskInPlace`, `applyMasks` and `checkProfile` for a `CGContext` or a locked
  `CVPixelBuffer`; `mask(_:orientation:)` for a `CGImage` (masks a copy and returns an upright image);
  `FaceMasker.encodeJPEG` (pixels only, no metadata); and file mode with `detectFile(at:)` and `maskFile(at:to:)`, which
  write a new JPEG without the source's metadata (unless an allow-list is given with `MetadataPolicy.keepAllowlist`) and
  replace the destination in one step. Calls run on a private serial queue of each masker, never on the main thread,
  and are cancelled with Swift task cancellation. `PlanMasker` is for apps that bring their own detector.
- `DetectorModel` and `DetectorProfile`: the app supplies the model (`ModelSource.data` or `.file`), describes it
  (`DetectionFormat.yuNetLayout` or `.genericDetections`), and gives the expected SHA-256; a model with another hash is
  refused with `FaceMaskError.modelIntegrity` before it is parsed. FaceBlur ships no model.
- Masks are opaque. `MaskingConfiguration` (style, shape, expansion, feather) can only make masks larger than the
  defaults: a face's mask is 1.6 times the width and 1.8 times the height of its box by default, and these defaults are
  also the smallest values allowed (`expandX`/`expandY` and `DetectorProfile.minMaskExpandX`/`minMaskExpandY` accept
  1.6 / 1.8 to 3.0; smaller values throw `FaceMaskError.invalidConfiguration(parameter:)`).
- `FaceMaskError`, the one error type, with one case per error of the library; messages never contain paths, file
  names, pixel data or coordinates.
- ONNX Runtime 1.20.0 (Microsoft's Swift package, pinned exactly) with the model session created from verified bytes in
  memory; no model file is written. The product `FaceBlurOrtShim` is for Kotlin Multiplatform apps that register the
  runtime bridge themselves.
- A privacy manifest (`PrivacyInfo.xcprivacy`) in the package: no tracking, no collected data.
- `Examples/SwiftUIDemo`, a SwiftUI app that shows the order of the calls: choose and confirm a model, pick a photo,
  detect, edit the masks with buttons, mask and save a JPEG. It declares no network permission.

### Known issues

- Known issue (iOS): FaceBlur runs with ONNX Runtime 1.20.0 on iOS, an older runtime that lacks some later memory-safety fixes. FaceBlur requires the SHA-256 of your model and refuses models that reference external data before the runtime reads the file, but it cannot make a malicious model safe: load only models you trust, ship them inside your app and hard-code their hash.
