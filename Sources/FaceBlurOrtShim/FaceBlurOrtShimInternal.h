// SPDX-License-Identifier: Apache-2.0
// Internal to the shim and the package's own tests; not part of the public header.
#ifndef FACEBLUR_ORT_SHIM_INTERNAL_H
#define FACEBLUR_ORT_SHIM_INTERNAL_H

#include <onnxruntime/onnxruntime_c_api.h>
#include <stdint.h>

/// Creates the process environment through `api`: logging at "fatal" only, telemetry events disabled (ADR 0010,
/// telemetry amendment of 2026-11-11). Returns FB_ORT_OK with `*out` set; FB_ORT_NOT_CREATED when the environment
/// cannot be created; FB_ORT_OPTION_FAILED when telemetry cannot be disabled, after releasing the environment. On
/// every failure `*out` is NULL, so no session can be created.
int32_t fb_ort_create_env(const OrtApi *api, OrtEnv **out);

#endif
