/*
 * Phase 1 ABI probe (docs/design/boundaries.md).
 *
 * Compiles against `schemas/media_core.h` only - the same file a platform host
 * uses - and loads the *packaged* `libff_media_core.dylib` through
 * `@executable_path/../Frameworks`, exactly the way the app does. It then drives
 * the byte transport: version, capabilities, handle lifetime, argument
 * validation, a command round trip, a snapshot, the event sink, attach/detach and
 * cancellation-free shutdown.
 *
 * It deliberately plays no audio: the audio path is verified by
 * `media-ffi/examples/play_file` and the ignored session playback test. What this
 * probe proves is that the shipped library loads, exports the documented symbols
 * with the documented behaviour, and can be called from C.
 *
 * Output is one JSON line, `{"probe":"abi","failures":[...]}`; the exit code is
 * zero only when the failure list is empty.
 */

#include "media_core.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define MAX_FAILURES 24
#define SNAPSHOT_BYTES 4096
#define REPLY_BYTES 4096
#define CAPABILITIES_BYTES 8192

static char failures[MAX_FAILURES][256];
static int failure_count = 0;
static int sink_calls = 0;

/* Resolved from the library, like every other entry point: the probe links
 * against nothing, so a missing symbol is a probe failure rather than a link
 * error nobody reads. */
static void (*bytes_free)(ff_owned_bytes_t bytes) = NULL;

/* Twenty milliseconds, the polling step while waiting for the event sink. */
static const struct timespec POLL_STEP = {0, 20000000};

static void fail(const char *message) {
  if (failure_count < MAX_FAILURES) {
    snprintf(failures[failure_count], sizeof(failures[failure_count]), "%s", message);
    failure_count++;
  }
}

/* Reports a result code that the contract says must be zero. */
static void expect_ok(const char *what, uint32_t code) {
  if (code != FF_MEDIA_OK) {
    char message[256];
    snprintf(message, sizeof(message), "%s returned code %u", what, code);
    fail(message);
  }
}

static void expect_code(const char *what, uint32_t code, uint32_t expected) {
  if (code != expected) {
    char message[256];
    snprintf(message, sizeof(message), "%s returned code %u, expected %u", what, code, expected);
    fail(message);
  }
}

/* Copies an owned buffer into `out` and releases it. */
static int take(ff_owned_bytes_t bytes, char *out, size_t capacity, const char *what) {
  if (bytes.data == NULL || bytes.len == 0) {
    char message[256];
    snprintf(message, sizeof(message), "%s returned an empty buffer", what);
    fail(message);
    return 0;
  }
  size_t copy = bytes.len < capacity - 1 ? bytes.len : capacity - 1;
  memcpy(out, bytes.data, copy);
  out[copy] = '\0';
  if (bytes_free != NULL) {
    bytes_free(bytes);
  }
  return 1;
}

/* Whether `haystack` contains `needle`. */
static int contains(const char *haystack, const char *needle) {
  return strstr(haystack, needle) != NULL;
}

/* Extracts a JSON string field without a JSON parser; the probe only reads ids. */
static int field(const char *json, const char *key, char *out, size_t capacity) {
  char pattern[64];
  snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
  const char *start = strstr(json, pattern);
  if (start == NULL) {
    return 0;
  }
  start += strlen(pattern);
  const char *end = strchr(start, '"');
  if (end == NULL) {
    return 0;
  }
  size_t length = (size_t)(end - start);
  if (length >= capacity) {
    length = capacity - 1;
  }
  memcpy(out, start, length);
  out[length] = '\0';
  return 1;
}

/*
 * The sink owns every event buffer it receives and releases it with
 * ff_owned_bytes_free; `user` is unused here.
 */
static void on_event(uint8_t *json, size_t len, void *user) {
  (void)user;
  if (json != NULL && len > 0) {
    sink_calls++;
  }
  if (bytes_free != NULL) {
    ff_owned_bytes_t event = {json, len};
    bytes_free(event);
  }
}

