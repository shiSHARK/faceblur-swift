#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Static checks for the SwiftUI demo (run from anywhere): the app declares no network access and no location, only
# the FaceBlur public API is used, nothing is logged, and the wording makes only the three claims.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/SwiftUIDemo
fail=0
bad() { echo "FAIL: $1"; fail=1; }

# 1. Info.plist: no network or location declarations, no entitlements file.
plist=$here/Config/Info.plist
for key in NSAppTransportSecurity NSAllowsArbitraryLoads NSLocationWhenInUseUsageDescription \
    NSLocationAlwaysUsageDescription NSUserTrackingUsageDescription UIBackgroundModes; do
  grep -q "<key>$key</key>" "$plist" && bad "Info.plist declares $key"
done
grep -q "<key>NSPhotoLibraryUsageDescription</key>" "$plist" || bad "Info.plist has no photo purpose string"
[ -z "$(find "$here" -name '*.entitlements' -not -path '*/build/*')" ] || bad "an entitlements file exists"
grep -q "CODE_SIGN_ENTITLEMENTS" "$here/SwiftUIDemo.xcodeproj/project.pbxproj" && bad "project sets entitlements"

# 2. No network code in the demo sources.
if grep -nE "URLSession|URLRequest|NWConnection|NWPathMonitor|CFNetwork|Socket|WebKit|WKWebView|import Network|http://|https://" \
    "$src"/*.swift | grep -v "^[^:]*:[0-9]*: *//"; then bad "network API or URL in the demo sources"; fi

# 3. Nothing is logged and nothing is stored by the app. The one exception is StagedFiles.swift, which deletes the file
# the system exporter stages in tmp: it may use FileManager but only to list and remove, never to create or write.
# Each file is passed on its own, quoted, so a space in the path cannot split it; grep exits 0 = hit, 1 = clean, and
# anything else (2 = error, e.g. an unreadable file) is a FAIL, never a pass.
for file in "$src"/*.swift; do
  [ "${file##*/}" = "StagedFiles.swift" ] && continue
  rc=0
  grep -nE "print\(|NSLog|os_log|Logger\(|debugPrint|dump\(|UserDefaults|FileManager|write\(to|\.write\(|NSTemporaryDirectory|temporaryDirectory" \
    "$file" || rc=$?
  case $rc in
    0) bad "logging or storage API in ${file##*/}" ;;
    1) ;;
    *) bad "grep failed (exit $rc) on ${file##*/}" ;;
  esac
done
rc=0
grep -nE "print\(|NSLog|os_log|Logger\(|debugPrint|dump\(|UserDefaults|write\(to|\.write\(|createFile|createDirectory|copyItem|\.moveItem|replaceItem|contents\(atPath|FileHandle|OutputStream" \
  "$src/StagedFiles.swift" || rc=$?
case $rc in
  0) bad "StagedFiles.swift does more than list and remove" ;;
  1) ;;
  *) bad "grep failed (exit $rc) on StagedFiles.swift" ;;
esac

# 4. Only the public Swift API: no Kotlin framework import and no internal import of the package.
if grep -nE "import FaceBlurCore|import FaceBlurOnnxRuntime|import FaceBlurOrtShim|@testable import FaceBlur|internal import" \
    "$src"/*.swift; then bad "the demo uses more than the public FaceBlur API"; fi
files=$(grep -lE "^import FaceBlur$" "$src"/*.swift | wc -l | tr -d ' ')
[ "$files" = "1" ] || bad "FaceBlur is imported in $files files (expected only FaceBlurEngine.swift)"

# 5. Forbidden wording in the strings the person reads.
if grep -niE "anonymi|gdpr|compliant|guarantee" "$src"/Copy.swift; then bad "forbidden wording in Copy.swift"; fi

# 6. The debug hooks are compiled out of Release.
head -3 "$src/DebugLaunchHooks.swift" | grep -q "^#if DEBUG" || bad "launch hooks are not inside #if DEBUG"
grep -q "DebugLaunchHooks" "$src/SwiftUIDemoApp.swift" && ! grep -B1 "DebugLaunchHooks" "$src/SwiftUIDemoApp.swift" | grep -q "#if DEBUG" && bad "hook call outside #if DEBUG"

[ "$fail" = 0 ] && echo "PASS: demo static checks" && exit 0
exit 1
