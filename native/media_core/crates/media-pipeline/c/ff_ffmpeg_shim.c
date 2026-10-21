/*
 * FFmpeg demux/decode/resample shim for the Fideflow playback pipeline.
 *
 * FFmpeg's structs stay inside this translation unit, the same rule
 * c/ff_portaudio.c applies to PortAudio: Rust only exchanges scalars, byte
 * buffers and one opaque pointer. That keeps the Rust side free of transcribed
 * FFmpeg layouts while libavformat still owns demuxing, libavcodec decoding and
 * libswresample the sample-rate, channel-layout and sample-format conversion.
 *
 * docs/design/playback.md fixes the negotiated output format: interleaved 48 kHz stereo float32,
 * resampled by libswresample with the SoX Resampler engine (`resampler=soxr`).
 * The engine actually selected is reported back so the capability probe and the
 * runtime diagnostics can prove libsoxr is in the path instead of assuming it.
 *
 * Threading: one decoder belongs to one worker thread. `ff_decoder_set_cancel`
 * points the decoder at a flag owned by the caller; the flag is read from the
 * worker and from libavformat's interrupt callback, which may run on a different
 * thread, so it must be an atomic or volatile int.
 */

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _MSC_VER
#include <intrin.h>
#define __ATOMIC_RELAXED 0
#define __atomic_load_n(ptr, order) _InterlockedCompareExchange((volatile long *)(ptr), 0, 0)
#define __atomic_store_n(ptr, value, order) _InterlockedExchange((volatile long *)(ptr), (value))
#endif

#define FF_PCM_RATE 48000
#define FF_PCM_CHANNELS 2

enum ff_decode_code {
    FF_DECODE_OK = 0,
    FF_DECODE_OPEN_FAILED = 1,
    FF_DECODE_NO_AUDIO_STREAM = 2,
    FF_DECODE_UNSUPPORTED_FORMAT = 3,
    FF_DECODE_DECODE_FAILED = 4,
    FF_DECODE_SEEK_FAILED = 5,
    FF_DECODE_END_OF_STREAM = 6,
    FF_DECODE_CANCELLED = 7
};

typedef struct ff_audio_info {
    int sample_rate;
    int channels;
    long long duration_ms; /* -1 when the container does not report one */
    char codec[64];
    char container[64];
    int output_rate;
    int output_channels;
    char resampler[64]; /* engine libswresample actually selected */
} ff_audio_info;

typedef struct ff_decoder {
    AVFormatContext *format;
    AVIOContext *input_io;
    void *input_opaque;
    int (*input_read)(void *, uint8_t *, int, volatile int *);
    int64_t (*input_seek)(void *, int64_t, int, volatile int *);
    AVCodecContext *codec;
    SwrContext *swr;
    AVPacket *packet;
    AVFrame *frame;
    int stream_index;
    int frame_ready;     /* `frame` holds decoded samples not yet converted */
    int input_drained;   /* avcodec_send_packet(NULL) has been sent */
    int output_drained;  /* libswresample has no buffered samples left */
    int eof_seen;        /* av_read_frame reported the end of the input */
    long long discard_until_us; /* drop output before this media time (after seek) */
    long long frame_media_us;   /* media time of the first sample of `frame` */
    long long emitted_from_frame;
    long long next_output_us;   /* media time after the last sample handed out */
    int output_rate;
    int output_channels;
    int source_rate;            /* native sample rate used to time frame offsets */
    /* Staging buffer for one conversion.
     *
     * libswresample must be able to produce everything it wants for the input it
     * is given; handing it a buffer sized by the *caller* breaks that contract.
     * With the SoXR engine a short frame plus a small caller buffer made soxr
     * hand out a null internal input pointer and crash inside its own memcpy, so
     * output is staged here at the size `swr_get_out_samples` asks for and then
     * served in pieces. It also makes the pipeline independent of the block size
     * a caller happens to use. */
    float *stage;
    int stage_capacity; /* frames the staging buffer can hold */
    int stage_offset;   /* next staged frame to serve */
    int stage_count;    /* staged frames available */
    long long stage_media_us; /* media time of staged frame 0 */
    volatile int *cancel_flag;
    int interrupted;
    char resampler[64];
} ff_decoder;

