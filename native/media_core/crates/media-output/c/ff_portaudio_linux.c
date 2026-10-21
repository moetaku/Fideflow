/* Pinned PortAudio transport, ALSA device-name policy. Control calls are
 * serialized by Rust CONTROL; the render callback only touches its own state. */
#define _POSIX_C_SOURCE 200809L
#include <portaudio.h>
#include <pa_linux_alsa.h>
#include <alsa/asoundlib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <alloca.h>
#include <time.h>
#include <sys/stat.h>
#include <spawn.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>

#define FF_UID_BYTES 1024
#define FF_NAME_BYTES 256
#define FF_MAX_DEVICES 256

typedef void (*ff_render_callback)(float *, unsigned int, void *);
typedef struct { char uid[FF_UID_BYTES], name[FF_NAME_BYTES]; int is_default, exclusive_supported; } ff_device_info;
typedef struct { char device_name[FF_NAME_BYTES], device_uid[FF_UID_BYTES]; int sample_rate, channels, internal_format; unsigned int period_frames, periods; double period_seconds; } ff_output_info;
typedef struct { char name[FF_UID_BYTES], profile[FF_NAME_BYTES], default_sink[FF_UID_BYTES]; } ff_desktop_lease;
typedef struct ff_output {
    PaStream *stream;
    ff_render_callback render;
    void *user;
    char pcm[FF_UID_BYTES], uid[FF_UID_BYTES], name[FF_NAME_BYTES];
    unsigned int channels, rate, period;
    int exclusive;
    ff_desktop_lease lease[FF_MAX_DEVICES];
    size_t lease_count;
    _Atomic int stopping, failed;
    struct ff_output *next;
} ff_output;
static ff_output *live_outputs;
static unsigned int refs;
static _Atomic unsigned int changes;
static uint64_t last_devices, last_config, last_default;
static char desktop_pcm[FF_UID_BYTES], desktop_name[FF_NAME_BYTES];
extern char **environ;
static struct timespec last_poll;