int main(void) {
  void *handle = dlopen("@rpath/libff_media_core.dylib", RTLD_NOW | RTLD_LOCAL);
  if (handle == NULL) {
    handle = dlopen("@executable_path/../Frameworks/libff_media_core.dylib", RTLD_NOW | RTLD_LOCAL);
  }
  if (handle == NULL) {
    printf("{\"probe\":\"abi\",\"failures\":[\"dlopen: %s\"]}\n", dlerror());
    return 1;
  }

  bytes_free = (void (*)(ff_owned_bytes_t))dlsym(handle, "ff_owned_bytes_free");
  uint32_t (*abi_version)(void) = (uint32_t(*)(void))dlsym(handle, "ff_media_core_abi_version");
  ff_owned_bytes_t (*capabilities)(void) =
      (ff_owned_bytes_t(*)(void))dlsym(handle, "ff_media_core_capabilities_json");
  ff_player_t *(*player_new)(void) = (ff_player_t * (*)(void)) dlsym(handle, "ff_player_new");
  void (*player_free)(ff_player_t *) = (void (*)(ff_player_t *))dlsym(handle, "ff_player_free");
  uint32_t (*set_event_sink)(ff_player_t *, ff_event_sink_t, void *) =
      (uint32_t(*)(ff_player_t *, ff_event_sink_t, void *))dlsym(handle, "ff_player_set_event_sink");
  uint32_t (*player_state)(const ff_player_t *) =
      (uint32_t(*)(const ff_player_t *))dlsym(handle, "ff_player_state");
  uint32_t (*attach)(ff_player_t *, const uint8_t *, size_t, ff_owned_bytes_t *) =
      (uint32_t(*)(ff_player_t *, const uint8_t *, size_t, ff_owned_bytes_t *))
          dlsym(handle, "ff_player_attach");
  uint32_t (*detach)(ff_player_t *, const uint8_t *, size_t) =
      (uint32_t(*)(ff_player_t *, const uint8_t *, size_t))dlsym(handle, "ff_player_detach");
  uint32_t (*snapshot)(ff_player_t *, ff_owned_bytes_t *) =
      (uint32_t(*)(ff_player_t *, ff_owned_bytes_t *))dlsym(handle, "ff_player_snapshot");
  uint32_t (*diagnostics)(ff_player_t *, ff_owned_bytes_t *) =
      (uint32_t(*)(ff_player_t *, ff_owned_bytes_t *))dlsym(handle, "ff_player_diagnostics");
  uint32_t (*execute)(ff_player_t *, const uint8_t *, size_t, uint32_t, ff_owned_bytes_t *) =
      (uint32_t(*)(ff_player_t *, const uint8_t *, size_t, uint32_t, ff_owned_bytes_t *))
          dlsym(handle, "ff_player_execute");

  if (bytes_free == NULL || abi_version == NULL || capabilities == NULL || player_new == NULL ||
      player_free == NULL || set_event_sink == NULL || player_state == NULL || attach == NULL ||
      detach == NULL || snapshot == NULL || diagnostics == NULL || execute == NULL) {
    printf("{\"probe\":\"abi\",\"failures\":[\"a documented symbol is missing from the library\"]}\n");
    dlclose(handle);
    return 1;
  }

  char buffer[CAPABILITIES_BYTES];
  if (abi_version() != FF_MEDIA_CORE_ABI_VERSION) {
    fail("ff_media_core_abi_version does not match FF_MEDIA_CORE_ABI_VERSION");
  }
  if (take(capabilities(), buffer, sizeof(buffer), "capabilities")) {
    if (!contains(buffer, "\"controlTransport\":\"bytes+json\"")) {
      fail("capabilities do not announce the byte transport");
    }
    if (!contains(buffer, "\"abiVersion\":3")) {
      fail("capabilities do not announce abiVersion 3");
    }
  }

  ff_player_t *player = player_new();
  if (player == NULL) {
    fail("ff_player_new returned NULL");
    printf("{\"probe\":\"abi\",\"failures\":[\"ff_player_new returned NULL\"]}\n");
    dlclose(handle);
    return 1;
  }
  if (player_state(player) != FF_PLAYBACK_IDLE) {
    fail("a fresh player is not idle");
  }

  /* Argument validation: the codes the header documents, not a crash. A failed
   * call must leave the out-parameter untouched, so it is zeroed up front. */
  ff_owned_bytes_t out = {0};
  expect_code("execute(NULL json)", execute(player, NULL, 0, 0, &out), FF_MEDIA_ERR_INVALID_ARGUMENT);
  const uint8_t garbage[] = {0xff, 0xfe};
  expect_code("execute(non-UTF-8)", execute(player, garbage, sizeof(garbage), 0, &out),
              FF_MEDIA_ERR_INVALID_ARGUMENT);
  const uint8_t not_object[] = "[1,2,3]";
  expect_code("execute(non-object)", execute(player, not_object, sizeof(not_object) - 1, 0, &out),
              FF_MEDIA_ERR_MALFORMED_MESSAGE);
  expect_code("execute(NULL player)", execute(NULL, not_object, sizeof(not_object) - 1, 0, &out),
              FF_MEDIA_ERR_NULL_HANDLE);

  /* The session id comes from the snapshot: a host learns it by attaching. */
  expect_ok("snapshot", snapshot(player, &out));
  char baseline[SNAPSHOT_BYTES];
  char session_id[128];
  if (take(out, baseline, sizeof(baseline), "snapshot")) {
    if (!contains(baseline, "\"kind\":\"snapshot\"")) {
      fail("the snapshot is not a snapshot message");
    }
    if (!field(baseline, "sessionId", session_id, sizeof(session_id))) {
      fail("the snapshot has no sessionId");
      session_id[0] = '\0';
    }
    const char *required[] = {"schemaVersion", "sessionRevision", "queueRevision", "generation",
                              "phase",          "playWhenReady",   "buffering",      "suppressionReasons",
                              "isActuallyPlaying", "currentQueueItemId", "positionMs"};
    for (size_t index = 0; index < sizeof(required) / sizeof(required[0]); index++) {
      char pattern[64];
      snprintf(pattern, sizeof(pattern), "\"%s\"", required[index]);
      if (!contains(baseline, pattern)) {
        fail("the snapshot is missing a schema-required field");
      }
    }
  }

  /* A command round trip: accepted on an empty queue, rejected for play. */
  char command[512];
  snprintf(command, sizeof(command),
           "{\"schemaVersion\":1,\"kind\":\"pause\",\"clientId\":\"abi-probe\","
           "\"commandId\":\"cmd-1\",\"targetSessionId\":\"%s\",\"payload\":{}}",
           session_id);
  expect_ok("execute(pause)", execute(player, (const uint8_t *)command, strlen(command), 1000, &out));
  char reply[REPLY_BYTES];
  if (take(out, reply, sizeof(reply), "pause reply")) {
    if (!contains(reply, "\"status\":\"accepted\"")) {
      fail("a pause on an idle session was not accepted");
    }
  }

  snprintf(command, sizeof(command),
           "{\"schemaVersion\":1,\"kind\":\"play\",\"clientId\":\"abi-probe\","
           "\"commandId\":\"cmd-2\",\"targetSessionId\":\"%s\",\"payload\":{}}",
           session_id);
  expect_ok("execute(play)", execute(player, (const uint8_t *)command, strlen(command), 1000, &out));
  if (take(out, reply, sizeof(reply), "play reply")) {
    if (!contains(reply, "\"status\":\"rejected\"") || !contains(reply, "\"errorCode\":\"emptyQueue\"")) {
      fail("play on an empty queue must be rejected with emptyQueue");
    }
  }

  /* The event sink must be reachable and must carry real payloads. */
  expect_ok("set_event_sink", set_event_sink(player, on_event, NULL));
  snprintf(command, sizeof(command),
           "{\"schemaVersion\":1,\"kind\":\"stop\",\"clientId\":\"abi-probe\","
           "\"commandId\":\"cmd-3\",\"targetSessionId\":\"%s\",\"payload\":{}}",
           session_id);
  expect_ok("execute(stop)", execute(player, (const uint8_t *)command, strlen(command), 1000, &out));
  if (out.data != NULL) {
    bytes_free(out);
  }
  for (int waited = 0; waited < 2000 && sink_calls == 0; waited += 20) {
    nanosleep(&POLL_STEP, NULL);
  }
  if (sink_calls == 0) {
    fail("the event sink never received a snapshot");
  }
  expect_ok("set_event_sink(clear)", set_event_sink(player, NULL, NULL));

  /* Subscriptions: attach returns a connection id and a baseline, detach is
   * idempotent. */
  const char *client_id = "abi-probe";
  expect_ok("attach", attach(player, (const uint8_t *)client_id, strlen(client_id), &out));
  char connection_id[64] = "";
  if (take(out, reply, sizeof(reply), "attachment")) {
    if (!field(reply, "connectionId", connection_id, sizeof(connection_id))) {
      fail("attach returned no connectionId");
    }
    if (!contains(reply, "\"baseline\"")) {
      fail("attach returned no baseline");
    }
  }
  if (connection_id[0] != '\0') {
    expect_ok("detach", detach(player, (const uint8_t *)connection_id, strlen(connection_id)));
  }
  const char *unknown = "conn-4242";
  expect_ok("detach(unknown)", detach(player, (const uint8_t *)unknown, strlen(unknown)));

  /* Diagnostics are payload-free (docs/design/diagnostics.md). */
  expect_ok("diagnostics", diagnostics(player, &out));
  if (take(out, buffer, sizeof(buffer), "diagnostics")) {
    const char *forbidden[] = {"file://", "http://", "https://", "/Users/", "/var/", "/tmp/"};
    for (size_t index = 0; index < sizeof(forbidden) / sizeof(forbidden[0]); index++) {
      if (contains(buffer, forbidden[index])) {
        fail("diagnostics carry a path or URL");
      }
    }
  }

  player_free(player);
  dlclose(handle);

  printf("{\"probe\":\"abi\",\"failures\":[");
  for (int index = 0; index < failure_count; index++) {
    printf("%s\"%s\"", index == 0 ? "" : ",", failures[index]);
  }
  printf("],\"sinkCalls\":%d}\n", sink_calls);
  return failure_count == 0 ? 0 : 1;
}
