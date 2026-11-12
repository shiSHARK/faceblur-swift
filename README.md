<!-- SPDX-License-Identifier: Apache-2.0 -->
# faceblur-swift

`faceblur-swift` is the Swift package of [FaceBlur](https://github.com/shiSHARK/faceblur). It finds faces in a photo
with a face-detection model that your app provides, covers each face with an opaque mask, and writes the result as a
new JPEG without the source file's metadata. It runs on the device, on iOS, and has a Swift API (`async` methods and
Swift errors; no Kotlin type is visible).

FaceBlur is a tool for data minimisation: it reduces what a photo shows before you store or share it. Detection can
miss faces, and masks cover only the faces that the model finds. Check the result before you share a photo.

## What it does

- **Opaque masks only.** A face is covered by an opaque mask. There is no blur, no pixelation and no transparent or
  partial style, and no setting can make a mask smaller than the default: a mask is 1.6 times the width and 1.8 times
  the height of the face box by default, and can only be made larger (up to 3.0).
- **Metadata removed.** File mode builds the output JPEG from the masked pixels. It carries none of the source file's
  metadata, unless you explicitly keep a group (GPS, date and time, camera) with an allow-list; each group keeps
  personal data in the output.
- **No network code.** FaceBlur contains no network code of its own.
- **Two API modes.** *File mode* (`maskFile`) reads a JPEG, HEIC or PNG file, masks it and writes a new JPEG.
  *In-memory mode* (`mask`, `maskInPlace`, `applyMasks`) masks a `CGImage`, a `CGContext` or a `CVPixelBuffer`.
- **Fail closed.** If something goes wrong, the call throws a `FaceMaskError` and does not hand out an image that looks
  masked.

## What it does not do

- It does not ship a face-detection model. Your app chooses one, describes it in a `DetectorProfile`, bundles it and
  hard-codes its SHA-256; a file with another hash is refused before it is parsed. The model, its licence and its
  training data are your responsibility.
- It does not guarantee that every face is found, and it does not judge whether your model, profile or score threshold
  suits your photos. This release publishes no detection results; measure your own setup on your own photos.
- It does not change a photo in any other way, and in-memory mode does not write metadata: the encoder you use decides
  what a file contains.
- It writes nothing to disk except the masked output file (and, for a safe overwrite, a temporary file of the masked
  output next to the destination).
- It is not an assessment of your legal obligations.

## Requirements and install

iOS 18 or newer, and a Swift 6.2 toolchain (Xcode with Swift 6.2). The package depends on ONNX Runtime 1.20.0
(Microsoft's `onnxruntime-swift-package-manager`, pinned exactly) and brings the FaceBlur library as a binary
framework.

In Xcode: File > Add Package Dependencies, enter `https://github.com/shiSHARK/faceblur-swift` and choose "Up to Next
Minor Version" from `0.1.0`. In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/shiSHARK/faceblur-swift", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "FaceBlur", package: "faceblur-swift")]),
]
```

Kotlin Multiplatform apps do not use the `FaceBlur` product: they depend on the Maven artifact
`io.github.shishark:faceblur` and add only the product `FaceBlurOrtShim`. See the
[Kotlin Multiplatform guide](https://github.com/shiSHARK/faceblur/blob/main/docs/guides/kmp-ios.md).

## Quick start

Bundle your model in the app, put its SHA-256 (`shasum -a 256 model.onnx`) in your code, and call FaceBlur from an
`async` context:

```swift
import FaceBlur
import Foundation

// The SHA-256 of YOUR model file, hard-coded in your app. This placeholder matches no file, so loading fails with
// `FaceMaskError.modelIntegrity` until you replace it.
let modelSHA256 = "0000000000000000000000000000000000000000000000000000000000000000"

func maskPhoto(modelURL: URL, source: URL, output: URL) async throws -> Int {
    let profile = try DetectorProfile(
        format: .yuNetLayout,            // the output layout of YOUR model
        inputWidth: 640, inputHeight: 640,
        scoreThreshold: 0.5,             // example value: choose it with your own photos
        expectedSHA256: modelSHA256)
    let model = try await DetectorModel(source: .file(modelURL), profile: profile)
    let masker = try await FaceMasker(model: model)
    defer { masker.close() }
    let result = try await masker.maskFile(at: source, to: .newFile(output))
    return result.masks.count // detection can miss faces: let the person check the result
}
```

The calls run on a private queue, never on the main thread. Cancel with Swift task cancellation. After any error, or
after `CancellationError`, treat the photo as not masked and never publish the original instead.

## Guides

The guides are in the [faceblur repository](https://github.com/shiSHARK/faceblur/tree/main/docs/guides):
[FaceBlur in a Swift app](https://github.com/shiSHARK/faceblur/blob/main/docs/guides/swift.md),
[Providing your model](https://github.com/shiSHARK/faceblur/blob/main/docs/guides/providing-your-model.md),
[Score threshold](https://github.com/shiSHARK/faceblur/blob/main/docs/guides/score-threshold.md) and
[Threading, cancellation and memory](https://github.com/shiSHARK/faceblur/blob/main/docs/guides/threading-and-memory.md).

## Demo app

`Examples/SwiftUIDemo` is a small SwiftUI app that shows the order of the calls: choose and confirm a model, pick a photo,
detect faces, edit the masks with buttons, mask and save a JPEG. See its [README](Examples/SwiftUIDemo/README.md).

## Contributing

Version 0.1.0 accepts issues, not pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Model and training-data licensing

This package is licensed under the Apache License, Version 2.0 (see `LICENSE` and `NOTICE`). The licences of the
third-party components it depends on, including ONNX Runtime (MIT), are listed in `licenses/INDEX.txt`; the licence
texts are in `licenses/` and are packaged in the zip of the FaceBlurCore framework.

FaceBlur does not include a face-detection model and does not download one. The model that your app uses, the licence
of that model and the licence and origin of the data it was trained on are separate from the licence of FaceBlur. They
are your responsibility, and FaceBlur does not check or assess them.
