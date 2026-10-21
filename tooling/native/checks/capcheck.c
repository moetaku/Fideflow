/*
 * Fideflow native capability probe (docs/design/native-build.md verification).
 *
 * Links against a freshly built offline FFmpeg/libsoxr prefix and proves, per
 * architecture and without shipping any external fixture:
 *   - the FFmpeg configuration string carries the expected component flags;
 *   - exactly the allowlisted input protocols exist for the network mode;
 *   - every allowlisted decoder, demuxer and parser is available;
 *   - a synthesized 44.1 kHz mono s16 WAV decodes and resamples to 48 kHz
 *     stereo float32 through libswresample with the soxr engine selected.
 *
 * Exit status is non-zero when any check fails. The last line is a one-line
 * JSON summary so the build script can archive machine-readable evidence.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <process.h>
#define getpid _getpid
#define setenv(key, value, overwrite) _putenv_s(key, value)
#else
#include <unistd.h>
#endif

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#define FF_TEST_RATE 44100
#define FF_TEST_MILLISECONDS 250
#define FF_OUTPUT_RATE 48000
#define FF_OUTPUT_CHANNELS 2
#define FF_OUTPUT_SAMPLE_FORMAT AV_SAMPLE_FMT_FLT
#define FF_OUT_CAPACITY (FF_OUTPUT_RATE * FF_OUTPUT_CHANNELS * 4)

static int g_failures;

static void check(int ok, const char *what, const char *detail)
{
    printf("  %s %s%s%s\n", ok ? "ok  " : "FAIL", what, detail ? ": " : "",
           detail ? detail : "");
    if (!ok) {
        g_failures++;
    }
}

static int contains(const char *haystack, const char *needle)
{
    return haystack != NULL && strstr(haystack, needle) != NULL;
}

static int list_has_word(const char *list, const char *word)
{
    size_t length = strlen(word);
    const char *at = list;

    while (at != NULL && (at = strstr(at, word)) != NULL) {
        int left = (at == list) || (at[-1] == ' ');
        int right = (at[length] == ' ' || at[length] == '\0');

        if (left && right) {
            return 1;
        }
        at += length;
    }
    return 0;
}

/* ------------------------------------------------------------------ probe */

static void probe_configuration(const char *network, const char **configuration)
{
    const char *config = avcodec_configuration();

    *configuration = config;
    printf("FFmpeg %s\n", av_version_info());
    printf("libavcodec %u, libavformat %u, libavutil %u, libswresample %u\n",
           avcodec_version(), avformat_version(), avutil_version(), swresample_version());
    printf("configuration: %s\n\n", config);

    check(contains(config, "--enable-libsoxr"), "ffmpeg built with --enable-libsoxr", NULL);
    check(!contains(config, "--enable-gpl"), "ffmpeg built without --enable-gpl", NULL);
    check(!contains(config, "--enable-nonfree"), "ffmpeg built without --enable-nonfree", NULL);
    check(contains(config, "--disable-autodetect"), "ffmpeg built without autodetected system libraries", NULL);

    check(strcmp(network, "off") == 0, "only offline FFmpeg is supported", NULL);
    check(contains(config, "--disable-network"), "ffmpeg built with --disable-network", NULL);
    check(!contains(config, "--enable-network"), "network is not enabled", NULL);
    check(contains(config, "--disable-openssl"), "OpenSSL disabled", NULL);
    check(contains(config, "--disable-securetransport") && contains(config, "--disable-schannel"), "system TLS disabled", NULL);

}

static void probe_protocols(const char *network, char *seen, size_t seen_size)
{
    void *opaque = NULL;
    const char *name;
    size_t used = 0;

    seen[0] = '\0';
    while ((name = avio_enum_protocols(&opaque, 0)) != NULL) {
        size_t length = strlen(name);
        check(strcmp(name, "file") == 0 || strcmp(name, "pipe") == 0, "only file/pipe protocols are allowed", name);

        if (used + length + 2 >= seen_size) {
            break;
        }
        memcpy(seen + used, name, length);
        used += length;
        seen[used++] = ' ';
        seen[used] = '\0';
    }
    check(used > 0, "input protocol list", seen);

    check(list_has_word(seen, "file"), "protocol file available", NULL);
    check(list_has_word(seen, "pipe"), "protocol pipe available", NULL);
    (void)network;
    check(!list_has_word(seen, "http"), "protocol http absent", NULL);
    check(!list_has_word(seen, "https"), "protocol https absent", NULL);
    check(!list_has_word(seen, "tls"), "protocol tls absent", NULL);
    check(!list_has_word(seen, "tcp"), "protocol tcp absent", NULL);
    check(!list_has_word(seen, "udp"), "protocol udp absent", NULL);

}

