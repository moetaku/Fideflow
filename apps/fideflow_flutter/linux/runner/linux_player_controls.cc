#include "linux_player_controls.h"

#include <gio/gio.h>
#include <glib/gstdio.h>
#include "linux_global_shortcuts.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <unistd.h>

namespace {
constexpr char kPath[] = "/org/mpris/MediaPlayer2";
constexpr char kPlayerInterface[] = "org.mpris.MediaPlayer2.Player";
constexpr char kRootInterface[] = "org.mpris.MediaPlayer2";
const char kXml[] =
    "<node>"
    "<interface name='org.mpris.MediaPlayer2'>"
    "<method name='Raise'/><method name='Quit'/>"
    "<property name='CanQuit' type='b' access='read'/>"
    "<property name='CanRaise' type='b' access='read'/>"
    "<property name='HasTrackList' type='b' access='read'/>"
    "<property name='Identity' type='s' access='read'/>"
    "<property name='DesktopEntry' type='s' access='read'/>"
    "<property name='SupportedUriSchemes' type='as' access='read'/>"
    "<property name='SupportedMimeTypes' type='as' access='read'/>"
    "</interface>"
    "<interface name='org.mpris.MediaPlayer2.Player'>"
    "<method name='Next'/><method name='Previous'/><method name='Pause'/>"
    "<method name='PlayPause'/><method name='Stop'/><method name='Play'/>"
    "<method name='Seek'><arg direction='in' name='Offset' type='x'/></method>"
    "<method name='SetPosition'><arg direction='in' name='TrackId' type='o'/>"
    "<arg direction='in' name='Position' type='x'/></method>"
    "<method name='OpenUri'><arg direction='in' name='Uri' type='s'/></method>"
    "<signal name='Seeked'><arg name='Position' type='x'/></signal>"
    "<property name='PlaybackStatus' type='s' access='read'/>"
    "<property name='LoopStatus' type='s' access='readwrite'/>"
    "<property name='Rate' type='d' access='readwrite'/>"
    "<property name='Shuffle' type='b' access='readwrite'/>"
    "<property name='Metadata' type='a{sv}' access='read'/>"
    "<property name='Volume' type='d' access='readwrite'/>"
    "<property name='Position' type='x' access='read'/>"
    "<property name='MinimumRate' type='d' access='read'/>"
    "<property name='MaximumRate' type='d' access='read'/>"
    "<property name='CanGoNext' type='b' access='read'/>"
    "<property name='CanGoPrevious' type='b' access='read'/>"
    "<property name='CanPlay' type='b' access='read'/>"
    "<property name='CanPause' type='b' access='read'/>"
    "<property name='CanSeek' type='b' access='read'/>"
    "<property name='CanControl' type='b' access='read'/>"
    "</interface></node>";

struct ActionReply {
  GDBusMethodInvocation* invocation;
  std::function<void(bool)> on_complete;
};

void ActionFinished(GObject* object, GAsyncResult* result, gpointer data) {
  auto* reply = static_cast<ActionReply*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  FlValue* value = response != nullptr && FL_IS_METHOD_SUCCESS_RESPONSE(response)
      ? fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response))
      : nullptr;
  const bool ok = value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
                  fl_value_get_bool(value);
  if (reply->on_complete) reply->on_complete(ok);
  if (ok) g_dbus_method_invocation_return_value(reply->invocation, nullptr);
  else g_dbus_method_invocation_return_error_literal(
      reply->invocation, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
      "Playback action was rejected");
  g_object_unref(reply->invocation);
  delete reply;
}

}  // namespace

