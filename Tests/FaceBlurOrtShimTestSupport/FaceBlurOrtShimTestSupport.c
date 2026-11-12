// SPDX-License-Identifier: Apache-2.0
#include "FaceBlurOrtShimTestSupport.h"

#include "../../Sources/FaceBlurOrtShim/FaceBlurOrtShimInternal.h"

#include <onnxruntime/onnxruntime_c_api.h>
#include <stddef.h>

static const OrtApi *g_real;
static OrtEnv *g_made;
static int32_t g_created;
static int32_t g_released;

static OrtStatus *ORT_API_CALL counting_create_env(OrtLoggingLevel level, const char *id, OrtEnv **out) {
    OrtStatus *status = g_real->CreateEnv(level, id, out);
    if (status == NULL) {
        g_created++;
        g_made = *out;
    }
    return status;
}

static OrtStatus *ORT_API_CALL failing_disable_telemetry(const OrtEnv *environment) {
    (void)environment;
    return g_real->CreateStatus(ORT_FAIL, "telemetry switch failed (test)");
}

static void ORT_API_CALL counting_release_env(OrtEnv *environment) {
    if (environment != NULL && environment == g_made) g_released++;
    g_real->ReleaseEnv(environment);
}

int32_t fb_ort_test_create_env(int32_t fail_telemetry, int32_t *handed_out, int32_t *created, int32_t *released) {
    const OrtApiBase *base = OrtGetApiBase();
    g_real = base != NULL ? base->GetApi(ORT_API_VERSION) : NULL;
    if (g_real == NULL) return -1;
    OrtApi api = *g_real;
    api.CreateEnv = counting_create_env;
    api.ReleaseEnv = counting_release_env;
    if (fail_telemetry) api.DisableTelemetryEvents = failing_disable_telemetry;
    g_made = NULL;
    g_created = 0;
    g_released = 0;
    OrtEnv *out = (OrtEnv *)(uintptr_t)1; // must be reset to NULL on failure
    int32_t status = fb_ort_create_env(&api, &out);
    *handed_out = out != NULL;
    if (out != NULL && out != (OrtEnv *)(uintptr_t)1) api.ReleaseEnv(out);
    *created = g_created;
    *released = g_released;
    return status;
}
