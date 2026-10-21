/*
 * miniaudio translation unit for the Fideflow native host (docs/design/native-build.md).
 *
 * miniaudio is compiled into the Rust host library rather than shipped as a
 * separate dynamic library, and is configured for exactly one job: low-level
 * Core Audio device output. FFmpeg stays the only decoder and the only
 * application-level resampler, so every unused facility is compiled out.
 *
 * The small neutral API at the bottom keeps miniaudio's structs inside C: Rust
 * only exchanges scalars and byte buffers, which is the same ownership rule the
 * media_core C ABI follows.
 *
 * Launch with:
 *   clang -c c/ff_miniaudio.c -I<miniaudio dir> ...
 */

#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_COREAUDIO
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#include "miniaudio.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Mirrored in src/lib.rs as MiniaudioConfigFlag. */
#define FF_MINIADIO_FLAG_SINGLE_BACKEND (1u << 0)
#define FF_MINIADIO_FLAG_COREAUDIO (1u << 1)
#define FF_MINIADIO_FLAG_NO_DECODING (1u << 2)
#define FF_MINIADIO_FLAG_NO_ENCODING (1u << 3)
#define FF_MINIADIO_FLAG_NO_GENERATION (1u << 4)
#define FF_MINIADIO_FLAG_NO_RESOURCE_MANAGER (1u << 5)
#define FF_MINIADIO_FLAG_NO_NODE_GRAPH (1u << 6)
#define FF_MINIADIO_FLAG_NO_ENGINE (1u << 7)

const char *ff_miniaudio_version(void)
{
    return MA_VERSION_STRING;
}

/* Reports the compile-time configuration that actually took effect. */
unsigned int ff_miniaudio_config_flags(void)
{
    unsigned int flags = 0;

#ifdef MA_ENABLE_ONLY_SPECIFIC_BACKENDS
    flags |= FF_MINIADIO_FLAG_SINGLE_BACKEND;
#endif
#ifdef MA_ENABLE_COREAUDIO
    flags |= FF_MINIADIO_FLAG_COREAUDIO;
#endif
#ifdef MA_NO_DECODING
    flags |= FF_MINIADIO_FLAG_NO_DECODING;
#endif
#ifdef MA_NO_ENCODING
    flags |= FF_MINIADIO_FLAG_NO_ENCODING;
#endif
#ifdef MA_NO_GENERATION
    flags |= FF_MINIADIO_FLAG_NO_GENERATION;
#endif
#ifdef MA_NO_RESOURCE_MANAGER
    flags |= FF_MINIADIO_FLAG_NO_RESOURCE_MANAGER;
#endif
#ifdef MA_NO_NODE_GRAPH
    flags |= FF_MINIADIO_FLAG_NO_NODE_GRAPH;
#endif
#ifdef MA_NO_ENGINE
    flags |= FF_MINIADIO_FLAG_NO_ENGINE;
#endif
    return flags;
}

/*
 * Device output.
 *
 * Rust owns the policy (how many frames to hand the device, what to fill in when
 * the ring runs dry); this shim only moves floats and keeps miniaudio's structs
 * inside C. The render callback is called from the audio thread, so the whole
 * path here does no allocation, no locking and no I/O.
 */

#define FF_OUTPUT_NAME_BYTES 256

/* Render `frames` interleaved frames into `out`; must fill every frame. */
typedef void (*ff_render_callback)(float *out, unsigned int frames, void *user);

typedef struct ff_output_info {
    char device_name[FF_OUTPUT_NAME_BYTES];
    int sample_rate;
    int channels;
    int internal_format;       /* ma_format value the backend actually opened */
    unsigned int period_frames; /* frames per device period */
    unsigned int periods;       /* periods the backend allocated */
    /* Buffer depth of one period, which is what miniaudio 0.11.25 can report;
     * it is not the full round-trip latency (docs/design/playback.md accepts the uncorrected
     * frame-clock anchor and records this limitation). */
    double period_seconds;
} ff_output_info;

typedef struct ff_output {
    ma_device device;
    ff_render_callback callback;
    void *user;
} ff_output;

static void ff_output_set_error(char *buffer, size_t size, const char *message, ma_result result)
{
    if (buffer == NULL || size == 0) {
        return;
    }
    snprintf(buffer, size, "%s: %s", message, ma_result_description(result));
}

static void ff_output_data_callback(ma_device *device, void *output, const void *input,
                                    ma_uint32 frame_count)
{
    ff_output *context = (ff_output *)device->pUserData;
    size_t samples = (size_t)frame_count * (size_t)device->playback.channels;

    (void)input;
    if (context == NULL || context->callback == NULL || output == NULL) {
        if (output != NULL) {
            memset(output, 0, samples * sizeof(float));
        }
        return;
    }
    context->callback((float *)output, (unsigned int)frame_count, context->user);
}

/*
 * Opens and starts a playback device. Returns 0 on success and fills `*out`,
 * or a negative value with `error_text` describing the miniaudio result.
 */