/* Resolve the desktop route without changing system ALSA configuration. */
static int pcm_available(const char *name) {
    snd_pcm_t *handle = NULL;
    int result = snd_pcm_open(&handle, name, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
    if (handle) snd_pcm_close(handle);
    return result >= 0 || result == -EBUSY;
}
/* Control plane only. Keep UTF-8 descriptions and stable English field names
 * even when the SSH or desktop process inherited the C locale. */
static int pactl(char *const arguments[], char *text, size_t capacity) {
    int descriptors[2];
    if (!capacity || pipe(descriptors)) return -1;
    text[0] = 0;
    fcntl(descriptors[0], F_SETFD, FD_CLOEXEC);
    fcntl(descriptors[0], F_SETFL, O_NONBLOCK);
    fcntl(descriptors[1], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&actions, descriptors[0]);
    posix_spawn_file_actions_addclose(&actions, descriptors[1]);
    size_t env_count = 0;
    while (environ[env_count]) ++env_count;
    char **env = calloc(env_count + 2, sizeof(*env));
    if (!env) {
        posix_spawn_file_actions_destroy(&actions);
        close(descriptors[0]); close(descriptors[1]); return -1;
    }
    size_t n = 0;
    for (size_t i = 0; i < env_count; ++i)
        if (strncmp(environ[i], "LC_ALL=", 7)) env[n++] = environ[i];
    env[n] = "LC_ALL=C.UTF-8";
    pid_t child;
    int result = posix_spawnp(&child, "pactl", &actions, NULL, arguments, env);
    free(env);
    posix_spawn_file_actions_destroy(&actions);
    close(descriptors[1]);
    if (result) { close(descriptors[0]); return -1; }
    size_t used = 0;
    struct pollfd descriptor = {.fd = descriptors[0], .events = POLLIN};
    struct timespec started, now;
    clock_gettime(CLOCK_MONOTONIC, &started);
    int status = 0, complete = 0, overflow = 0;
    do {
        if (poll(&descriptor, 1, 10) > 0) {
            char chunk[4096];
            ssize_t bytes;
            while ((bytes = read(descriptors[0], chunk, sizeof(chunk))) > 0) {
                if ((size_t)bytes >= capacity - used) { overflow = 1; break; }
                memcpy(text + used, chunk, (size_t)bytes); used += (size_t)bytes;
            }
        }
        if (waitpid(child, &status, WNOHANG) == child) { complete = 1; break; }
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while (!overflow && (now.tv_sec-started.tv_sec)*1000 + (now.tv_nsec-started.tv_nsec)/1000000 < 1000);
    if (complete && !overflow) {
        ssize_t bytes;
        while ((bytes = read(descriptors[0], text + used, capacity-1-used)) > 0)
            used += (size_t)bytes;
        if (used == capacity-1) overflow = 1;
    }
    close(descriptors[0]);
    if (!complete) { kill(child, SIGKILL); waitpid(child, &status, 0); }
    text[used] = 0;
    return complete && !overflow && WIFEXITED(status) && !WEXITSTATUS(status) ? 0 : -1;
}
typedef struct {
    char name[FF_UID_BYTES], description[FF_NAME_BYTES], profile[FF_NAME_BYTES];
    int card, device, suspended;
    unsigned int index;
} ff_desktop_sink;
static ff_desktop_sink desktop_sinks[FF_MAX_DEVICES];
static int desktop_count;
static int safe_sink_name(const char *name) {
    if (!*name) return 0;
    for (const char *c = name; *c; ++c)
        if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
              (*c >= '0' && *c <= '9') || strchr("_.-", *c))) return 0;
    return strlen(name) + sizeof("pulse:DEVICE=") <= FF_UID_BYTES;
}
static int parse_sinks(char *text, ff_desktop_sink *sinks) {
    int count = 0;
    ff_desktop_sink *sink = NULL;
    char *save = NULL;
    for (char *line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (!strncmp(line, "Sink #", 6) || !strncmp(line, "Card #", 6)) {
            if (count == FF_MAX_DEVICES) return -1;
            sink = &sinks[count++]; memset(sink, 0, sizeof(*sink)); sink->card = sink->device = -1;
            sscanf(line+6, "%u", &sink->index);
        } else if (sink) {
            while (*line == '\t' || *line == ' ') ++line;
            if (!strncmp(line, "Name: ", 6)) snprintf(sink->name, sizeof(sink->name), "%s", line+6);
            else if (!strncmp(line, "Description: ", 13)) snprintf(sink->description, sizeof(sink->description), "%s", line+13);
            else if (!strncmp(line, "Active Profile: ", 16)) snprintf(sink->profile, sizeof(sink->profile), "%s", line+16);
            else if (!strncmp(line, "State: ", 7)) sink->suspended = !strcmp(line+7, "SUSPENDED");
            else if (!strncmp(line, "alsa.device = ", 14)) sscanf(line+14, "\"%d\"", &sink->device);
            else if (!strncmp(line, "alsa.card = ", 12)) sscanf(line+12, "\"%d\"", &sink->card);
        }
    }
    for (int i = 0; i < count; ++i) if (!safe_sink_name(sinks[i].name)) return -1;
    return count;
}
static void refresh_desktop_default(void) {
    desktop_pcm[0] = desktop_name[0] = 0;
    desktop_count = 0;
    char *text = malloc(1024 * 1024);
    if (!text) return;
    char *list[] = {"pactl", "list", "sinks", NULL};
    if (!pactl(list, text, 1024 * 1024)) {
        int count = parse_sinks(text, desktop_sinks);
        if (count > 0) desktop_count = count;
    }
    free(text);
    char name[FF_UID_BYTES];
    char *args[] = {"pactl", "get-default-sink", NULL};
    if (pactl(args, name, sizeof(name))) return;
    name[strcspn(name, "\r\n")] = 0;
    for (int i = 0; i < desktop_count; ++i) if (!strcmp(name, desktop_sinks[i].name)) {
        snprintf(desktop_pcm, sizeof(desktop_pcm), "pulse:DEVICE=%.*s", FF_UID_BYTES-14, name);
        snprintf(desktop_name, sizeof(desktop_name), "%.*s", FF_NAME_BYTES-1, desktop_sinks[i].description);
        break;
    }
}
static int card_profile(const char *name, const char *profile) {
    char ignored[128];
    char *args[] = {"pactl", "set-card-profile", (char *)name, (char *)profile, NULL};
    return pactl(args, ignored, sizeof(ignored));
}
static void restore_desktop(ff_desktop_lease *lease, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        if (!lease[i].profile[0]) continue;
        if (card_profile(lease[i].name, lease[i].profile))
            fprintf(stderr, "Fideflow: unable to restore desktop audio profile for %s\n", lease[i].name);
    }
    /* Nodes appear asynchronously after restoring a profile. Reattach only
     * streams that belonged to this card before acquisition. */
    for (size_t i = 0; i < count; ++i) {
        if (!lease[i].default_sink[0]) continue;
        if (lease[i].profile[0]) {
            char current[FF_UID_BYTES];
            char *get[] = {"pactl", "get-default-sink", NULL};
            if (!pactl(get, current, sizeof(current))) {
                current[strcspn(current, "\r\n")] = 0;
                /* Reapplying an unchanged default can make WirePlumber move
                 * explicitly routed streams back to the default device. */
                if (!strcmp(current, lease[i].default_sink)) continue;
            }
        }
        char ignored[128];
        char *args[] = {"pactl", lease[i].profile[0] ? "set-default-sink" : "move-sink-input",
                        lease[i].profile[0] ? lease[i].default_sink : lease[i].name,
                        lease[i].profile[0] ? NULL : lease[i].default_sink, NULL};
        for (int attempt = 0; attempt < 20; ++attempt) {
            if (!pactl(args, ignored, sizeof(ignored))) break;
            struct timespec delay = {.tv_sec = 0, .tv_nsec = 10000000};
            nanosleep(&delay, NULL);
        }
    }
    if (count) refresh_desktop_default();
}
/* PipeWire can immediately reactivate a suspended sink with active clients.
 * Temporarily disable only the selected card's desktop profile, restoring its
 * prior profile on close or failure. This also releases coupled capture PCMs. */
