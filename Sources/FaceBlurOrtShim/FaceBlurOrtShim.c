// SPDX-License-Identifier: Apache-2.0
#include "FaceBlurOrtShim.h"
#include "FaceBlurOrtShimInternal.h"

#include <onnxruntime/onnxruntime_c_api.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FB_MAX_OUTPUTS 64
#define FB_MAX_NAME 1024
#define FB_MAX_DIMS 16

struct fb_ort_session {
    OrtSession *session;
    OrtMemoryInfo *memory;
    int64_t shape[4];
    int64_t input_bytes;
    char *input_name;
    char *output_names[FB_MAX_OUTPUTS];
    OrtValue *outputs[FB_MAX_OUTPUTS];
    int32_t output_count;
};

static const OrtApi *g_api;
static OrtEnv *g_env;
static int32_t g_init_status = FB_ORT_NOT_CREATED;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

/// Releases a status without reading its message (runtime messages can contain paths); 1 if it was an error.
static int failed(OrtStatus *status) {
    if (status == NULL) return 0;
    g_api->ReleaseStatus(status);
    return 1;
}

int32_t fb_ort_create_env(const OrtApi *api, OrtEnv **out) {
    *out = NULL;
    OrtEnv *created = NULL;
    OrtStatus *status = api->CreateEnv(ORT_LOGGING_LEVEL_FATAL, "faceblur", &created);
    if (status != NULL) {
        api->ReleaseStatus(status);
        return FB_ORT_NOT_CREATED;
    }
    status = api->DisableTelemetryEvents(created);
    if (status != NULL) {
        api->ReleaseStatus(status);
        api->ReleaseEnv(created);
        return FB_ORT_OPTION_FAILED;
    }
    *out = created;
    return FB_ORT_OK;
}

/// One environment per process (fb_ort_create_env); its status is kept and returned by every later open.
static void init_once(void) {
    const OrtApiBase *base = OrtGetApiBase();
    if (base == NULL) return;
    const OrtApi *api = base->GetApi(ORT_API_VERSION);
    if (api == NULL) return;
    OrtEnv *created = NULL;
    int32_t status = fb_ort_create_env(api, &created);
    if (status == FB_ORT_OK) {
        g_api = api;
        g_env = created;
    }
    g_init_status = status;
}

/// FB_ORT_OK when the environment exists; otherwise the status that stops every open (fail closed).
static int32_t ready(void) {
    pthread_once(&g_once, init_once);
    return g_api != NULL && g_env != NULL ? FB_ORT_OK : g_init_status;
}

const char *fb_ort_version(void) {
    const OrtApiBase *base = OrtGetApiBase();
    const char *v = base != NULL ? base->GetVersionString() : NULL;
    return v != NULL ? v : "";
}

/// The locked option list (ADR 0010 decision 2 / ADR 0012 decision 4). Never set: an optimised-model path,
/// profiling, custom operators, external initializers, other providers. Returns FB_ORT_OK, FB_ORT_OPTION_FAILED, or
/// FB_ORT_NOT_CREATED when only the XNNPACK provider could not be added (the caller then uses the CPU provider).
static int32_t make_options(int use_xnnpack, int32_t threads, OrtSessionOptions **out) {
    OrtSessionOptions *o = NULL;
    *out = NULL;
    if (failed(g_api->CreateSessionOptions(&o))) return FB_ORT_OPTION_FAILED;
    int bad = 0;
    bad |= failed(g_api->AddSessionConfigEntry(o, "session.load_model_format", "ONNX"));
    bad |= failed(g_api->AddSessionConfigEntry(o, "session.allow_released_opsets_only", "1"));
    bad |= failed(g_api->AddSessionConfigEntry(o, "session.intra_op.allow_spinning", "0"));
    bad |= failed(g_api->SetSessionGraphOptimizationLevel(o, ORT_ENABLE_ALL));
    bad |= failed(g_api->SetSessionLogSeverityLevel(o, ORT_LOGGING_LEVEL_FATAL));
    bad |= failed(g_api->DisableProfiling(o));
    if (use_xnnpack) {
        bad |= failed(g_api->SetIntraOpNumThreads(o, 1));
    } else if (threads > 0) {
        bad |= failed(g_api->SetIntraOpNumThreads(o, threads));
    }
    if (bad) {
        g_api->ReleaseSessionOptions(o);
        return FB_ORT_OPTION_FAILED;
    }
    if (use_xnnpack) {
        char value[16];
        snprintf(value, sizeof value, "%d", (int)threads);
        const char *keys[] = {"intra_op_num_threads"};
        const char *values[] = {value};
        if (failed(g_api->SessionOptionsAppendExecutionProvider(o, "XNNPACK", keys, values, 1))) {
            g_api->ReleaseSessionOptions(o);
            return FB_ORT_NOT_CREATED;
        }
    }
    *out = o;
    return FB_ORT_OK;
}