int ff_output_start(int sample_rate, int channels, unsigned int period_frames,
                    ff_render_callback callback, void *user, ff_output **out, char *error_text,
                    size_t error_text_size)
{
    ma_device_config config;
    ff_output *context;
    ma_result result;

    if (out == NULL) {
        return -1;
    }
    *out = NULL;
    if (callback == NULL || sample_rate <= 0 || channels <= 0) {
        if (error_text != NULL && error_text_size > 0) {
            snprintf(error_text, error_text_size, "invalid output configuration");
        }
        return -1;
    }
    context = calloc(1, sizeof(*context));
    if (context == NULL) {
        if (error_text != NULL && error_text_size > 0) {
            snprintf(error_text, error_text_size, "out of memory");
        }
        return -1;
    }
    context->callback = callback;
    context->user = user;

    config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = (ma_uint32)channels;
    config.sampleRate = (ma_uint32)sample_rate;
    config.periodSizeInFrames = period_frames;
    config.dataCallback = ff_output_data_callback;
    config.pUserData = context;
    /* Keep decoded floats intact: the pipeline owns gain, and clamping here would
     * hide the overshoot the diagnostics need to report (docs/design/playback.md). */
    config.noClip = MA_TRUE;

    result = ma_device_init(NULL, &config, &context->device);
    if (result != MA_SUCCESS) {
        ff_output_set_error(error_text, error_text_size, "could not open the output device", result);
        free(context);
        return -1;
    }
    result = ma_device_start(&context->device);
    if (result != MA_SUCCESS) {
        ff_output_set_error(error_text, error_text_size, "could not start the output device", result);
        ma_device_uninit(&context->device);
        free(context);
        return -1;
    }
    *out = context;
    return 0;
}

/* Stops the audio thread. No callback runs once this returns. */
void ff_output_pause(ff_output *output)
{
    if (output != NULL) {
        ma_device_stop(&output->device);
    }
}

/* Restarts a paused device; the configuration and the callback are unchanged. */
int ff_output_resume(ff_output *output)
{
    if (output == NULL) {
        return -1;
    }
    return ma_device_start(&output->device) == MA_SUCCESS ? 0 : -1;
}

int ff_output_is_running(const ff_output *output)
{
    if (output == NULL) {
        return 0;
    }
    return ma_device_is_started(&output->device) == MA_TRUE ? 1 : 0;
}

/* Releases the device and the context. The caller must not use either again. */
void ff_output_release(ff_output *output)
{
    if (output != NULL) {
        ma_device_uninit(&output->device);
        free(output);
    }
}

/* Reports the format the backend opened, for diagnostics and docs/design/playback.md evidence. */
int ff_output_get_info(const ff_output *output, ff_output_info *info)
{
    const char *name;
    size_t length = 0;

    if (output == NULL || info == NULL) {
        return -1;
    }
    memset(info, 0, sizeof(*info));
    info->sample_rate = (int)output->device.playback.internalSampleRate;
    info->channels = (int)output->device.playback.internalChannels;
    info->internal_format = (int)output->device.playback.internalFormat;
    info->period_frames = output->device.playback.internalPeriodSizeInFrames;
    info->periods = output->device.playback.internalPeriods;
    if (info->sample_rate > 0) {
        info->period_seconds = (double)info->period_frames / (double)info->sample_rate;
    }
    name = output->device.playback.name;
    while (length + 1 < FF_OUTPUT_NAME_BYTES && name[length] != '\0') {
        length += 1;
    }
    memcpy(info->device_name, name, length);
    info->device_name[length] = '\0';
    return 0;
}

/*
 * Copies playback device names into `buffer` as newline-separated UTF-8 and
 * returns how many names fit, or a negative value on error. The temporary
 * miniaudio context never escapes this function: device info pointers are only
 * valid while the context lives.
 */
int ff_miniaudio_playback_device_names(char *buffer, size_t buffer_size)
{
    ma_context context;
    ma_device_info *playback = NULL;
    ma_device_info *capture = NULL;
    ma_uint32 playback_count = 0;
    ma_uint32 capture_count = 0;
    size_t used = 0;
    ma_uint32 index;
    int written = 0;

    if (buffer == NULL || buffer_size == 0) {
        return -1;
    }
    buffer[0] = '\0';
    if (ma_context_init(NULL, 0, NULL, &context) != MA_SUCCESS) {
        return -1;
    }
    if (ma_context_get_devices(&context, &playback, &playback_count, &capture, &capture_count) !=
        MA_SUCCESS) {
        ma_context_uninit(&context);
        return -1;
    }
    for (index = 0; index < playback_count; index++) {
        size_t length = 0;
        size_t needed;

        while (length <= MA_MAX_DEVICE_NAME_LENGTH && playback[index].name[length] != '\0') {
            length += 1;
        }
        needed = length + 2;

        if (used + needed > buffer_size) {
            break;
        }
        memcpy(buffer + used, playback[index].name, length);
        used += length;
        buffer[used] = (index + 1 == playback_count) ? '\0' : '\n';
        if (index + 1 < playback_count) {
            used += 1;
            buffer[used] = '\0';
        }
        written += 1;
    }
    ma_context_uninit(&context);
    return written;
}