/* Names for the `resampler` option's values (`enum SwrEngine`). */
static const char *ff_resampler_name(int64_t engine)
{
    switch (engine) {
    case SWR_ENGINE_SWR:
        return "swr";
    case SWR_ENGINE_SOXR:
        return "soxr";
    default:
        return NULL;
    }
}

/* Defined at the end of this file and used by the open error paths. */
void ff_decoder_close(ff_decoder *decoder);

/*
 * Narrow debug trace for the convert path. Off unless FF_FFMPEG_TRACE is set in
 * the environment; it exists because a bad pointer handed to libswresample shows
 * up as a crash inside the resampler with no useful stack of our own. It prints
 * formats and frame counts only, never a path, title or sample payload (docs/design/diagnostics.md).
 */
static int ff_trace_enabled(void)
{
    static int cached = -1;
    if (cached < 0) {
        cached = getenv("FF_FFMPEG_TRACE") != NULL ? 1 : 0;
    }
    return cached;
}

static int ff_is_cancelled(const ff_decoder *decoder)
{
    return decoder->cancel_flag != NULL &&
           __atomic_load_n(decoder->cancel_flag, __ATOMIC_RELAXED) != 0;
}

/* libavformat polls this from its own threads while a read is blocked. */
static int ff_interrupt_callback(void *opaque)
{
    ff_decoder *decoder = opaque;

    int cancelled = decoder == NULL ? 0 : ff_is_cancelled(decoder);
    if (cancelled) {
        __atomic_store_n(&decoder->interrupted, 1, __ATOMIC_RELAXED);
    }
    return cancelled;
}

static void ff_set_error(char *buffer, size_t size, const char *message, int code)
{
    if (buffer == NULL || size == 0) {
        return;
    }
    if (code == 0) {
        snprintf(buffer, size, "%s", message);
        return;
    }
    snprintf(buffer, size, "%s (error %d)", message, code);
}

static void ff_decoder_reset_output(ff_decoder *decoder)
{
    decoder->frame_ready = 0;
    decoder->emitted_from_frame = 0;
    decoder->frame_media_us = 0;
    decoder->stage_offset = 0;
    decoder->stage_count = 0;
    decoder->stage_media_us = 0;
}

int ff_decoder_is_available(void)
{
    return 1;
}

const char *ff_ffmpeg_version(void)
{
    return av_version_info();
}

/*
 * Builds (or rebuilds) the resampler.
 *
 * The context is recreated rather than re-initialised because the SoXR engine
 * keeps its own state inside the context: calling `swr_init` on a context that
 * has already run leaves that state pointing at buffers the new configuration no
 * longer owns, which shows up as a crash inside `soxr_process` on the first block
 * after a seek.
 */
