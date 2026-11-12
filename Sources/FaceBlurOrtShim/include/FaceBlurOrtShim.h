// SPDX-License-Identifier: Apache-2.0
// The ONNX Runtime 1.20.0 C API behind the FaceBlur glue (ADR 0010): a session is created from model bytes in
// memory, so no model file, cache or optimised model is ever written. Only status codes leave these functions,
// never runtime error text (it can contain paths).
#ifndef FACEBLUR_ORT_SHIM_H
#define FACEBLUR_ORT_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Status codes, equal to the Kotlin `OnnxBridge` codes.
enum {
    FB_ORT_OK = 0,
    FB_ORT_NOT_CREATED = 1,
    FB_ORT_RUN_FAILED = 2,
    FB_ORT_OUTPUT_INVALID = 3,
    FB_ORT_NOT_OPEN = 4,
    FB_ORT_INVALID_ARGUMENTS = 5,
    FB_ORT_NAMES_DIFFER = 6,
    FB_ORT_OPTION_FAILED = 7,
};

/// Int64 values per output-table row (buffer address, capacity, bytes written, element type, rank, four dims).
#define FB_ORT_ROW_LONGS 9

typedef struct fb_ort_session fb_ort_session;

/// Opens a session from `model_byte_count` bytes at `model` (read during this call only). `input_shape` has rank 4.
/// XNNPACK with `threads` worker threads (0 = min(4, active cores)) is tried first, then the CPU provider.
/// On success `*out` is the session and `*xnnpack` is 1 if XNNPACK is used. FB_ORT_OPTION_FAILED when a required
/// option, or disabling the runtime's telemetry events, failed; no session is created then.
int32_t fb_ort_open(const void *model, int64_t model_byte_count, int32_t threads, const char *input_name,
                    const int64_t *input_shape, int32_t input_rank, const char *const *output_names,
                    int32_t output_count, int32_t active_cores, fb_ort_session **out, int32_t *xnnpack);

/// One pass: wraps `input` (exactly the open shape × 4 bytes) without a copy, runs, and copies every output into its
/// table row's buffer. Type, rank and dims are written to the row also when the status is FB_ORT_OUTPUT_INVALID.
int32_t fb_ort_run(fb_ort_session *session, void *input, int64_t input_byte_count, int64_t *table);

/// Releases the session (NULL is ignored).
void fb_ort_close(fb_ort_session *session);

/// The linked runtime's version string (static storage), or "" if the runtime is unavailable.
const char *fb_ort_version(void);

#ifdef __cplusplus
}
#endif

#endif
