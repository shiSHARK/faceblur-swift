#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Checks of the Swift facade (ADR 0011 decisions 1, 4a and 9). Usage:
#   config/check-facade.sh                    source checks only
#   config/check-facade.sh <symbol-graph-dir> also checks the public symbols of the built FaceBlur module, extracted
#                                             with `swift-symbolgraph-extract -minimum-access-level public`
# Exit 0 = all checks pass.
set -eu
cd "$(dirname "$0")/.."
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL: $*"; fail=1; }

src=Sources/FaceBlur

# Decision 1: the facade imports the Kotlin module with an access-level import only.
if grep -n '^[[:space:]]*\(@_exported \)\{0,1\}\(public \)\{0,1\}import FaceBlurCore' "$src"/*.swift; then
  bad "FaceBlur must use 'internal import FaceBlurCore'"
fi
for f in "$src"/*.swift; do
  if grep -q 'FaceBlurCore\.' "$f" && ! grep -q '^internal import FaceBlurCore$' "$f"; then
    bad "$f uses FaceBlurCore without 'internal import FaceBlurCore'"
  fi
done

# Decision 9: the unchecked Sendable opt-outs are counted (DetectorModel, KotlinRef).
n=$(grep -c '@unchecked Sendable' "$src"/*.swift | awk -F: '{s += $2} END {print s}')
[ "$n" -eq 2 ] || bad "expected exactly 2 '@unchecked Sendable' in $src, found $n"

# Decision 4a: a CVPixelBuffer is never mapped to a premultiplied layout.
if awk '/kCVPixelFormatType_32(BGRA|RGBA)/ && /Premultiplied/' "$src"/*.swift | grep -q .; then
  bad "a CVPixelBuffer format is mapped to a premultiplied layout"
fi
grep -q 'case kCVPixelFormatType_32BGRA: layout = .bgraNoneSkip' "$src"/PixelCarriers.swift || bad "32BGRA mapping"
grep -q 'case kCVPixelFormatType_32RGBA: layout = .rgbaNoneSkip' "$src"/PixelCarriers.swift || bad "32RGBA mapping"

# No logging or printing in the facade; no Objective-C runtime API of ONNX Runtime anywhere in the facade.
if grep -nE '\b(print|NSLog|os_log|debugPrint)\(|Logger\(' "$src"/*.swift; then bad "logging in the facade"; fi
if grep -rn 'import OnnxRuntimeBindings\|import onnxruntime' Sources/ | grep -v '^Sources/FaceBlurOrtShim/'; then
  bad "the runtime is imported outside the shim"
fi

# Public names never say "anonymi[sz]e".
if grep -rniE 'anonymi[sz]' "$src"; then bad "a name or text says anonymise"; fi

if [ $# -ge 1 ]; then
  graph="$1/FaceBlur.symbols.json"
  [ -s "$graph" ] || { bad "no symbol graph at $graph"; exit 1; }
  if grep -o '"spelling":"[^"]*"' "$graph" | grep -E 'Kotlin|FaceBlurCore|FBC'; then
    bad "a Kotlin or FaceBlurCore type in the public symbols"
  fi
  if grep -iE 'anonymi[sz]' "$graph"; then bad "a public symbol says anonymise"; fi
  say "public symbols: $(grep -o '"precise":"s:8FaceBlur[^"]*"' "$graph" | sort -u | wc -l | tr -d ' ')"
fi

[ "$fail" -eq 0 ] && say "check-facade: PASS"
exit "$fail"