static int ff_open_resampler(ff_decoder *decoder, char *error_text, size_t error_text_size)
{
    AVChannelLayout layout = { 0 };
    AVChannelLayout in_layout = { 0 };
    int result;

    if (decoder->codec->ch_layout.nb_channels > 0) {
        result = av_channel_layout_copy(&in_layout, &decoder->codec->ch_layout);
    } else {
        av_channel_layout_default(&in_layout, decoder->output_channels);
        result = 0;
    }
    if (result < 0) {
        ff_set_error(error_text, error_text_size, "could not copy the channel layout", result);
        return FF_DECODE_UNSUPPORTED_FORMAT;
    }
    if (in_layout.nb_channels == decoder->output_channels) av_channel_layout_copy(&layout, &in_layout);
    else av_channel_layout_default(&layout, decoder->output_channels);
    swr_free(&decoder->swr);
    result = swr_alloc_set_opts2(&decoder->swr, &layout, AV_SAMPLE_FMT_FLT, decoder->output_rate, &in_layout,
                                 decoder->codec->sample_fmt, decoder->codec->sample_rate, 0, NULL);
    av_channel_layout_uninit(&in_layout);
    av_channel_layout_uninit(&layout);
    if (result < 0 || decoder->swr == NULL) {
        ff_set_error(error_text, error_text_size, "could not create the resampler", result);
        return FF_DECODE_OPEN_FAILED;
    }

    /* docs/design/playback.md: the SoX Resampler engine, reached through libswresample.
     * FF_RESAMPLER overrides the engine for diagnostics; the default never moves. */
    {
        const char *requested = getenv("FF_RESAMPLER");
        result = av_opt_set(decoder->swr, "resampler",
                            requested != NULL && requested[0] != '\0' ? requested : "soxr", 0);
    }
    if (result < 0) {
        /* Not fatal: the engine that was actually selected is reported below. */
        decoder->resampler[0] = '\0';
    }
    av_opt_set_int(decoder->swr, "dither_method", SWR_DITHER_NONE, 0);
    result = swr_init(decoder->swr);
    if (result < 0) {
        ff_set_error(error_text, error_text_size, "could not initialise the resampler", result);
        return FF_DECODE_OPEN_FAILED;
    }
    /* Report the engine that was really selected: `av_opt_get_int` returns the
     * enum value, which has to be mapped back to the name the playback design uses. */
    {
        int64_t engine = -1;
        const char *name = NULL;
        if (av_opt_get_int(decoder->swr, "resampler", 0, &engine) >= 0) {
            name = ff_resampler_name(engine);
        }
        if (name != NULL) {
            snprintf(decoder->resampler, sizeof(decoder->resampler), "%s", name);
        } else {
            snprintf(decoder->resampler, sizeof(decoder->resampler), "engine(%lld)",
                     (long long)engine);
        }
    }
    decoder->source_rate = decoder->codec->sample_rate;
    if (ff_trace_enabled()) {
        fprintf(stderr,
                "ff_trace resampler decoder=%p in_rate=%d in_fmt=%d in_ch=%d resampler=%s\n",
                (void *)decoder, decoder->codec->sample_rate,
                (int)decoder->codec->sample_fmt, decoder->codec->ch_layout.nb_channels,
                decoder->resampler);
    }
    return FF_DECODE_OK;
}

static int ff_open_codec(ff_decoder *decoder, char *error_text, size_t error_text_size)
{
    const AVCodec *codec = NULL;
    AVCodecParameters *parameters = NULL;
    int result;

    decoder->stream_index = av_find_best_stream(decoder->format, AVMEDIA_TYPE_AUDIO, -1, -1,
                                                &codec, 0);
    if (decoder->stream_index < 0 || codec == NULL) {
        ff_set_error(error_text, error_text_size, "no decodable audio stream", decoder->stream_index);
        return FF_DECODE_NO_AUDIO_STREAM;
    }
    parameters = decoder->format->streams[decoder->stream_index]->codecpar;
    decoder->codec = avcodec_alloc_context3(codec);
    if (decoder->codec == NULL) {
        ff_set_error(error_text, error_text_size, "could not allocate the decoder context", 0);
        return FF_DECODE_OPEN_FAILED;
    }
    result = avcodec_parameters_to_context(decoder->codec, parameters);
    if (result < 0) {
        ff_set_error(error_text, error_text_size, "could not apply stream parameters", result);
        return FF_DECODE_OPEN_FAILED;
    }
    result = avcodec_open2(decoder->codec, codec, NULL);
    if (result < 0) {
        ff_set_error(error_text, error_text_size, "could not open the decoder", result);
        return FF_DECODE_OPEN_FAILED;
    }
    if (decoder->codec->sample_fmt == AV_SAMPLE_FMT_NONE || decoder->codec->sample_rate <= 0) {
        ff_set_error(error_text, error_text_size, "the stream has no usable audio format", 0);
        return FF_DECODE_UNSUPPORTED_FORMAT;
    }
    return ff_open_resampler(decoder, error_text, error_text_size);
}