static void probe_codecs(void)
{
    static const struct {
        enum AVCodecID id;
        const char *label;
    } decoders[] = {
        { AV_CODEC_ID_MP3, "mp3" },
        { AV_CODEC_ID_AAC, "aac" },
        { AV_CODEC_ID_FLAC, "flac" },
        { AV_CODEC_ID_ALAC, "alac" },
        { AV_CODEC_ID_VORBIS, "vorbis" },
        { AV_CODEC_ID_OPUS, "opus" },
        { AV_CODEC_ID_PCM_S16LE, "pcm_s16le" },
    };
    static const char *demuxers[] = {
        "aac", "flac", "matroska", "mov", "mp3", "ogg", "wav",
    };
    static const enum AVCodecID parsers[] = {
        AV_CODEC_ID_MP3, AV_CODEC_ID_AAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_VORBIS,
        AV_CODEC_ID_OPUS,
    };
    size_t index;

    for (index = 0; index < sizeof(decoders) / sizeof(decoders[0]); index++) {
        check(avcodec_find_decoder(decoders[index].id) != NULL, "decoder", decoders[index].label);
    }
    for (index = 0; index < sizeof(demuxers) / sizeof(demuxers[0]); index++) {
        check(av_find_input_format(demuxers[index]) != NULL, "demuxer", demuxers[index]);
    }
    for (index = 0; index < sizeof(parsers) / sizeof(parsers[0]); index++) {
        AVCodecParserContext *parser = av_parser_init((int)parsers[index]);

        check(parser != NULL, "parser", avcodec_get_name(parsers[index]));
        if (parser != NULL) {
            av_parser_close(parser);
        }
    }
}

/* --------------------------------------------------------- wav synthesis */

static void put_le16(unsigned char *at, unsigned value)
{
    at[0] = (unsigned char)(value & 0xffu);
    at[1] = (unsigned char)((value >> 8) & 0xffu);
}

static void put_le32(unsigned char *at, unsigned value)
{
    at[0] = (unsigned char)(value & 0xffu);
    at[1] = (unsigned char)((value >> 8) & 0xffu);
    at[2] = (unsigned char)((value >> 16) & 0xffu);
    at[3] = (unsigned char)((value >> 24) & 0xffu);
}

static int write_test_wav(const char *path, int *frames_out)
{
    int frames = FF_TEST_RATE * FF_TEST_MILLISECONDS / 1000;
    unsigned data_bytes = (unsigned)(frames * 2);
    unsigned char header[44];
    FILE *file;
    int index;

    memcpy(header, "RIFF", 4);
    put_le32(header + 4, 36u + data_bytes);
    memcpy(header + 8, "WAVEfmt ", 8);
    put_le32(header + 16, 16u);
    put_le16(header + 20, 1u);  /* PCM */
    put_le16(header + 22, 1u);  /* mono */
    put_le32(header + 24, FF_TEST_RATE);
    put_le32(header + 28, FF_TEST_RATE * 2u);
    put_le16(header + 32, 2u);
    put_le16(header + 34, 16u);
    memcpy(header + 36, "data", 4);
    put_le32(header + 40, data_bytes);

    file = fopen(path, "wb");
    if (file == NULL) {
        return -1;
    }
    if (fwrite(header, 1, sizeof(header), file) != sizeof(header)) {
        fclose(file);
        return -1;
    }
    for (index = 0; index < frames; index++) {
        double value = sin(2.0 * 3.14159265358979323846 * 440.0 * index / FF_TEST_RATE);
        int sample = (int)(value * 12000.0);
        unsigned char bytes[2];

        put_le16(bytes, (unsigned)(sample & 0xffff));
        if (fwrite(bytes, 1, 2, file) != 2) {
            fclose(file);
            return -1;
        }
    }
    if (fclose(file) != 0) {
        return -1;
    }
    *frames_out = frames;
    return 0;
}

/* ------------------------------------------------- decode and resample */

static int64_t convert(SwrContext *swr, AVFrame *frame, unsigned char *out, int capacity)
{
    unsigned char *out_planes[1];
    int produced;

    out_planes[0] = out;
    produced = swr_convert(swr, out_planes, capacity,
                           (const uint8_t **)frame->extended_data, frame->nb_samples);
    return produced < 0 ? -1 : produced;
}

