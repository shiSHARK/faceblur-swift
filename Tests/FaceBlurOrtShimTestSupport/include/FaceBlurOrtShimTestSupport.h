// SPDX-License-Identifier: Apache-2.0
// Test support for the package's own tests only (not a product).
#ifndef FACEBLUR_ORT_SHIM_TEST_SUPPORT_H
#define FACEBLUR_ORT_SHIM_TEST_SUPPORT_H

#include <stdint.h>

/// Runs the shim's environment creation with the linked runtime's API table, in which DisableTelemetryEvents fails
/// when `fail_telemetry` is 1. Reports whether the shim handed out an environment, and how many environments were
/// created and released. Every environment created here is released before returning.
int32_t fb_ort_test_create_env(int32_t fail_telemetry, int32_t *handed_out, int32_t *created, int32_t *released);

#endif