static int ff_input_read(void *opaque, uint8_t *buffer, int length) {
    ff_decoder *decoder = opaque;
    int result = decoder->input_read(decoder->input_opaque, buffer, length, decoder->cancel_flag);
    if (result > 0) return result;
    if (result == 0) return AVERROR_EOF;
    if (result == -2) { decoder->interrupted = 1; return AVERROR_EXIT; }
    if (result == -4) return AVERROR(ETIMEDOUT);
    return AVERROR(EIO);
}
static int64_t ff_input_seek(void *opaque, int64_t offset, int whence) {
    ff_decoder *decoder = opaque;
    int64_t result = decoder->input_seek(decoder->input_opaque, offset, whence, decoder->cancel_flag);
    return result < 0 ? AVERROR(EIO) : result;
}
ff_decoder *ff_decoder_open_input(const char *path, volatile int *cancel_flag, int *error_code, char *error_text,
                            size_t error_text_size, void *opaque,
                            int (*read_input)(void *, uint8_t *, int, volatile int *),
                            int64_t (*seek_input)(void *, int64_t, int, volatile int *))
{
    ff_decoder *decoder;
    const AVInputFormat *input_format = NULL;
    int result;

    if (error_code != NULL) {
        *error_code = FF_DECODE_OK;
    }
    if (path == NULL) {
        if (error_code != NULL) {
            *error_code = FF_DECODE_OPEN_FAILED;
        }
        ff_set_error(error_text, error_text_size, "no source path given", 0);
        return NULL;
    }
    decoder = calloc(1, sizeof(*decoder));
    if (decoder == NULL) {
        if (error_code != NULL) {
            *error_code = FF_DECODE_OPEN_FAILED;
        }
        ff_set_error(error_text, error_text_size, "out of memory", 0);
        return NULL;
    }
    decoder->output_rate = FF_PCM_RATE;
    decoder->output_channels = FF_PCM_CHANNELS;
    decoder->cancel_flag = cancel_flag;
    decoder->discard_until_us = -1;
    decoder->format = avformat_alloc_context();
    if (decoder->format == NULL) {
        ff_decoder_close(decoder);
        if (error_code != NULL) {
            *error_code = FF_DECODE_OPEN_FAILED;
        }
        ff_set_error(error_text, error_text_size, "could not allocate the format context", 0);
        return NULL;
    }
    decoder->format->interrupt_callback.callback = ff_interrupt_callback;
    decoder->format->interrupt_callback.opaque = decoder;
    /* Remote inputs use host-owned AVIO; FFmpeg is built without networking. */
    AVDictionary *options = NULL;
    if (read_input != NULL) {
        decoder->input_opaque = opaque; decoder->input_read = read_input; decoder->input_seek = seek_input;
        uint8_t *buffer = av_malloc(65536);
        decoder->input_io = buffer == NULL ? NULL : avio_alloc_context(buffer, 65536, 0, decoder, ff_input_read, NULL, ff_input_seek);
        if (decoder->input_io == NULL) {
            av_free(buffer); av_dict_free(&options); ff_decoder_close(decoder);
            if (error_code) *error_code = FF_DECODE_OPEN_FAILED;
            return NULL;
        }
        decoder->input_io->seekable = AVIO_SEEKABLE_NORMAL;
        decoder->format->pb = decoder->input_io;
        decoder->format->flags |= AVFMT_FLAG_CUSTOM_IO;
        av_dict_set(&options, "probesize", "131072", 0);
        av_dict_set(&options, "analyzeduration", "500000", 0);
        /* FLAC's seek table is only imported with FAST_SEEK set while reading
         * its header. Probe through buffered custom AVIO, then opt in only for
         * FLAC. The PCM discard stage still trims to the exact target sample. */
        if (av_probe_input_buffer2(decoder->input_io, &input_format, path, NULL,
                                   0, 131072) >= 0 && input_format != NULL &&
            strcmp(input_format->name, "flac") == 0) {
            decoder->format->flags |= AVFMT_FLAG_FAST_SEEK;
        }
    }
    result = avformat_open_input(&decoder->format, read_input != NULL ? NULL : path, input_format, &options);
    av_dict_free(&options);
    if (result < 0) {
        /* Read the cancel flag before the decoder is released. */
        int cancelled = ff_is_cancelled(decoder);
        ff_decoder_close(decoder);
        if (error_code != NULL) {
            *error_code = cancelled ? FF_DECODE_CANCELLED : FF_DECODE_OPEN_FAILED;
        }
        ff_set_error(error_text, error_text_size, "could not open the source", result);
        return NULL;
    }
    result = avformat_find_stream_info(decoder->format, NULL);
    if (result < 0) {
        ff_decoder_close(decoder);
        if (error_code != NULL) {
            *error_code = FF_DECODE_OPEN_FAILED;
        }
        ff_set_error(error_text, error_text_size, "could not read stream information", result);
        return NULL;
    }
    result = ff_open_codec(decoder, error_text, error_text_size);
    if (result != FF_DECODE_OK) {
        ff_decoder_close(decoder);
        if (error_code != NULL) {
            *error_code = result;
        }
        return NULL;
    }
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    if (decoder->packet == NULL || decoder->frame == NULL) {
        ff_decoder_close(decoder);
        if (error_code != NULL) {
            *error_code = FF_DECODE_OPEN_FAILED;
        }
        ff_set_error(error_text, error_text_size, "could not allocate the packet buffers", 0);
        return NULL;
    }
    return decoder;
}