static OrtSession *create(const void *model, size_t bytes, OrtSessionOptions *options) {
    OrtSession *s = NULL;
    if (failed(g_api->CreateSessionFromArray(g_env, model, bytes, options, &s))) return NULL;
    return s;
}

/// 1 if the session has exactly one input called `input_name` and exactly the outputs `names`, in this order.
static int names_match(OrtSession *s, const char *input_name, const char *const *names, int32_t count) {
    OrtAllocator *alloc = NULL;
    size_t n = 0;
    if (failed(g_api->GetAllocatorWithDefaultOptions(&alloc))) return 0;
    if (failed(g_api->SessionGetInputCount(s, &n)) || n != 1) return 0;
    char *name = NULL;
    if (failed(g_api->SessionGetInputName(s, 0, alloc, &name))) return 0;
    int ok = strcmp(name, input_name) == 0;
    (void)failed(g_api->AllocatorFree(alloc, name));
    if (!ok) return 0;
    if (failed(g_api->SessionGetOutputCount(s, &n)) || n != (size_t)count) return 0;
    for (int32_t i = 0; i < count; i++) {
        name = NULL;
        if (failed(g_api->SessionGetOutputName(s, (size_t)i, alloc, &name))) return 0;
        ok = strcmp(name, names[i]) == 0;
        (void)failed(g_api->AllocatorFree(alloc, name));
        if (!ok) return 0;
    }
    return 1;
}

static char *copy_name(const char *s) {
    if (s == NULL) return NULL;
    size_t n = strnlen(s, FB_MAX_NAME + 1);
    if (n == 0 || n > FB_MAX_NAME) return NULL;
    char *c = malloc(n + 1);
    if (c != NULL) memcpy(c, s, n + 1);
    return c;
}

void fb_ort_close(fb_ort_session *h) {
    if (h == NULL) return;
    if (g_api != NULL) {
        if (h->session != NULL) g_api->ReleaseSession(h->session);
        if (h->memory != NULL) g_api->ReleaseMemoryInfo(h->memory);
    }
    free(h->input_name);
    for (int32_t i = 0; i < FB_MAX_OUTPUTS; i++) free(h->output_names[i]);
    free(h);
}

int32_t fb_ort_open(const void *model, int64_t model_byte_count, int32_t threads, const char *input_name,
                    const int64_t *input_shape, int32_t input_rank, const char *const *output_names,
                    int32_t output_count, int32_t active_cores, fb_ort_session **out, int32_t *xnnpack) {
    if (out == NULL || xnnpack == NULL) return FB_ORT_INVALID_ARGUMENTS;
    *out = NULL;
    *xnnpack = 0;
    if (model == NULL || model_byte_count <= 0 || input_name == NULL || input_shape == NULL || input_rank != 4 ||
        output_names == NULL || output_count <= 0 || output_count > FB_MAX_OUTPUTS || threads < 0) {
        return FB_ORT_INVALID_ARGUMENTS;
    }
    int64_t elements = 1;
    for (int i = 0; i < 4; i++) {
        int64_t d = input_shape[i];
        if (d <= 0 || elements > INT64_MAX / 4 / d) return FB_ORT_INVALID_ARGUMENTS;
        elements *= d;
    }
    int32_t init_status = ready();
    if (init_status != FB_ORT_OK) return init_status; // FB_ORT_OPTION_FAILED if telemetry could not be disabled
    fb_ort_session *h = calloc(1, sizeof *h);
    if (h == NULL) return FB_ORT_NOT_CREATED;
    h->input_bytes = elements * 4;
    memcpy(h->shape, input_shape, sizeof h->shape);
    h->input_name = copy_name(input_name);
    h->output_count = output_count;
    int names_ok = h->input_name != NULL;
    for (int32_t i = 0; i < output_count && names_ok; i++) {
        h->output_names[i] = copy_name(output_names[i]);
        names_ok = h->output_names[i] != NULL;
    }
    if (!names_ok) {
        fb_ort_close(h);
        return FB_ORT_INVALID_ARGUMENTS;
    }
    if (failed(g_api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &h->memory))) {
        fb_ort_close(h);
        return FB_ORT_NOT_CREATED;
    }
    int32_t auto_threads = active_cores < 1 ? 1 : (active_cores > 4 ? 4 : active_cores);
    OrtSessionOptions *options = NULL;
    int32_t st = make_options(1, threads > 0 ? threads : auto_threads, &options);
    if (st == FB_ORT_OPTION_FAILED) {
        fb_ort_close(h);
        return FB_ORT_OPTION_FAILED;
    }
    if (st == FB_ORT_OK) {
        h->session = create(model, (size_t)model_byte_count, options);
        g_api->ReleaseSessionOptions(options);
        if (h->session != NULL) *xnnpack = 1;
    }
    if (h->session == NULL) {
        st = make_options(0, threads, &options);
        if (st != FB_ORT_OK) {
            fb_ort_close(h);
            return FB_ORT_OPTION_FAILED;
        }
        h->session = create(model, (size_t)model_byte_count, options);
        g_api->ReleaseSessionOptions(options);
    }
    if (h->session == NULL) {
        fb_ort_close(h);
        return FB_ORT_NOT_CREATED;
    }
    if (!names_match(h->session, h->input_name, (const char *const *)h->output_names, output_count)) {
        fb_ort_close(h);
        *xnnpack = 0;
        return FB_ORT_NAMES_DIFFER;
    }
    *out = h;
    return FB_ORT_OK;
}