static void probe_decode(const char *wav_path, int frames, long long *output_samples)
{
    AVFormatContext *format = NULL;
    AVCodecContext *decoder = NULL;
    SwrContext *swr = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    unsigned char *out = NULL;
    AVChannelLayout out_layout;
    int64_t decoded_input = 0;
    int64_t produced_output = 0;
    int stream_index;
    int64_t engine = -1;
    int ret;

    *output_samples = 0;
    check(avformat_open_input(&format, wav_path, NULL, NULL) >= 0, "open synthesized wav", wav_path);
    if (format == NULL) {
        goto cleanup;
    }
    check(avformat_find_stream_info(format, NULL) >= 0, "read stream info", NULL);
    stream_index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    check(stream_index >= 0, "find audio stream", NULL);
    if (stream_index < 0) {
        goto cleanup;
    }
    decoder = avcodec_alloc_context3(NULL);
    ret = avcodec_parameters_to_context(decoder, format->streams[stream_index]->codecpar);
    check(ret >= 0 && avcodec_open2(decoder, avcodec_find_decoder(decoder->codec_id), NULL) >= 0,
          "open pcm decoder", avcodec_get_name(decoder->codec_id));

    av_channel_layout_default(&out_layout, FF_OUTPUT_CHANNELS);
    ret = swr_alloc_set_opts2(&swr, &out_layout, FF_OUTPUT_SAMPLE_FORMAT, FF_OUTPUT_RATE,
                              &decoder->ch_layout, decoder->sample_fmt, decoder->sample_rate, 0, NULL);
    check(ret >= 0 && swr != NULL, "swr_alloc_set_opts2", NULL);
    if (swr == NULL) {
        goto cleanup;
    }
    ret = av_opt_set(swr, "resampler", "soxr", 0);
    check(ret >= 0, "select soxr resampler", ret < 0 ? "swresample has no soxr engine" : NULL);
    if (ret >= 0 && av_opt_get_int(swr, "resampler", 0, &engine) >= 0) {
        /* swresample's first engine is the built-in swr resampler; anything else
         * means the requested soxr engine is what the context will use. */
        check(engine != 0, "resampler engine is not the default swr engine", NULL);
    }
    ret = swr_init(swr);
    check(ret >= 0, "swr_init", NULL);
    if (ret < 0) {
        goto cleanup;
    }

    out = malloc(FF_OUT_CAPACITY);
    packet = av_packet_alloc();
    frame = av_frame_alloc();
    check(out != NULL && packet != NULL && frame != NULL, "allocate decode buffers", NULL);
    if (out == NULL || packet == NULL || frame == NULL) {
        goto cleanup;
    }

    while ((ret = av_read_frame(format, packet)) >= 0) {
        int64_t produced;

        if (packet->stream_index != stream_index) {
            av_packet_unref(packet);
            continue;
        }
        if (avcodec_send_packet(decoder, packet) < 0) {
            av_packet_unref(packet);
            break;
        }
        av_packet_unref(packet);
        while (avcodec_receive_frame(decoder, frame) >= 0) {
            decoded_input += frame->nb_samples;
            produced = convert(swr, frame, out, FF_OUT_CAPACITY);
            if (produced < 0) {
                check(0, "swr_convert", "failed");
                break;
            }
            produced_output += produced;
            av_frame_unref(frame);
        }
    }
    if (avcodec_send_packet(decoder, NULL) >= 0) {
        while (avcodec_receive_frame(decoder, frame) >= 0) {
            decoded_input += frame->nb_samples;
            produced_output += convert(swr, frame, out, FF_OUT_CAPACITY);
            av_frame_unref(frame);
        }
    }
    {
        unsigned char *planes[1];

        planes[0] = out;
        ret = swr_convert(swr, planes, FF_OUT_CAPACITY, NULL, 0);
        if (ret > 0) {
            produced_output += ret;
        }
    }

    check(decoded_input == frames, "decoded every synthesized sample", NULL);
    check(produced_output > 0, "resampled output produced", NULL);
    {
        double expected = (double)decoded_input * FF_OUTPUT_RATE / FF_TEST_RATE;
        double delta = fabs((double)produced_output - expected) / (expected > 0 ? expected : 1.0);

        check(delta < 0.02, "resampled length within 2% of 48 kHz expectation", NULL);
    }
    printf("  info decoded %lld input samples -> %lld output samples at %d Hz, %d channels\n",
           (long long)decoded_input, (long long)produced_output, FF_OUTPUT_RATE, FF_OUTPUT_CHANNELS);
    *output_samples = produced_output;

cleanup:
    free(out);
    av_frame_free(&frame);
    av_packet_free(&packet);
    swr_free(&swr);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
}

/* ----------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    const char *arch = "unknown";
    const char *network = "off";
    const char *configuration = "";
    char wav_path[512];
    char protocols[4096];
    long long output_samples = 0;
    int smoke_bytes = 0;
    int frames = 0;
    int index;

    for (index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--arch") == 0 && index + 1 < argc) {
            arch = argv[++index];
        } else if (strcmp(argv[index], "--network") == 0 && index + 1 < argc) {
            network = argv[++index];
        }
    }

    printf("== Fideflow native capability probe (%s, network=%s) ==\n", arch, network);

    probe_configuration(network, &configuration);
    probe_protocols(network, protocols, sizeof(protocols));
    probe_codecs();

    snprintf(wav_path, sizeof(wav_path), "%s/ff-capcheck-%d.wav",
             getenv("TMPDIR") != NULL ? getenv("TMPDIR") : "/tmp", (int)getpid());
    if (write_test_wav(wav_path, &frames) != 0) {
        check(0, "write synthesized wav", wav_path);
    } else {
        probe_decode(wav_path, frames, &output_samples);
        remove(wav_path);
    }
    printf("\n{\"arch\":\"%s\",\"network\":\"%s\",\"decodedFrames\":%d,\"outputSamples\":%lld,"
           "\"resampler\":\"soxr\",\"tlsSmokeBytes\":%d,\"failures\":%d}\n",
           arch, network, frames, output_samples, smoke_bytes, g_failures);

    if (g_failures > 0) {
        printf("capability probe failed: %d check(s)\n", g_failures);
        return 1;
    }
    printf("capability probe passed\n");
    return 0;
}