ff_decoder *ff_decoder_open(const char *path, volatile int *cancel_flag, int *error_code, char *error_text, size_t error_text_size) {
    return ff_decoder_open_input(path, cancel_flag, error_code, error_text, error_text_size, NULL, NULL, NULL);
}

void ff_decoder_set_cancel(ff_decoder *decoder, volatile int *flag)
{
    if (decoder != NULL) {
        decoder->cancel_flag = flag;
        if (decoder->input_io != NULL) {
            /* Custom AVIO owns no protocol connection poisoned by interrupt.
             * Seek on the new worker repositions it before any PCM is reused. */
            decoder->input_io->error = 0;
            decoder->input_io->eof_reached = 0;
            __atomic_store_n(&decoder->interrupted, 0, __ATOMIC_RELAXED);
        }
    }
}

int ff_decoder_can_reuse_for_seek(const ff_decoder *decoder)
{
    const AVIOContext *io = decoder->format->pb;
    return io != NULL && (io->seekable & AVIO_SEEKABLE_NORMAL) != 0 &&
        (io->error >= 0 || io->error == AVERROR_EOF);
}

int ff_decoder_was_interrupted(const ff_decoder *decoder)
{
    return __atomic_load_n(&decoder->interrupted, __ATOMIC_RELAXED);
}

int ff_decoder_get_info(const ff_decoder *decoder, ff_audio_info *out)
{
    const AVCodecParameters *parameters;
    const AVCodecDescriptor *descriptor;
    const AVInputFormat *input;

    if (decoder == NULL || out == NULL || decoder->codec == NULL) {
        return FF_DECODE_UNSUPPORTED_FORMAT;
    }
    memset(out, 0, sizeof(*out));
    parameters = decoder->format->streams[decoder->stream_index]->codecpar;
    out->sample_rate = decoder->codec->sample_rate;
    out->channels = decoder->codec->ch_layout.nb_channels;
    out->output_rate = decoder->output_rate;
    out->output_channels = decoder->output_channels;
    out->duration_ms = -1;
    if (decoder->format->duration != AV_NOPTS_VALUE && decoder->format->duration > 0) {
        out->duration_ms = decoder->format->duration / (AV_TIME_BASE / 1000);
    }
    descriptor = avcodec_descriptor_get(parameters->codec_id);
    snprintf(out->codec, sizeof(out->codec), "%s",
             descriptor != NULL ? descriptor->name : "unknown");
    input = decoder->format->iformat;
    snprintf(out->container, sizeof(out->container), "%s", input != NULL ? input->name : "unknown");
    snprintf(out->resampler, sizeof(out->resampler), "%s",
             decoder->resampler[0] != '\0' ? decoder->resampler : "unknown");
    return FF_DECODE_OK;
}

static int ff_next_frame(ff_decoder *decoder);

/* Grows the staging buffer so it can hold `frames` output frames. */
static int ff_stage_reserve(ff_decoder *decoder, int frames)
{
    float *resized;

    /* Ring + decode block + staging stay below the session PCM ceiling. */
    if (frames < 0 || (size_t)frames > (768u * 1024u) / (sizeof(float) * decoder->output_channels)) return -1;
    if (frames <= decoder->stage_capacity) {
        return 0;
    }
    resized = realloc(decoder->stage, (size_t)frames * decoder->output_channels * sizeof(float));
    if (resized == NULL) {
        return -1;
    }
    decoder->stage = resized;
    decoder->stage_capacity = frames;
    return 0;
}