/// Writes type, rank and up to four dims of `v` into `row`; copies the data if it is float32, rank <= 4 and fits.
static int32_t copy_out(OrtValue *v, int64_t *row) {
    OrtTensorTypeAndShapeInfo *info = NULL;
    if (failed(g_api->GetTensorTypeAndShape(v, &info))) return FB_ORT_OUTPUT_INVALID;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    size_t rank = 0;
    int64_t dims[FB_MAX_DIMS] = {0};
    int ok = !failed(g_api->GetTensorElementType(info, &type)) && !failed(g_api->GetDimensionsCount(info, &rank)) &&
             rank <= FB_MAX_DIMS && !failed(g_api->GetDimensions(info, dims, rank));
    g_api->ReleaseTensorTypeAndShapeInfo(info);
    if (!ok) return FB_ORT_OUTPUT_INVALID;
    row[3] = (int64_t)type;
    row[4] = (int64_t)rank;
    for (size_t k = 0; k < 4; k++) row[5 + k] = k < rank ? dims[k] : 0;
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || rank > 4) return FB_ORT_OUTPUT_INVALID;
    int64_t bytes = 4;
    for (size_t k = 0; k < rank; k++) {
        if (dims[k] < 0 || (dims[k] != 0 && bytes > INT64_MAX / dims[k])) return FB_ORT_OUTPUT_INVALID;
        bytes *= dims[k];
    }
    void *dst = (void *)(intptr_t)row[0];
    if (bytes > row[1] || (bytes > 0 && dst == NULL)) return FB_ORT_OUTPUT_INVALID;
    void *src = NULL;
    if (bytes > 0) {
        if (failed(g_api->GetTensorMutableData(v, &src)) || src == NULL) return FB_ORT_OUTPUT_INVALID;
        memcpy(dst, src, (size_t)bytes);
    }
    row[2] = bytes;
    return FB_ORT_OK;
}

int32_t fb_ort_run(fb_ort_session *h, void *input, int64_t input_byte_count, int64_t *table) {
    if (h == NULL || h->session == NULL || g_api == NULL) return FB_ORT_NOT_OPEN;
    if (input == NULL || table == NULL || input_byte_count != h->input_bytes) return FB_ORT_INVALID_ARGUMENTS;
    for (int32_t i = 0; i < h->output_count; i++) {
        const int64_t *row = table + (size_t)i * FB_ORT_ROW_LONGS;
        if (row[0] == 0 || row[1] < 0) return FB_ORT_INVALID_ARGUMENTS;
    }
    OrtValue *in = NULL;
    if (failed(g_api->CreateTensorWithDataAsOrtValue(h->memory, input, (size_t)input_byte_count, h->shape, 4,
                                                     ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &in))) {
        return FB_ORT_RUN_FAILED;
    }
    memset(h->outputs, 0, sizeof h->outputs);
    const char *in_names[] = {h->input_name};
    const OrtValue *ins[] = {in};
    int run_failed = failed(g_api->Run(h->session, NULL, in_names, ins, 1, (const char *const *)h->output_names,
                                       (size_t)h->output_count, h->outputs));
    g_api->ReleaseValue(in);
    int32_t status = run_failed ? FB_ORT_RUN_FAILED : FB_ORT_OK;
    for (int32_t i = 0; i < h->output_count; i++) {
        if (h->outputs[i] == NULL) {
            if (status == FB_ORT_OK) status = FB_ORT_OUTPUT_INVALID;
            continue;
        }
        if (status != FB_ORT_RUN_FAILED && copy_out(h->outputs[i], table + (size_t)i * FB_ORT_ROW_LONGS) != FB_ORT_OK) {
            status = FB_ORT_OUTPUT_INVALID;
        }
        g_api->ReleaseValue(h->outputs[i]);
        h->outputs[i] = NULL;
    }
    return status;
}