struct LinuxPlayerControls::Impl {
  struct CallbackState { Impl* owner = nullptr; };
  GtkApplication* application;
  GtkWindow* window;
  FlView* view;
  FlMethodChannel* channel = nullptr;
  GDBusConnection* bus = nullptr;
  GDBusNodeInfo* node = nullptr;
  guint registration = 0;
  guint owner_id = 0;
  guint player_registration_ = 0;
  bool ready = false, enabled = true, has_track = false, playing = false;
  bool can_seek = false, suspended = false;
  double duration = 0, position = 0;
  std::string title, artist, album, token, art_uri;
  std::string art_path;
  std::string status = "Stopped", loop_status = "None";
  double volume = 0;
  bool shuffle = false;
  bool have_timeline_sample = false, last_sample_playing = false;
  double last_sample_position = 0;
  gint64 last_sample_time = 0;
  std::string last_sample_token;
  guint64 next_seek_request = 0, pending_seek_request = 0, last_seeked_request = 0;
  double pending_seek_target = 0;
  bool pending_seek_emitted = false;
  GVariant* last_metadata = nullptr;
  std::string last_status, last_loop_status;
  double last_volume = -1;
  bool last_shuffle = false, last_has_track = false, last_can_seek = false;
  bool last_enabled = false, last_can_quit = false;
  std::unique_ptr<LinuxGlobalShortcuts> shortcuts;
  std::function<void()> quit_handler;
  std::shared_ptr<CallbackState> callback_state = std::make_shared<CallbackState>();