/*
 * Fills the staging buffer with the next converted block.
 *
 * Returns 1 when the stage holds frames, 0 when the resampler is drained, and -1
 * with `*failure` set to an `ff_decode_code` otherwise.
 */
static int ff_fill_stage(ff_decoder *decoder, int *failure)
{
    long long block_time;
    int status;
    int produced;
    int needed;

    if (decoder->output_drained) {
        return 0;
    }
    status = decoder->frame_ready ? 1 : ff_next_frame(decoder);
    if (status < 0) {
        *failure = -status;
        return -1;
    }
    if (status == 0) {
        /* No input left: flush the resampler's internal backlog. */
        needed = swr_get_out_samples(decoder->swr, 0) + 4096;
        if (needed < 4096) {
            needed = 4096;
        }
        if (ff_stage_reserve(decoder, needed) < 0) {
            *failure = FF_DECODE_DECODE_FAILED;
            return -1;
        }
        produced = swr_convert(decoder->swr, (uint8_t **)&decoder->stage, needed, NULL, 0);
        if (ff_trace_enabled()) {
            fprintf(stderr, "ff_trace flush produced=%d\n", produced);
        }
        if (produced < 0) {
            *failure = FF_DECODE_DECODE_FAILED;
            return -1;
        }
        if (produced == 0) {
            decoder->output_drained = 1;
            return 0;
        }
        block_time = decoder->next_output_us;
    } else {
        const AVFrame *frame = decoder->frame;
        const uint8_t *in_data[AV_NUM_DATA_POINTERS];
        int bytes_per_sample = av_get_bytes_per_sample(frame->format);
        int planar = av_sample_fmt_is_planar(frame->format);
        int planes = planar ? frame->ch_layout.nb_channels : 1;
        int remaining = frame->nb_samples - (int)decoder->emitted_from_frame;
        int index;

        if (remaining < 0) {
            remaining = 0;
        }
        /* Ask the resampler how much room its own conversion needs rather than
         * assuming the input count is the output count. */
        needed = swr_get_out_samples(decoder->swr, remaining);
        if (needed < remaining + 1) {
            needed = remaining + 1;
        }
        if (ff_stage_reserve(decoder, needed) < 0) {
            *failure = FF_DECODE_DECODE_FAILED;
            return -1;
        }
        for (index = 0; index < AV_NUM_DATA_POINTERS; index++) {
            in_data[index] = NULL;
        }
        for (index = 0; index < planes && index < AV_NUM_DATA_POINTERS; index++) {
            in_data[index] =
                frame->extended_data[index] + decoder->emitted_from_frame * bytes_per_sample;
        }
        if (ff_trace_enabled()) {
            fprintf(stderr,
                    "ff_trace convert fmt=%d planar=%d planes=%d ch=%d nb_samples=%d "
                    "emitted=%lld remaining=%d needed=%d in0=%p\n",
                    (int)frame->format, planar, planes, frame->ch_layout.nb_channels,
                    frame->nb_samples, (long long)decoder->emitted_from_frame, remaining, needed,
                    (void *)in_data[0]);
        }
        produced = swr_convert(decoder->swr, (uint8_t **)&decoder->stage, needed, in_data,
                               remaining);
        if (produced < 0) {
            *failure = FF_DECODE_DECODE_FAILED;
            return -1;
        }
        /* The frame offset is measured in *input* samples, so it is timed with the
         * source rate; the produced count is output samples at the pipeline rate. */
        block_time = decoder->frame_media_us +
                     decoder->emitted_from_frame * 1000000 / decoder->source_rate;
        decoder->next_output_us = block_time + (long long)produced * 1000000 / decoder->output_rate;
        decoder->emitted_from_frame += remaining;
        if (decoder->emitted_from_frame >= frame->nb_samples) {
            decoder->frame_ready = 0;
            decoder->emitted_from_frame = 0;
        }
        if (produced == 0) {
            /* The resampler wants more input before it can produce anything. */
            decoder->stage_offset = 0;
            decoder->stage_count = 0;
            return 1;
        }
    }
    decoder->stage_offset = 0;
    decoder->stage_count = produced;
    decoder->stage_media_us = block_time;
    return 1;
}

