#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Source check of the ONNX Runtime glue (ADR 0010 decision 2): no logging or network names, none of the runtime calls
# that write files or load extra code (optimised-model path, profiling, custom operators, external initializers,
# path-based sessions), only allow-listed session configuration keys, and no literal runtime version.
# Usage: sh config/check-glue-sources.sh [sources dir]   (default: Sources). Exit 0 = clean, 1 = finding.
set -u
dir=${1:-Sources}
[ -d "$dir" ] || { echo "check-glue-sources: no directory $dir" >&2; exit 2; }
fail=0
banned='NSLog|os_log|\bprint\(|\bLogger\b|\bprintf\(|fprintf|\bputs\(|URLSession|NSURLConnection|CFNetwork|import Network\b|\bsocket\(|\bconnect\(|SetOptimizedModelFilePath|optimized_model|EnableProfiling|RegisterCustomOps|registerCustomOps|AddExternalInitializers|AddInitializer|CreateSession\(|CreateSessionWithPrepackedWeightsContainer\(|modelPath|ORTSession\(|ep\.context|use_ort_model_bytes|onnxruntime_extensions|CoreML|AppendExecutionProvider_CoreML|session\.save_model_format'
if grep -rnE "$banned" "$dir" --include='*.swift' --include='*.c' --include='*.h' --include='*.m' --include='*.mm'; then
    echo "check-glue-sources: FAIL banned name above" >&2
    fail=1
fi
allowed='session.load_model_format session.allow_released_opsets_only session.intra_op.allow_spinning'
keys=$(grep -rhoE 'AddSessionConfigEntry\([^,]+, *"[^"]*"' "$dir" | sed 's/.*"\([^"]*\)"$/\1/' | sort -u)
for k in $keys; do
    case " $allowed " in
        *" $k "*) ;;
        *) echo "check-glue-sources: FAIL configuration key not allowed: $k" >&2; fail=1 ;;
    esac
done
for k in $allowed; do
    echo "$keys" | grep -qx "$k" || { echo "check-glue-sources: FAIL required key missing: $k" >&2; fail=1; }
done
if grep -rnE 'func runtimeVersion\(\)[^{]*\{ *"' "$dir"; then
    echo "check-glue-sources: FAIL runtimeVersion() returns a literal" >&2
    fail=1
fi
grep -rq 'ORT_LOGGING_LEVEL_FATAL' "$dir" || { echo "check-glue-sources: FAIL logging level fatal not set" >&2; fail=1; }
grep -rq 'DisableTelemetryEvents' "$dir" || { echo "check-glue-sources: FAIL telemetry events not disabled" >&2; fail=1; }
[ "$fail" = 0 ] && echo "check-glue-sources: PASS"
exit "$fail"