static int acquire_desktop(const char *pcm, ff_desktop_lease *lease, size_t *count) {
    *count = 0;
    if (strncmp(pcm, "hw:", 3)) return 0;
    snd_ctl_t *ctl = NULL;
    char card_id[128];
    const char *card = pcm + 3;
    if (!strncmp(card, "CARD=", 5)) card += 5;
    size_t len = strcspn(card, ",");
    if (!len || len > sizeof(card_id)-4) return -1;
    snprintf(card_id, sizeof(card_id), "hw:%.*s", (int)len, card);
    if (snd_ctl_open(&ctl, card_id, SND_CTL_NONBLOCK) < 0) return -1;
    snd_ctl_card_info_t *ci; snd_ctl_card_info_alloca(&ci);
    int card_number = snd_ctl_card_info(ctl, ci) >= 0 ? snd_ctl_card_info_get_card(ci) : -1;
    snd_ctl_close(ctl);
    if (card_number < 0) return -1;
    char *text = malloc(1024 * 1024);
    ff_desktop_sink *cards = calloc(FF_MAX_DEVICES, sizeof(*cards));
    if (!text || !cards) { free(text); free(cards); return -1; }
    char *args[] = {"pactl", "list", "cards", NULL};
    int cards_count = pactl(args, text, 1024 * 1024) ? 0 : parse_sinks(text, cards);
    free(text);
    int failed = 0;
    for (int i = 0; i < cards_count; ++i) {
        ff_desktop_sink *item = &cards[i];
        if (item->card != card_number || !item->profile[0] || !strcmp(item->profile, "off")) continue;
        if (*count >= FF_MAX_DEVICES) { failed = 1; break; }
        ff_desktop_lease *entry = &lease[(*count)++];
        memset(entry, 0, sizeof(*entry));
        snprintf(entry->name, sizeof(entry->name), "%.*s", FF_UID_BYTES-1, item->name);
        snprintf(entry->profile, sizeof(entry->profile), "%.*s", FF_NAME_BYTES-1, item->profile);
        char *get_default[] = {"pactl", "get-default-sink", NULL};
        if (!pactl(get_default, entry->default_sink, sizeof(entry->default_sink)))
            entry->default_sink[strcspn(entry->default_sink, "\r\n")] = 0;
        else entry->default_sink[0] = 0;
        refresh_desktop_default();
        char *inputs = malloc(65536);
        if (!inputs) { failed = 1; break; }
        char *list_inputs[] = {"pactl", "list", "short", "sink-inputs", NULL};
        if (!pactl(list_inputs, inputs, 65536)) {
            char *save = NULL;
            for (char *line = strtok_r(inputs, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
                unsigned int input, sink;
                if (sscanf(line, "%u %u", &input, &sink) != 2) continue;
                for (int j = 0; j < desktop_count; ++j) {
                    if (desktop_sinks[j].card != card_number || desktop_sinks[j].index != sink) continue;
                    if (*count >= FF_MAX_DEVICES) { failed = 1; break; }
                    ff_desktop_lease *stream = &lease[(*count)++];
                    memset(stream, 0, sizeof(*stream));
                    snprintf(stream->name, sizeof(stream->name), "%u", input);
                    snprintf(stream->default_sink, sizeof(stream->default_sink), "%.*s", FF_UID_BYTES-1, desktop_sinks[j].name);
                }
            }
        } else failed = 1;
        free(inputs);
        if (failed || card_profile(entry->name, "off")) { failed = 1; break; }
    }
    free(cards);
    /* Profile changes are asynchronous with respect to closing ALSA fds. */
    for (int attempt = 0; !failed && attempt < 100; ++attempt) {
        snd_pcm_t *probe = NULL;
        int result = snd_pcm_open(&probe, pcm, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
        if (probe) snd_pcm_close(probe);
        if (result >= 0) return 0;
        if (result != -EBUSY) break;
        struct timespec delay = {.tv_sec = 0, .tv_nsec = 5000000};
        nanosleep(&delay, NULL);
    }
    restore_desktop(lease, *count); *count = 0;
    return -1;
}
static const char *default_pcm(void) {
    if (desktop_pcm[0]) return desktop_pcm;
    const char *routes[] = {"default", "pipewire", "pulse"};
    for (size_t i = 0; i < sizeof(routes) / sizeof(*routes); ++i)
        if (pcm_available(routes[i])) return routes[i];
    return "default";
}
static const char *pcm_name(const char *uid) {
    if (!uid || !uid[0] || !strcmp(uid, "alsa:default")) return default_pcm();
    if (strncmp(uid, "alsa:", 5) || !uid[5]) return NULL;
    /* Preserve saved selections from the former dmix-based shared list. */
    if (!strncmp(uid+5, "dmix:CARD=", 10)) {
        char card[128]; int device = 0;
        const char *id = uid+15;
        size_t length = strcspn(id, ",");
        if (length && length < sizeof(card)) {
            memcpy(card, id, length); card[length] = 0;
            int index = snd_card_get_index(card);
            const char *dev = strstr(id+length, ",DEV=");
            if (dev) sscanf(dev+5, "%d", &device);
            for (int i = 0; index >= 0 && i < desktop_count; ++i)
                if (desktop_sinks[i].card == index && desktop_sinks[i].device == device) {
                    static char shared[FF_UID_BYTES];
                    snprintf(shared, sizeof(shared), "pulse:DEVICE=%.*s", FF_UID_BYTES-14, desktop_sinks[i].name);
                    return shared;
                }
        }
    }
    return uid + 5;
}
static ff_output *current_output(const char *pcm) {
    for (ff_output *out = live_outputs; pcm && out; out = out->next)
        if (!strcmp(out->pcm, pcm) && !atomic_load(&out->failed)) return out;
    return NULL;
}
static uint64_t hash_bytes(uint64_t hash, const char *text) {
    for (; *text; ++text) hash = (hash ^ (unsigned char)*text) * UINT64_C(1099511628211);
    return hash;
}
static int compare_devices(const void *a, const void *b) {
    return strcmp(((const ff_device_info *)a)->uid, ((const ff_device_info *)b)->uid);
}
static int append_device(ff_device_info *out, size_t capacity, int count, const char *pcm, const char *name, int hardware) {
    for (int i = 0; i < count; ++i) if (!strcmp(out[i].uid + 5, pcm)) {
        if (hardware) out[i].exclusive_supported = 1;
        return count;
    }
    if ((size_t)count >= capacity || strlen(pcm) + 6 > FF_UID_BYTES) return -1;
    ff_device_info *device = &out[count];
    memset(device, 0, sizeof(*device));
    snprintf(device->uid, sizeof(device->uid), "alsa:%s", pcm);
    snprintf(device->name, sizeof(device->name), "%s", name && *name ? name : pcm);
    for (char *p = device->name; *p; ++p) if (*p == '\n') *p = ' ';
    device->is_default = !strcmp(pcm, "default");
    device->exclusive_supported = hardware;
    return count + 1;
}
static int hardware_devices(ff_device_info *out, size_t capacity, int count) {
    int card = -1;
    while (snd_card_next(&card) >= 0 && card >= 0) {
        char control[32]; snprintf(control, sizeof(control), "hw:%d", card);
        snd_ctl_t *ctl = NULL;
        if (snd_ctl_open(&ctl, control, SND_CTL_NONBLOCK) < 0) continue;
        snd_ctl_card_info_t *card_info; snd_ctl_card_info_alloca(&card_info);
        snd_pcm_info_t *pcm_info; snd_pcm_info_alloca(&pcm_info);
        if (snd_ctl_card_info(ctl, card_info) >= 0) {
            int device = -1;
            while (snd_ctl_pcm_next_device(ctl, &device) >= 0 && device >= 0) {
                snd_pcm_info_set_device(pcm_info, (unsigned int)device);
                snd_pcm_info_set_subdevice(pcm_info, 0);
                snd_pcm_info_set_stream(pcm_info, SND_PCM_STREAM_PLAYBACK);
                if (snd_ctl_pcm_info(ctl, pcm_info) < 0) continue;
                char pcm[FF_UID_BYTES], name[FF_NAME_BYTES];
                snprintf(pcm, sizeof(pcm), "hw:CARD=%s,DEV=%d,SUBDEV=0", snd_ctl_card_info_get_id(card_info), device);
                snprintf(name, sizeof(name), "%s / %s", snd_ctl_card_info_get_name(card_info), snd_pcm_info_get_name(pcm_info));
                /* Shared and direct output retain distinct UIDs, but the same
                 * physical PCM must have one display name in both modes. */
                ff_output *active = current_output(pcm);
                if (active) snprintf(name, sizeof(name), "%s", active->name);
                for (int i = 0; i < desktop_count; ++i)
                    if (desktop_sinks[i].card == card && desktop_sinks[i].device == device && desktop_sinks[i].description[0]) {
                        snprintf(name, sizeof(name), "%.*s", FF_NAME_BYTES-1, desktop_sinks[i].description);
                        break;
                    }
                count = append_device(out, capacity, count, pcm, name, 1);
                if (count < 0) { snd_ctl_close(ctl); return -1; }
                /* One canonical mixer route per physical playback PCM. Do not
                 * expose front/surround/resampler aliases as extra devices. */
                snprintf(pcm, sizeof(pcm), "dmix:CARD=%s,DEV=%d", snd_ctl_card_info_get_id(card_info), device);
                int desktop_card = 0;
                for (int i = 0; i < desktop_count; ++i)
                    if (desktop_sinks[i].card == card) desktop_card = 1;
                if (!desktop_card && pcm_available(pcm)) {
                    snprintf(name, sizeof(name), "%s / %s", snd_ctl_card_info_get_name(card_info), snd_pcm_info_get_name(pcm_info));
                    count = append_device(out, capacity, count, pcm, name, 0);
                    if (count < 0) { snd_ctl_close(ctl); return -1; }
                }
            }
        }
        snd_ctl_close(ctl);
    }
    return count;
}
static int enumerate(ff_device_info *out, size_t capacity) {
    if (snd_config_update() < 0) return -1;
    int count = 0;
    const char *route = default_pcm();
    if (pcm_available(route)) {
        count = append_device(out, capacity, count, desktop_pcm[0] ? desktop_pcm : "default", desktop_name[0] ? desktop_name : "System default output", 0);
        if (count > 0) out[count-1].is_default = 1;
        if (count < 0) return -1;
    }
    for (int i = 0; i < desktop_count; ++i) {
        char pcm[FF_UID_BYTES];
        snprintf(pcm, sizeof(pcm), "pulse:DEVICE=%.*s", FF_UID_BYTES-14, desktop_sinks[i].name);
        count = append_device(out, capacity, count, pcm, desktop_sinks[i].description, 0);
        if (count < 0) return -1;
    }
    count = hardware_devices(out, capacity, count);
    if (count < 0) return -1;
    qsort(out, (size_t)count, sizeof(*out), compare_devices);
    return count;
}
static uint64_t config_hash(void) {
    const char *override = getenv("ALSA_CONFIG_PATH");
    const char *home = getenv("HOME");
    char user_path[4096] = {0};
    if (home) snprintf(user_path, sizeof(user_path), "%s/.asoundrc", home);
    const char *paths[] = {override ? override : "/usr/share/alsa/alsa.conf", "/etc/asound.conf", user_path};
    uint64_t hash = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < sizeof(paths) / sizeof(*paths); ++i) {
        struct stat info;
        hash = hash_bytes(hash, paths[i]);
        if (stat(paths[i], &info) == 0) {
            hash ^= (uint64_t)info.st_mtim.tv_sec ^ ((uint64_t)info.st_mtim.tv_nsec << 1);
            hash = (hash ^ (uint64_t)info.st_size ^ (uint64_t)info.st_ino) * UINT64_C(1099511628211);
        }
    }
    return hash;
}
static void poll_devices(void) {
    refresh_desktop_default();
    ff_device_info devices[FF_MAX_DEVICES];
    int count = enumerate(devices, FF_MAX_DEVICES);
    if (count < 0) { atomic_fetch_or(&changes, 3u); return; }
    uint64_t hash = UINT64_C(1469598103934665603);
    for (int i = 0; i < count; ++i) {
        hash = hash_bytes(hash, devices[i].uid);
        hash = hash_bytes(hash, devices[i].name);
    }
    uint64_t config = config_hash();
    uint64_t current_default = hash_bytes(UINT64_C(1469598103934665603), default_pcm());
    if (last_default && last_default != current_default) atomic_fetch_or(&changes, 3u);
    last_default = current_default;
    if (last_devices && last_devices != hash) atomic_fetch_or(&changes, 1u);
    if (last_config && last_config != config) atomic_fetch_or(&changes, 3u);
    last_devices = hash; last_config = config;
}
int ff_context_acquire(void) {
    if (refs) { ++refs; return 0; }
    if (Pa_Initialize() != paNoError) return -1;
    PaAlsa_SetRetriesBusy(0);
    refs = 1; last_devices = last_config = last_default = 0;
    atomic_store(&changes, 0);
    poll_devices();
    clock_gettime(CLOCK_MONOTONIC, &last_poll);
    return 0;
}
void ff_context_release(void) {
    if (refs && --refs == 0) Pa_Terminate();
}
unsigned int ff_output_changes(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = (double)(now.tv_sec - last_poll.tv_sec) + (now.tv_nsec - last_poll.tv_nsec) / 1e9;
    if (refs && elapsed >= .4) { poll_devices(); last_poll = now; }
    return atomic_exchange(&changes, 0);
}
int ff_output_devices(ff_device_info *out, size_t capacity) { return enumerate(out, capacity); }
int ff_output_route_valid(const char *uid) {
    const char *pcm = pcm_name(uid);
    if (!pcm) return 0;
    snd_pcm_t *handle = NULL;
    int result = snd_pcm_open(&handle, pcm, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
    if (handle) snd_pcm_close(handle);
    return result >= 0 || result == -EBUSY;
}
int ff_output_default_uid(char *out, size_t capacity) {
    const char *pcm = desktop_pcm[0] ? desktop_pcm : "default";
    if (capacity < strlen(pcm) + 6 || !ff_output_route_valid(NULL)) return -1;
    snprintf(out, capacity, "alsa:%s", pcm); return 0;
}
static void parameters(const char *pcm, int channels, PaStreamParameters *out, PaAlsaStreamInfo *alsa) {
    memset(out, 0, sizeof(*out));
    PaAlsa_InitializeStreamInfo(alsa);
    alsa->deviceString = pcm;
    out->device = paUseHostApiSpecificDeviceSpecification;
    out->channelCount = channels;
    out->sampleFormat = paFloat32;
    out->suggestedLatency = .02;
    out->hostApiSpecificStreamInfo = alsa;
}
static int supported(const char *pcm, int channels, unsigned int rate) {
    if (!pcm || channels < 1 || channels > 32 || rate < 8000 || rate > 384000) return 0;
    PaStreamParameters output; PaAlsaStreamInfo alsa;
    parameters(pcm, channels, &output, &alsa);
    return Pa_IsFormatSupported(NULL, &output, rate) == paFormatIsSupported;
}
static unsigned int output_channels(const char *uid, unsigned int preferred, int exclusive) {
    const char *pcm = pcm_name(uid);
    if (!pcm || (exclusive && strncmp(pcm, "hw:", 3))) return 0;
    ff_output *current = current_output(pcm);
    if (current && !strncmp(current->pcm, "hw:", 3)) return current->channels;
    snd_pcm_t *handle = NULL;
    if (snd_pcm_open(&handle, pcm, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0) return 0;
    snd_pcm_hw_params_t *params; snd_pcm_hw_params_alloca(&params);
    unsigned int result = 0, maximum = 0;
    if (snd_pcm_hw_params_any(handle, params) >= 0) {
        snd_pcm_hw_params_get_channels_max(params, &maximum);
        const unsigned int choices[] = {preferred, 2, 1, maximum < 32 ? maximum : 32};
        for (size_t i = 0; i < sizeof(choices) / sizeof(*choices); ++i)
            if (choices[i] >= 1 && choices[i] <= 32 && snd_pcm_hw_params_test_channels(handle, params, choices[i]) == 0) {
                result = choices[i]; break;
            }
    }
    snd_pcm_close(handle);
    return result;
}
static unsigned int output_rate(const char *uid, unsigned int preferred, int exclusive) {
    const char *pcm = pcm_name(uid);
    if (exclusive && (!pcm || strncmp(pcm, "hw:", 3))) return 0;
    ff_output *current = current_output(pcm);
    if (current && !strncmp(current->pcm, "hw:", 3)) {
        // Decoder rebuilding may negotiate while our candidate owns the PCM.
        // Do not reopen that PCM to probe it. A different requested rate is
        // checked strictly by the real open after the old stream is released.
        if (exclusive) return preferred >= 8000 && preferred <= 384000 ? preferred : 0;
        return current->rate;
    }
    unsigned int channels = output_channels(uid, 2, exclusive);
    if (!channels) return 0;
    if (exclusive) return supported(pcm, (int)channels, preferred) ? preferred : 0;
    const unsigned int choices[] = {preferred, 48000, 44100, 96000};
    for (size_t i = 0; i < sizeof(choices) / sizeof(*choices); ++i)
        if (supported(pcm, (int)channels, choices[i])) return choices[i];
    return 0;
}
static unsigned int negotiate(const char *uid, unsigned int preferred, int exclusive, int rate) {
    const char *pcm = pcm_name(uid);
    if (!pcm) return 0;
    /* pcm_name can point at desktop_pcm, which a refresh replaces. */
    char route[FF_UID_BYTES]; snprintf(route, sizeof(route), "%s", pcm);
    if (!exclusive || current_output(route))
        return rate ? output_rate(uid, preferred, exclusive) : output_channels(uid, preferred, exclusive);
    ff_desktop_lease *lease = calloc(FF_MAX_DEVICES, sizeof(*lease));
    if (!lease) return 0;
    size_t count = 0;
    if (acquire_desktop(route, lease, &count)) { free(lease); return 0; }
    unsigned int result = rate ? output_rate(uid, preferred, exclusive) : output_channels(uid, preferred, exclusive);
    restore_desktop(lease, count);
    free(lease);
    return result;
}
unsigned int ff_output_channels(const char *uid, unsigned int preferred, int exclusive) {
    return negotiate(uid, preferred, exclusive, 0);
}
unsigned int ff_output_rate(const char *uid, unsigned int preferred, int exclusive) {
    return negotiate(uid, preferred, exclusive, 1);
}
static int render(const void *input, void *buffer, unsigned long frames,
                  const PaStreamCallbackTimeInfo *time, PaStreamCallbackFlags flags, void *user) {
    (void)input; (void)time; (void)flags;
    ff_output *output = user;
    if (buffer) output->render(buffer, (unsigned int)frames, output->user);
    return paContinue;
}
static void finished(void *user) {
    ff_output *output = user;
    if (!atomic_load(&output->stopping)) {
        atomic_store(&output->failed, 1);
        atomic_fetch_or(&changes, 3u);
    }
}
void ff_output_release(ff_output *output) {
    if (!output) return;
    ff_output **slot = &live_outputs;
    while (*slot && *slot != output) slot = &(*slot)->next;
    if (*slot) *slot = output->next;
    atomic_store(&output->stopping, 1);
    if (output->stream) { Pa_AbortStream(output->stream); Pa_CloseStream(output->stream); }
    restore_desktop(output->lease, output->lease_count);
    free(output);
}
static int direct_hardware(const char *pcm) {
    if (!pcm || strncmp(pcm, "hw:", 3)) return 0;
    snd_pcm_t *probe = NULL;
    if (snd_pcm_open(&probe, pcm, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0) return 0;
    int hardware = snd_pcm_type(probe) == SND_PCM_TYPE_HW;
    snd_pcm_close(probe);
    return hardware;
}
int ff_output_start(const char *uid, int exclusive, int rate, int channels, unsigned int period,
                    ff_render_callback callback, void *user, ff_output **out, char *error, size_t size) {
    *out = NULL;
    const char *pcm = pcm_name(uid);
    const char *failure = exclusive ? "outputExclusiveUnavailable" : "outputDeviceUnavailable";
    if (!pcm || (exclusive && strncmp(pcm, "hw:", 3)) || !callback || channels < 1 || channels > 32 || rate < 8000 || rate > 384000) goto fail;
    ff_output *output = calloc(1, sizeof(*output));
    if (!output) { failure = "outputOpenFailed"; goto fail; }
    if (strlen(pcm) + 6 > sizeof(output->uid)) { free(output); goto fail; }
    snprintf(output->pcm, sizeof(output->pcm), "%s", pcm);
    snprintf(output->uid, sizeof(output->uid), "alsa:%s", pcm);
    snprintf(output->name, sizeof(output->name), "%s", pcm);
    output->exclusive = exclusive;
    output->render = callback; output->user = user;
    ff_device_info devices[FF_MAX_DEVICES];
    int device_count = enumerate(devices, FF_MAX_DEVICES);
    for (int i = 0; i < device_count; ++i)
        if (!strcmp(devices[i].uid, output->uid)) {
            snprintf(output->name, sizeof(output->name), "%s", devices[i].name); break;
        }
    /* Resolve the display name before exclusive acquisition removes the
     * desktop sink. Keep it stable for stream info and device polling. */
    if (exclusive && (acquire_desktop(output->pcm, output->lease, &output->lease_count) || !direct_hardware(output->pcm))) {
        ff_output_release(output); goto fail;
    }
    output->rate = (unsigned int)rate; output->channels = (unsigned int)channels;
    output->period = period ? period : 256;
    PaStreamParameters params; PaAlsaStreamInfo alsa;
    parameters(output->pcm, channels, &params, &alsa);
    PaError result = Pa_OpenStream(&output->stream, NULL, &params, rate,
                                  output->period, paClipOff | paDitherOff, render, output);
    if (result != paNoError) { ff_output_release(output); goto fail; }
    const PaStreamInfo *actual = Pa_GetStreamInfo(output->stream);
    if (!actual || (exclusive && actual->sampleRate != rate)) {
        failure = "outputExclusiveUnavailable"; ff_output_release(output); goto fail;
    }
    if (Pa_SetStreamFinishedCallback(output->stream, finished) != paNoError ||
        Pa_StartStream(output->stream) != paNoError) {
        failure = "outputStartFailed"; ff_output_release(output); goto fail;
    }
    output->rate = (unsigned int)actual->sampleRate;
    output->next = live_outputs; live_outputs = output;
    *out = output; return 0;
fail:
    if (size) snprintf(error, size, "%s", failure);
    return -1;
}
int ff_output_get_info(ff_output *output, ff_output_info *info) {
    if (!output || !info) return -1;
    const PaStreamInfo *stream = Pa_GetStreamInfo(output->stream);
    if (!stream) return -1;
    memset(info, 0, sizeof(*info));
    snprintf(info->device_name, sizeof(info->device_name), "%s", output->name);
    snprintf(info->device_uid, sizeof(info->device_uid), "%s", output->uid);
    info->sample_rate = (int)stream->sampleRate;
    info->channels = (int)output->channels; info->internal_format = 1;
    info->period_frames = output->period;
    info->period_seconds = stream->outputLatency;
    info->periods = (unsigned int)(stream->outputLatency * stream->sampleRate / output->period + .5);
    return 0;
}
int ff_output_is_running(ff_output *output) {
    return output && !atomic_load(&output->failed) && Pa_IsStreamActive(output->stream) == 1;
}
int ff_output_hog_owned(ff_output *output) { return output && output->exclusive && !atomic_load(&output->failed); }
void ff_output_pause(ff_output *output) {
    if (!output) return;
    atomic_store(&output->stopping, 1);
    Pa_AbortStream(output->stream);
}
int ff_output_resume(ff_output *output) {
    if (!output || atomic_load(&output->failed)) return -1;
    atomic_store(&output->stopping, 0);
    PaError result = Pa_StartStream(output->stream);
    return result == paNoError || result == paStreamIsNotStopped ? 0 : -1;
}