/* Pulls one decoded frame into `decoder->frame`; returns 1 on success, 0 when
 * the decoder is drained and a negative value on failure. */
static int ff_next_frame(ff_decoder *decoder)
{
    int result;

    for (;;) {
        if (ff_is_cancelled(decoder)) {
            return -FF_DECODE_CANCELLED;
        }
        result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result == 0) {
            decoder->frame_ready = 1;
            decoder->emitted_from_frame = 0;
            decoder->frame_media_us = 0;
            if (decoder->frame->best_effort_timestamp != AV_NOPTS_VALUE) {
                decoder->frame_media_us = av_rescale_q(
                    decoder->frame->best_effort_timestamp,
                    decoder->format->streams[decoder->stream_index]->time_base,
                    (AVRational){ 1, 1000000 });
            }
            return 1;
        }
        if (result == AVERROR_EOF) {
            return 0;
        }
        if (result != AVERROR(EAGAIN)) {
            return -FF_DECODE_DECODE_FAILED;
        }
        /* The decoder needs input. Once the flush packet has been sent there is
         * nothing left to feed, so a repeated EAGAIN must end the stream rather
         * than spin here. */
        if (decoder->input_drained) {
            return 0;
        }
        if (!decoder->eof_seen) {
            result = av_read_frame(decoder->format, decoder->packet);
            /* An interrupted AVIO read may still yield a truncated packet.
             * Retiring workers must not feed it to the codec (notably s24le
             * packets whose partial size is not a whole sample frame). */
            if (ff_is_cancelled(decoder)) {
                av_packet_unref(decoder->packet);
                return -FF_DECODE_CANCELLED;
            }
            if (result < 0) {
                /* A cancelled or failed I/O operation is not a clean EOF. Its
                 * decoder must never be handed back for seek reuse. */
                if (result != AVERROR_EOF) {
                    return ff_is_cancelled(decoder) || result == AVERROR_EXIT
                        ? -FF_DECODE_CANCELLED : -FF_DECODE_DECODE_FAILED;
                }
                decoder->eof_seen = 1;
                if (avcodec_send_packet(decoder->codec, NULL) >= 0 || result == AVERROR_EOF) {
                    decoder->input_drained = 1;
                }
                continue;
            }
            if (decoder->packet->stream_index == decoder->stream_index) {
                result = avcodec_send_packet(decoder->codec, decoder->packet);
                av_packet_unref(decoder->packet);
                if (result < 0 && result != AVERROR(EAGAIN)) {
                    return -FF_DECODE_DECODE_FAILED;
                }
            } else {
                av_packet_unref(decoder->packet);
            }
            continue;
        }
        result = avcodec_send_packet(decoder->codec, NULL);
        if (result < 0 && result != AVERROR_EOF && result != AVERROR(EAGAIN)) {
            return -FF_DECODE_DECODE_FAILED;
        }
        decoder->input_drained = 1;
    }
}