  Impl(GtkApplication* app, GtkWindow* win, FlView* flutter_view)
      : application(GTK_APPLICATION(g_object_ref(app))),
        window(GTK_WINDOW(g_object_ref(win))), view(FL_VIEW(g_object_ref(flutter_view))) {
    callback_state->owner = this;
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        "fideflow/player_controls", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel, MethodCall, this, nullptr);
    shortcuts = std::make_unique<LinuxGlobalShortcuts>(window,
        [this](const std::string& action) {
          g_autoptr(FlValue) args = fl_value_new_map();
          fl_value_set_string_take(args, "action", fl_value_new_string(action.c_str()));
          fl_method_channel_invoke_method(channel, "action", args, nullptr, nullptr, nullptr);
        },
        [this](const std::string& error) {
          g_autoptr(FlValue) value = fl_value_new_string(error.c_str());
          fl_method_channel_invoke_method(channel, "hotkeyError", value, nullptr, nullptr, nullptr);
        });
    node = g_dbus_node_info_new_for_xml(kXml, nullptr);
    g_autoptr(GError) error = nullptr;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (bus != nullptr && node != nullptr) {
      const GDBusInterfaceVTable vtable = {MethodCallDbus, GetProperty, SetProperty, {0}};
      registration = g_dbus_connection_register_object(
          bus, kPath, node->interfaces[0], &vtable, this, nullptr, &error);
      if (registration != 0) {
        const guint player_registration = g_dbus_connection_register_object(
            bus, kPath, node->interfaces[1], &vtable, this, nullptr, &error);
        if (player_registration == 0) {
          g_dbus_connection_unregister_object(bus, registration);
          registration = 0;
        } else {
          // Both registrations are removed through the connection close below.
          player_registration_ = player_registration;
          const std::string name = "org.mpris.MediaPlayer2.fideflow";
          owner_id = g_bus_own_name_on_connection(bus, name.c_str(),
              G_BUS_NAME_OWNER_FLAGS_NONE, nullptr, nullptr, nullptr, nullptr);
        }
      }
    }
  }

  ~Impl() {
    callback_state->owner = nullptr;
    ready = false;
    StopMpris();
    if (shortcuts) shortcuts->Dispose();
    if (channel) {
      fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
      g_clear_object(&channel);
    }
    if (!art_path.empty()) g_unlink(art_path.c_str());
    if (node) g_dbus_node_info_unref(node);
    if (last_metadata) g_variant_unref(last_metadata);
    g_clear_object(&bus); g_clear_object(&view); g_clear_object(&window); g_clear_object(&application);
  }

  void StopMpris() {
    if (owner_id) { g_bus_unown_name(owner_id); owner_id = 0; }
    if (bus && registration) { g_dbus_connection_unregister_object(bus, registration); registration = 0; }
    if (bus && player_registration_) { g_dbus_connection_unregister_object(bus, player_registration_); player_registration_ = 0; }
  }

  static void MethodCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
    auto* self = static_cast<Impl*>(data);
    const char* method = fl_method_call_get_name(call);
    FlValue* args = fl_method_call_get_args(call);
    if (g_strcmp0(method, "configure") == 0 && args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* media = fl_value_lookup_string(args, "mediaEnabled");
      self->enabled = !media || fl_value_get_bool(media);
      if (!self->enabled) self->Clear();
      std::weak_ptr<CallbackState> weak_state = self->callback_state;
      self->shortcuts->Configure(args, [weak_state, held = FL_METHOD_CALL(g_object_ref(call))](std::map<std::string, std::string> failures) {
        auto state = weak_state.lock();
        Impl* owner = state ? state->owner : nullptr;
        g_autoptr(FlValue) result = fl_value_new_map();
        for (const auto& failure : failures) {
          fl_value_set_string_take(result, failure.first.c_str(),
                                   fl_value_new_string(failure.second.c_str()));
        }
        fl_method_call_respond_success(held, result, nullptr);
        g_object_unref(held);
        if (owner) { owner->ready = true; owner->PropertiesChanged(); }
      });
    } else if (g_strcmp0(method, "suspend") == 0) {
      self->suspended = args && fl_value_get_bool(args);
      self->shortcuts->Suspend(self->suspended);
      fl_method_call_respond_success(call, nullptr, nullptr);
    } else if (g_strcmp0(method, "publish") == 0 && args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      self->Publish(args);
      fl_method_call_respond_success(call, nullptr, nullptr);
    } else if (g_strcmp0(method, "artwork") == 0 && args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      self->Artwork(args);
      fl_method_call_respond_success(call, nullptr, nullptr);
    } else if (g_strcmp0(method, "dispose") == 0) {
      self->ready = false;
      self->shortcuts->Dispose();
      self->Clear();
      self->StopMpris();
      fl_method_call_respond_success(call, nullptr, nullptr);
    } else {
      fl_method_call_respond_not_implemented(call, nullptr);
    }
  }

  static GVariant* GetProperty(GDBusConnection*, const gchar*, const gchar*, const gchar* interface,
      const gchar* property, GError**, gpointer data) {
    auto* s = static_cast<Impl*>(data);
    if (g_str_equal(interface, kRootInterface)) {
      if (g_str_equal(property, "CanQuit")) return g_variant_new_boolean(s->ready && static_cast<bool>(s->quit_handler));
      if (g_str_equal(property, "CanRaise")) return g_variant_new_boolean(TRUE);
      if (g_str_equal(property, "HasTrackList")) return g_variant_new_boolean(FALSE);
      if (g_str_equal(property, "Identity")) return g_variant_new_string("Fideflow");
      if (g_str_equal(property, "DesktopEntry")) return g_variant_new_string("fideflow");
      if (g_str_equal(property, "SupportedUriSchemes")) return g_variant_new_strv(nullptr, 0);
      if (g_str_equal(property, "SupportedMimeTypes")) return g_variant_new_strv(nullptr, 0);
    }
    if (g_str_equal(interface, kPlayerInterface)) {
      if (g_str_equal(property, "PlaybackStatus")) return g_variant_new_string(s->status.c_str());
      if (g_str_equal(property, "LoopStatus")) return g_variant_new_string(s->loop_status.c_str());
      if (g_str_equal(property, "Rate") || g_str_equal(property, "MinimumRate") || g_str_equal(property, "MaximumRate")) return g_variant_new_double(1.0);
      if (g_str_equal(property, "Shuffle")) return g_variant_new_boolean(s->shuffle);
      if (g_str_equal(property, "Volume")) return g_variant_new_double(s->volume);
      if (g_str_equal(property, "Position")) return g_variant_new_int64(static_cast<gint64>(s->position * 1000000.0));
      if (g_str_equal(property, "CanControl")) return g_variant_new_boolean(TRUE);
      if (g_str_equal(property, "CanGoNext") || g_str_equal(property, "CanGoPrevious") || g_str_equal(property, "CanPlay") || g_str_equal(property, "CanPause")) return g_variant_new_boolean(s->enabled && s->has_track);
      if (g_str_equal(property, "CanSeek")) return g_variant_new_boolean(s->enabled && s->has_track && s->can_seek);
      if (g_str_equal(property, "Metadata")) return s->Metadata();
    }
    return nullptr;
  }

  static gboolean SetProperty(GDBusConnection*, const gchar*, const gchar*, const gchar* interface, const gchar* property, GVariant* value, GError** error, gpointer data) {
    auto* s = static_cast<Impl*>(data);
    if (!g_str_equal(interface, kPlayerInterface) || !s->ready || !s->enabled) {
      g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_FAILED, "Player controls are unavailable");
      return FALSE;
    }
    if (g_str_equal(property, "LoopStatus") && g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
      const char* status = g_variant_get_string(value, nullptr);
      const double encoded = g_str_equal(status, "None") ? 0 : g_str_equal(status, "Track") ? 1 : g_str_equal(status, "Playlist") ? 2 : -1;
      if (encoded < 0) { g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Invalid LoopStatus"); return FALSE; }
      s->InvokeAction("setLoopStatus", encoded); return TRUE;
    }
    if (g_str_equal(property, "Rate") && g_variant_is_of_type(value, G_VARIANT_TYPE_DOUBLE)) {
      const double rate = g_variant_get_double(value);
      if (!std::isfinite(rate) || (rate != 1.0 && rate != 0.0)) { g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Only normal playback rate is supported"); return FALSE; }
      if (rate == 0.0) s->InvokeAction("pause");
      return TRUE;
    }
    if (g_str_equal(property, "Shuffle") && g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)) {
      s->InvokeAction("setShuffle", g_variant_get_boolean(value) ? 1 : 0); return TRUE;
    }
    if (g_str_equal(property, "Volume") && g_variant_is_of_type(value, G_VARIANT_TYPE_DOUBLE)) {
      const double volume = g_variant_get_double(value);
      if (!std::isfinite(volume)) { g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Volume must be finite"); return FALSE; }
      s->InvokeAction("setVolume", std::max(0.0, std::min(volume, 1.0))); return TRUE;
    }
    g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_PROPERTY_READ_ONLY, "Property is read-only");
    return FALSE;
  }

  GVariant* Metadata() const {
    GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    if (has_track) {
      gchar* hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, token.c_str(), -1);
      const std::string id = std::string("/com/moetaku/fideflow/track/t") + (hash ? hash : "current");
      g_free(hash);
      g_variant_builder_add(&b, "{sv}", "mpris:trackid", g_variant_new_object_path(id.c_str()));
      g_variant_builder_add(&b, "{sv}", "xesam:title", g_variant_new_string(title.c_str()));
      const char* artists[] = {artist.c_str(), nullptr};
      g_variant_builder_add(&b, "{sv}", "xesam:artist", g_variant_new_strv(artists, 1));
      g_variant_builder_add(&b, "{sv}", "xesam:album", g_variant_new_string(album.c_str()));
      g_variant_builder_add(&b, "{sv}", "mpris:length", g_variant_new_int64(static_cast<gint64>(duration * 1000000.0)));
      if (!art_uri.empty()) g_variant_builder_add(&b, "{sv}", "mpris:artUrl", g_variant_new_string(art_uri.c_str()));
    } else {
      g_variant_builder_add(&b, "{sv}", "mpris:trackid",
                            g_variant_new_object_path("/org/mpris/MediaPlayer2/TrackList/NoTrack"));
    }
    return g_variant_builder_end(&b);
  }

  void PropertiesChanged() {
    if (!bus || !registration) return;
    GVariantBuilder changed, invalidated; g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}")); g_variant_builder_init(&invalidated, G_VARIANT_TYPE("as"));
    bool changed_any = false;
    if (last_status != status) { g_variant_builder_add(&changed, "{sv}", "PlaybackStatus", g_variant_new_string(status.c_str())); last_status = status; changed_any = true; }
    GVariant* metadata = g_variant_ref_sink(Metadata());
    if (!last_metadata || !g_variant_equal(last_metadata, metadata)) {
      g_variant_builder_add(&changed, "{sv}", "Metadata", metadata);
      if (last_metadata) g_variant_unref(last_metadata);
      last_metadata = g_variant_ref(metadata);
      changed_any = true;
    }
    g_variant_unref(metadata);
    if (last_loop_status != loop_status) { g_variant_builder_add(&changed, "{sv}", "LoopStatus", g_variant_new_string(loop_status.c_str())); last_loop_status = loop_status; changed_any = true; }
    if (last_shuffle != shuffle) { g_variant_builder_add(&changed, "{sv}", "Shuffle", g_variant_new_boolean(shuffle)); last_shuffle = shuffle; changed_any = true; }
    if (last_volume != volume) { g_variant_builder_add(&changed, "{sv}", "Volume", g_variant_new_double(volume)); last_volume = volume; changed_any = true; }
    const char* signals[] = {"CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek"};
    const bool capabilities_changed = last_has_track != has_track || last_can_seek != can_seek || last_enabled != enabled;
    if (capabilities_changed) {
      for (auto* name : signals) g_variant_builder_add(&changed, "{sv}", name, g_variant_new_boolean(enabled && has_track && (!g_str_equal(name, "CanSeek") || can_seek)));
      last_has_track = has_track; last_can_seek = can_seek; last_enabled = enabled; changed_any = true;
    }
    if (changed_any) g_dbus_connection_emit_signal(bus, nullptr, kPath, "org.freedesktop.DBus.Properties", "PropertiesChanged",
      g_variant_new("(s@a{sv}@as)", kPlayerInterface, g_variant_builder_end(&changed), g_variant_builder_end(&invalidated)), nullptr);
    else { g_variant_builder_clear(&changed); g_variant_builder_clear(&invalidated); }
    const bool can_quit = ready && static_cast<bool>(quit_handler);
    if (can_quit != last_can_quit) {
      GVariantBuilder root_changed, root_invalidated;
      g_variant_builder_init(&root_changed, G_VARIANT_TYPE("a{sv}"));
      g_variant_builder_init(&root_invalidated, G_VARIANT_TYPE("as"));
      g_variant_builder_add(&root_changed, "{sv}", "CanQuit", g_variant_new_boolean(can_quit));
      g_dbus_connection_emit_signal(bus, nullptr, kPath, "org.freedesktop.DBus.Properties", "PropertiesChanged",
        g_variant_new("(s@a{sv}@as)", kRootInterface, g_variant_builder_end(&root_changed), g_variant_builder_end(&root_invalidated)), nullptr);
      last_can_quit = can_quit;
    }
  }

  void Clear() { has_track = playing = can_seek = false; have_timeline_sample = false; status = "Stopped"; title.clear(); artist.clear(); album.clear(); art_uri.clear(); if (!art_path.empty()) { g_unlink(art_path.c_str()); art_path.clear(); } position = duration = 0; PropertiesChanged(); }

  void Publish(FlValue* map) {
    FlValue* get = nullptr;
#define VALUE(key) (get = fl_value_lookup_string(map, key))
    FlValue* enabled_value = VALUE("hasTrack"); has_track = enabled && enabled_value && fl_value_get_bool(enabled_value);
    FlValue* v = VALUE("playing"); playing = has_track && v && fl_value_get_bool(v);
    v = VALUE("status");
    const std::string status_value = v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING ? fl_value_get_string(v) : "";
    status = !has_track || status_value == "stopped" || status_value == "idle"
                 ? "Stopped" : playing ? "Playing" : "Paused";
    v = VALUE("canSeek"); can_seek = has_track && v && fl_value_get_bool(v);
    auto number = [&](const char* key) { FlValue* n = VALUE(key); return n && fl_value_get_type(n) == FL_VALUE_TYPE_FLOAT ? fl_value_get_float(n) : n && fl_value_get_type(n) == FL_VALUE_TYPE_INT ? static_cast<double>(fl_value_get_int(n)) : 0.0; };
    duration = std::max(0.0, std::min(number("duration"), 1e10));
    position = std::max(0.0, std::min(number("position"), duration));
    volume = std::max(0.0, std::min(number("volume"), 1.0));
    auto string = [&](const char* key) { FlValue* x = VALUE(key); return x && fl_value_get_type(x) == FL_VALUE_TYPE_STRING ? std::string(fl_value_get_string(x)) : std::string(); };
    title = string("title"); artist = string("artist"); album = string("album"); loop_status = string("loopStatus");
    v = VALUE("shuffle"); shuffle = v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(v);
    const std::string next_token = string("token");
    if (next_token != token) pending_seek_request = 0;
    if (next_token != token && !art_path.empty()) {
      g_unlink(art_path.c_str()); art_path.clear(); art_uri.clear();
    }
    token = next_token;
    if (!has_track) { title.clear(); artist.clear(); album.clear(); art_uri.clear(); if (!art_path.empty()) { g_unlink(art_path.c_str()); art_path.clear(); } }
    const gint64 now = g_get_monotonic_time();
    const bool same_track = has_track && have_timeline_sample && token == last_sample_token;
    bool discontinuity = false;
    if (same_track) {
      const double elapsed = std::max<gint64>(0, now - last_sample_time) / 1000000.0;
      const double expected = std::min(duration, last_sample_position + (last_sample_playing ? elapsed : 0.0));
      discontinuity = std::abs(position - expected) > 0.25;
    }
    const bool pending_match = same_track && pending_seek_request != 0 &&
        std::abs(position - pending_seek_target) <= 0.75;
    if (pending_match || discontinuity) {
      if (!pending_seek_emitted) EmitSeeked(position);
      if (pending_seek_request != 0) {
        last_seeked_request = pending_seek_request;
        pending_seek_request = 0;
        pending_seek_emitted = false;
      }
    }
    have_timeline_sample = has_track;
    last_sample_token = token;
    last_sample_position = position;
    last_sample_time = now;
    last_sample_playing = playing;
    PropertiesChanged();
#undef VALUE
  }

  void Artwork(FlValue* map) {
    FlValue* t = fl_value_lookup_string(map, "token"); FlValue* bytes = fl_value_lookup_string(map, "bytes");
    if (!enabled || !has_track || !t || !bytes || fl_value_get_type(t) != FL_VALUE_TYPE_STRING || fl_value_get_type(bytes) != FL_VALUE_TYPE_UINT8_LIST || std::string(fl_value_get_string(t)) != token) return;
    const uint8_t* data = fl_value_get_uint8_list(bytes); const size_t size = fl_value_get_length(bytes);
    gchar* path = nullptr; gint fd = g_file_open_tmp("fideflow-mpris-XXXXXX", &path, nullptr);
    if (fd < 0) return;
    close(fd);
    if (!g_file_set_contents(path, reinterpret_cast<const gchar*>(data), size, nullptr)) { g_unlink(path); g_free(path); return; }
    if (!art_path.empty()) g_unlink(art_path.c_str());
    art_path = path;
    gchar* uri = g_filename_to_uri(path, nullptr, nullptr);
    art_uri = uri ? uri : "";
    g_free(uri);
    PropertiesChanged();
    g_free(path);
  }

  void InvokeAction(const char* action, double position_value = -1) {
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "action", fl_value_new_string(action));
    if (position_value >= 0) fl_value_set_string_take(args, "position", fl_value_new_float(position_value));
    fl_method_channel_invoke_method(channel, "action", args, nullptr, nullptr, nullptr);
  }

  void EmitSeeked(double target) {
    if (bus && player_registration_) g_dbus_connection_emit_signal(
        bus, nullptr, kPath, kPlayerInterface, "Seeked",
        g_variant_new("(x)", static_cast<gint64>(target * 1000000.0)), nullptr);
  }

  void CompleteSeekRequest(guint64 request, double target, bool accepted) {
    if (request == 0) return;
    if (!accepted) {
      if (pending_seek_request == request) pending_seek_request = 0;
      return;
    }
    if (last_seeked_request == request) return;
    EmitSeeked(target);
    last_seeked_request = request;
    if (pending_seek_request == request) pending_seek_emitted = true;
  }

  void Dispatch(GDBusMethodInvocation* invocation, const char* action, double position_value = -1) {
    if (g_str_equal(action, "raise")) { gtk_window_present(window); g_dbus_method_invocation_return_value(invocation, nullptr); return; }
    if (g_str_equal(action, "quit")) {
      if (!ready || !quit_handler) { g_dbus_method_invocation_return_error_literal(invocation, G_DBUS_ERROR, G_DBUS_ERROR_FAILED, "Quit is unavailable"); return; }
      quit_handler(); g_dbus_method_invocation_return_value(invocation, nullptr); return;
    }
    if (!ready || !enabled || !has_track) {
      g_dbus_method_invocation_return_error_literal(invocation, G_DBUS_ERROR, G_DBUS_ERROR_FAILED, "Player action is unavailable"); return;
    }
    if (g_str_equal(action, "seek") && !can_seek) { g_dbus_method_invocation_return_value(invocation, nullptr); return; }
    if (g_str_equal(action, "seek") && position_value > duration) {
      Dispatch(invocation, "next"); return;
    }
    if (g_str_equal(action, "seek") && position_value < 0) position_value = 0;
    guint64 seek_request = 0;
    if (g_str_equal(action, "seek")) {
      seek_request = ++next_seek_request;
      pending_seek_request = seek_request;
      pending_seek_target = position_value;
      pending_seek_emitted = false;
    }
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "action", fl_value_new_string(action));
    if (position_value >= 0) fl_value_set_string_take(args, "position", fl_value_new_float(position_value));
    std::weak_ptr<CallbackState> weak_state = callback_state;
    auto* reply = new ActionReply{G_DBUS_METHOD_INVOCATION(g_object_ref(invocation)),
        [weak_state, seek_request, position_value](bool accepted) {
          if (!seek_request) return;
          auto state = weak_state.lock();
          if (state && state->owner) state->owner->CompleteSeekRequest(
              seek_request, position_value, accepted);
        }};
    fl_method_channel_invoke_method(channel, "action", args, nullptr, ActionFinished, reply);
  }

  static void MethodCallDbus(GDBusConnection*, const gchar*, const gchar*, const gchar* interface, const gchar* method, GVariant* parameters, GDBusMethodInvocation* invocation, gpointer data) {
    auto* s = static_cast<Impl*>(data);
    if (g_str_equal(interface, kRootInterface)) { s->Dispatch(invocation, g_str_equal(method, "Raise") ? "raise" : "quit"); return; }
    if (g_str_equal(method, "Next")) s->Dispatch(invocation, "next");
    else if (g_str_equal(method, "Previous")) s->Dispatch(invocation, "previous");
    else if (g_str_equal(method, "Pause")) s->Dispatch(invocation, "pause");
    else if (g_str_equal(method, "PlayPause")) s->Dispatch(invocation, "toggle");
    else if (g_str_equal(method, "Stop")) s->Dispatch(invocation, "stop");
    else if (g_str_equal(method, "Play")) s->Dispatch(invocation, "play");
    else if (g_str_equal(method, "Seek")) { gint64 offset = 0; g_variant_get(parameters, "(x)", &offset); s->Dispatch(invocation, "seek", s->position + offset / 1000000.0); }
    else if (g_str_equal(method, "SetPosition")) { const gchar* track = nullptr; gint64 pos = 0; g_variant_get(parameters, "(&ox)", &track, &pos); gchar* hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, s->token.c_str(), -1); const std::string id = std::string("/com/moetaku/fideflow/track/t") + (hash ? hash : "current"); g_free(hash); if (!s->has_track || !g_str_equal(track, id.c_str()) || pos < 0 || pos >= static_cast<gint64>(s->duration * 1000000.0)) g_dbus_method_invocation_return_value(invocation, nullptr); else s->Dispatch(invocation, "seek", pos / 1000000.0); }
    else if (g_str_equal(method, "OpenUri")) g_dbus_method_invocation_return_error_literal(invocation, G_DBUS_ERROR, G_DBUS_ERROR_NOT_SUPPORTED, "Opening media URIs is not supported");
    else g_dbus_method_invocation_return_error_literal(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown MPRIS method");
  }
};

LinuxPlayerControls::LinuxPlayerControls(GtkApplication* app, GtkWindow* window, FlView* view)
    : impl_(std::make_unique<Impl>(app, window, view)) {}
LinuxPlayerControls::~LinuxPlayerControls() = default;
void LinuxPlayerControls::SetQuitHandler(std::function<void()> handler) {
  impl_->quit_handler = std::move(handler);
  impl_->PropertiesChanged();
}
