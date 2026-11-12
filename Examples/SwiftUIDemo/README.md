<!-- SPDX-License-Identifier: Apache-2.0 -->
# FaceBlur SwiftUI demo

A small SwiftUI app that shows the order of the calls in the Swift API of FaceBlur: choose and confirm a model,
pick a photo, detect faces, edit the masks with buttons, mask and save a JPEG. It covers faces with opaque masks and
writes a JPEG without metadata. Detection can miss faces, so check every result before you share it. FaceBlur
contains no network code.

The demo uses only the public `FaceBlur` module (async/await and Swift errors). `FaceBlurEngine.swift` is the only
file that imports it; the rest of the app does not know the library, which is how the unit tests replace it.

## Run it

1. Build the XCFramework once and put it at `Binaries/FaceBlurCore.xcframework` in the package root (development
   setup of the package; see its `Package.swift`).
2. Open `Examples/SwiftUIDemo/SwiftUIDemo.xcodeproj` in Xcode (the project refers to the package two folders up).
3. Choose an iOS 18 or newer simulator (Apple silicon only: the XCFramework has no x86_64 slice) or device and run. On a device, set your own signing team on the target.
4. Get a face-detection model in YuNet layout (an `.onnx` file) from its publisher and copy it where the Files app
   can reach it. The demo does not ship a model or a photo.

## What the app does

1. **Model.** "Choose model file" opens the system file picker. The demo shows the file name, size and the full
   SHA-256 in 4 lines of 16 digits. Only "Use this model" loads it, and only with exactly that hash; every other way
   out loads nothing. The model file is read where it is; the app makes no copy.
2. **Photo.** "Choose a photo" opens the system photo picker (`PhotosPicker`). It is disabled with "Choose a model first" until a model is loaded.
3. **Upright pixels.** `UIImage.cgImage` ignores the orientation, so the demo draws the photo upright with
   `UIImage.draw` first (the example in the `FaceMasker` documentation) and works at a long side of at most 3,500
   pixels.
4. **Review.** Faces are shown as solid outlines (F1, F2, ...), masks as dashed outlines (M1, M2, ...). Every mask
   has "Remove mask" / "Restore mask"; "Add a mask" creates one in the middle that you move and resize with buttons
   (no gestures); "Undo" takes back one edit.
5. **Save.** "Apply masks and save JPEG" masks a fresh copy of the upright photo with `applyMasks(_:to:)`, encodes it
   from pixels with ImageIO, removes every application segment the encoder adds, and opens the system exporter. The
   app holds the JPEG in memory and writes no file itself. The system exporter, however, stages the JPEG as a file in
   the app's own temporary folder while it is open (observed on the simulator, see "Files in the app's storage"); the
   app deletes that file when the exporter closes and again at the next launch. Besides that staged file (deleted as
   described), the only copy is the file you save.

## Privacy

- No network code and no network declarations; no location; no logging; no analytics.
- The app switcher shows a plain cover instead of the photo (the iOS counterpart of Android's FLAG_SECURE): an
  opaque window covers the screen whenever the scene is not active.
- `Config/Info.plist` has the photo purpose string and nothing for network, location or tracking; `PrivacyInfo.xcprivacy`
  declares no tracking and no collected data.
- `scripts/check-demo.sh` checks these points statically. The only file code is `StagedFiles.swift`, which can only
  list and delete; the script rejects anything else in it.

### Files in the app's storage

Observed on the iOS 18.0 and iOS 27.0 simulators with the real system photo picker and the real system file exporter
(UI test `testNothingButTheExportIsLeftBehindAfterPickMaskAndSave`, which lists the app's data container at any depth
after the launch, the pick, while the exporter is open, after the save and after "Choose another photo", and once
more after a cancelled export):

- The photo picker delivers the photo to the app in memory; no file appears in the app's container.
- The file exporter creates the masked JPEG (about 41 KB for the test photo) in the app's `tmp/` when it opens:
  `tmp/masked-photo.jpeg` on iOS 18.0, `tmp/<UUID>/masked-photo.jpeg` on iOS 27.0.
  When you save, the system moves that file to the place you chose and nothing stays in the container. When you cancel,
  the system leaves it in `tmp/`. The app deletes it (and its UUID folder) as soon as the exporter closes and at the
  next launch; without that deletion the files stayed after every cancel, which the UI test `testReviewEditAndSave`
  catches. How long the system keeps a staged file in `tmp/` on its own was not measured.
- What remains in the container is what the system creates for every app: container metadata, launch snapshots
  (`Library/SplashBoard`) and small UI state-restoration records (`Library/Saved Application State`).
- The file you save is written by the system where you choose, outside the app's container.
- Not covered: files the system itself keeps outside the app's container (for example in the Photos library or the
  Files storage), a physical device (not run), and iOS versions other than 18.0 and 27.0.

## Tests

- Unit tests (`SwiftUIDemoTests`): the view model against a fake engine, the pixel helpers, wording, the privacy
  declarations, and the real engine against a test model and a registered public fixture. The integration tests
  need `TEST_RUNNER_FACEBLUR_MODEL` (the test model file, supplied by the maintainer) and `TEST_RUNNER_FACEBLUR_TESTDATA` (the `testdata` folder
  of the `faceblur` repository) in the environment.
- UI tests (`SwiftUIDemoUITests`): additionally `TEST_RUNNER_FACEBLUR_PHOTO` (a fixture image) and optionally
  `TEST_RUNNER_FACEBLUR_SCREENSHOT_DIR`. Debug builds read `FACEBLUR_DEMO_MODEL` and `FACEBLUR_DEMO_PHOTO` at launch
  to stand in for the two system pickers; this code is compiled out of Release builds.

```
xcodebuild test -project SwiftUIDemo.xcodeproj -scheme SwiftUIDemo -destination 'platform=iOS Simulator,name=<device>'
```