int ff_decoder_read(ff_decoder *decoder, float *out, int max_frames, int *frames_out,
                    long long *media_time_us)
{
    if (frames_out != NULL) {
        *frames_out = 0;
    }
    if (decoder == NULL || out == NULL || frames_out == NULL || max_frames <= 0) {
        return FF_DECODE_DECODE_FAILED;
    }
    for (;;) {
        int available;
        int frames;
        long long block_time;

        if (ff_is_cancelled(decoder)) {
            return FF_DECODE_CANCELLED;
        }
        if (decoder->stage_offset >= decoder->stage_count) {
            int failure = FF_DECODE_DECODE_FAILED;
            int status;
            decoder->stage_offset = 0;
            decoder->stage_count = 0;
            status = ff_fill_stage(decoder, &failure);
            if (status < 0) {
                return failure;
            }
            if (status == 0) {
                return FF_DECODE_END_OF_STREAM;
            }
            if (decoder->stage_count == 0) {
                continue;
            }
        }
        available = decoder->stage_count - decoder->stage_offset;
        block_time = decoder->stage_media_us +
                     (long long)decoder->stage_offset * 1000000 / decoder->output_rate;
        /* After a seek, output before the target is decoded and dropped so the
         * caller's clock never reports a position it did not reach (docs/design/playback.md:
         * discard the samples preceding the target). The staged block is skipped
         * as a whole while it is still short of the target. */
        if (decoder->discard_until_us >= 0) {
            long long block_end = block_time + (long long)available * 1000000 / decoder->output_rate;
            if (block_end <= decoder->discard_until_us) {
                decoder->stage_offset = decoder->stage_count;
                continue;
            }
            if (block_time < decoder->discard_until_us) {
                int drop = (int)((decoder->discard_until_us - block_time) * decoder->output_rate / 1000000);
                if (drop > available) {
                    drop = available;
                }
                decoder->stage_offset += drop;
                available -= drop;
                block_time += (long long)drop * 1000000 / decoder->output_rate;
            }
            decoder->discard_until_us = -1;
        }
        frames = available < max_frames ? available : max_frames;
        memcpy(out, decoder->stage + (size_t)decoder->stage_offset * decoder->output_channels,
               (size_t)frames * decoder->output_channels * sizeof(float));
        decoder->stage_offset += frames;
        *frames_out = frames;
        if (media_time_us != NULL) {
            *media_time_us = block_time;
        }
        return FF_DECODE_OK;
    }
}

int ff_decoder_seek(ff_decoder *decoder, long long position_ms, long long *actual_media_us)
{
    int64_t target_us = position_ms * 1000;
    int64_t timestamp;
    int result;

    if (decoder == NULL) {
        return FF_DECODE_SEEK_FAILED;
    }
    timestamp = av_rescale_q(target_us, (AVRational){ 1, 1000000 },
                             decoder->format->streams[decoder->stream_index]->time_base);
    result = av_seek_frame(decoder->format, decoder->stream_index, timestamp, AVSEEK_FLAG_BACKWARD);
    if (result < 0) {
        return FF_DECODE_SEEK_FAILED;
    }
    avcodec_flush_buffers(decoder->codec);
    /* A fresh resampler: re-initialising the existing one leaves the SoXR instance
     * holding state from the previous position. */
    if (ff_open_resampler(decoder, NULL, 0) != FF_DECODE_OK) {
        return FF_DECODE_SEEK_FAILED;
    }
    av_packet_unref(decoder->packet);
    ff_decoder_reset_output(decoder);
    decoder->input_drained = 0;
    decoder->output_drained = 0;
    decoder->eof_seen = 0;
    decoder->discard_until_us = target_us;
    decoder->next_output_us = target_us;
    if (ff_trace_enabled()) {
        fprintf(stderr, "ff_trace seek decoder=%p target_ms=%lld\n", (void *)decoder,
                (long long)position_ms);
    }
    if (actual_media_us != NULL) {
        *actual_media_us = target_us;
    }
    return FF_DECODE_OK;
}

void ff_decoder_close(ff_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    swr_free(&decoder->swr);
    avcodec_free_context(&decoder->codec);
    avformat_close_input(&decoder->format);
    if (decoder->input_io != NULL) { av_freep(&decoder->input_io->buffer); avio_context_free(&decoder->input_io); }
    free(decoder->stage);
    free(decoder);
}

/* Called only before reads (or after quiescing and seeking). */
int ff_decoder_configure_output(ff_decoder *decoder, int rate, int channels) {
    if (!decoder || rate < 8000 || rate > 384000 || channels < 1 || channels > 8) return FF_DECODE_UNSUPPORTED_FORMAT;
    if(decoder->output_channels!=channels){free(decoder->stage);decoder->stage=NULL;decoder->stage_capacity=0;}
    decoder->output_rate=rate;decoder->output_channels=channels;
    decoder->stage_count=0;decoder->stage_offset=0;decoder->output_drained=0;
    char error[256]; return ff_open_resampler(decoder,error,sizeof(error));
}
