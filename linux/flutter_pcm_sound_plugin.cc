#include "include/flutter_pcm_sound/flutter_pcm_sound_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>
#include <alsa/asoundlib.h>
#include <thread>
#include <mutex>
#include <vector>
#include <algorithm>
#include <chrono>


#include <cstring>

#include "flutter_pcm_sound_plugin_private.h"

#define FLUTTER_PCM_SOUND_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_pcm_sound_plugin_get_type(), \
                              FlutterPcmSoundPlugin))


struct _FlutterPcmSoundPlugin {
 GObject parent_instance;
 snd_pcm_t* handle;
 int sample_rate;
 int channels;
 FlMethodChannel* channel;
 int feed_threshold;
 bool did_invoke_feed_callback;
 std::vector<uint8_t> samples;
 std::mutex samples_mutex;
 bool should_stop;
 std::thread* playback_thread;
};

G_DEFINE_TYPE(FlutterPcmSoundPlugin, flutter_pcm_sound_plugin, g_object_get_type())

static FlMethodResponse* setup_alsa(FlutterPcmSoundPlugin* self, FlValue* args) {
  int err;
 g_print("Setup args: %s\n", fl_value_to_string(args));

 FlValue* sample_rate_value = fl_value_lookup_string(args, "sample_rate");
 FlValue* channel_value = fl_value_lookup_string(args, "num_channels"); 
 
 if (!sample_rate_value || !channel_value) {
   g_autofree gchar* args_str = fl_value_to_string(args);

   const char* err_msg = g_strdup_printf("Missing args. Setup called with args: %s", args_str);

   g_print("Missing args - sample_rate: %p, channels: %p\n", 
           sample_rate_value, channel_value);
 return FL_METHOD_RESPONSE(fl_method_error_response_new("DEBUG", err_msg, nullptr));

 }

  self->sample_rate = fl_value_get_int(sample_rate_value);
  self->channels = fl_value_get_int(channel_value);

 err = snd_pcm_open(&self->handle, "default", SND_PCM_STREAM_PLAYBACK, 0);
 if (err < 0) return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));

 snd_pcm_hw_params_t* params;
 snd_pcm_hw_params_alloca(&params);
 snd_pcm_hw_params_any(self->handle, params);
 
 snd_pcm_hw_params_set_access(self->handle, params, SND_PCM_ACCESS_RW_INTERLEAVED);
 snd_pcm_hw_params_set_format(self->handle, params, SND_PCM_FORMAT_S16_LE);
 snd_pcm_hw_params_set_channels(self->handle, params, self->channels);
 snd_pcm_hw_params_set_rate(self->handle, params, self->sample_rate, 0);
 
 err = snd_pcm_hw_params(self->handle, params);
 if (err < 0) {
   snd_pcm_close(self->handle);
   self->handle = NULL;
   return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
 }

 return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* feed_alsa(FlutterPcmSoundPlugin* self, FlValue* args) {
  if (!self->handle) return FL_METHOD_RESPONSE(fl_method_error_response_new("NOT_INITIALIZED", "ALSA not initialized", nullptr));

  FlValue* buffer = fl_value_lookup_string(args, "buffer");
  const uint8_t* data = fl_value_get_uint8_list(buffer);
  size_t length = fl_value_get_length(buffer);

  {
    std::lock_guard<std::mutex> lock(self->samples_mutex);
    self->samples.insert(self->samples.end(), data, data + length);
    self->did_invoke_feed_callback = false;
  }

  if (!self->playback_thread) {
    self->should_stop = false;
    self->playback_thread = new std::thread(playback_thread_func, self);
  }

  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
}

static FlMethodResponse* release_alsa(FlutterPcmSoundPlugin* self) {
 if (self->handle) {
   if (self->playback_thread) {
     self->should_stop = true;
     self->playback_thread->join();
     delete self->playback_thread;
     self->playback_thread = nullptr;
   }

   snd_pcm_drain(self->handle);
   snd_pcm_close(self->handle);
   self->handle = NULL;

   {
     std::lock_guard<std::mutex> lock(self->samples_mutex);
     self->samples.clear();
   }
 }
 return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
}

static void flutter_pcm_sound_plugin_handle_method_call(
   FlutterPcmSoundPlugin* self,
   FlMethodCall* method_call) {
 g_autoptr(FlMethodResponse) response = nullptr;
 const gchar* method = fl_method_call_get_name(method_call);
 FlValue* args = fl_method_call_get_args(method_call);

if (strcmp(method, "setLogLevel") == 0) {
  response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
} else if (strcmp(method, "setFeedThreshold") == 0) {
  FlValue* threshold_value = fl_value_lookup_string(args, "feed_threshold");
  if (!threshold_value) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new("INVALID_ARGS", "feed_threshold required", nullptr));
  } else {
    self->feed_threshold = fl_value_get_int(threshold_value);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
  }
} else if (strcmp(method, "setup") == 0) {
   response = setup_alsa(self, args);
 } else if (strcmp(method, "feed") == 0) {
   response = feed_alsa(self, args);
 } else if (strcmp(method, "release") == 0) {
   response = release_alsa(self);
 } else {
   response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
 }

 fl_method_call_respond(method_call, response, nullptr);
}

static void flutter_pcm_sound_plugin_dispose(GObject* object) {
 FlutterPcmSoundPlugin* self = FLUTTER_PCM_SOUND_PLUGIN(object);
 if (self->handle) {
   snd_pcm_close(self->handle);
   self->handle = NULL;
 }
 G_OBJECT_CLASS(flutter_pcm_sound_plugin_parent_class)->dispose(object);
}

static void flutter_pcm_sound_plugin_class_init(FlutterPcmSoundPluginClass* klass) {
 G_OBJECT_CLASS(klass)->dispose = flutter_pcm_sound_plugin_dispose;
}

static void playback_thread_func(FlutterPcmSoundPlugin* self) {
  const int chunk_size = 200 * self->channels * 2;

  while (!self->should_stop) {
    std::vector<uint8_t> chunk;
    size_t remaining_frames;
    
    {
      std::lock_guard<std::mutex> lock(self->samples_mutex);
      if (self->samples.empty()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }

      size_t bytes_to_take = std::min(chunk_size, (int)self->samples.size());
      chunk.assign(self->samples.begin(), self->samples.begin() + bytes_to_take);
      self->samples.erase(self->samples.begin(), self->samples.begin() + bytes_to_take);
      
      remaining_frames = self->samples.size() / (self->channels * 2);
    }

    snd_pcm_sframes_t frames = snd_pcm_writei(self->handle, chunk.data(), chunk.size() / (self->channels * 2));
    if (frames < 0) {
      frames = snd_pcm_recover(self->handle, frames, 0);
      if (frames < 0) continue;
      frames = snd_pcm_writei(self->handle, chunk.data(), chunk.size() / (self->channels * 2));
    }

    if (remaining_frames <= self->feed_threshold && !self->did_invoke_feed_callback) {
      self->did_invoke_feed_callback = true;
      
      g_idle_add([](gpointer user_data) -> gboolean {
        auto* self = static_cast<FlutterPcmSoundPlugin*>(user_data);
        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(map, "remaining_frames", fl_value_new_int(remaining_frames));
        fl_method_channel_invoke_method(self->channel, "OnFeedSamples", map, NULL, NULL, NULL);
        return G_SOURCE_REMOVE;
      }, self);
    }
  }
}

static void flutter_pcm_sound_plugin_init(FlutterPcmSoundPlugin* self) {
  self->handle = NULL;
  self->feed_threshold = 8000;
  self->did_invoke_feed_callback = false;
  self->should_stop = false;
  self->playback_thread = nullptr;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                         gpointer user_data) {
 FlutterPcmSoundPlugin* plugin = FLUTTER_PCM_SOUND_PLUGIN(user_data);
 flutter_pcm_sound_plugin_handle_method_call(plugin, method_call);
}

void flutter_pcm_sound_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
 FlutterPcmSoundPlugin* plugin = FLUTTER_PCM_SOUND_PLUGIN(
     g_object_new(flutter_pcm_sound_plugin_get_type(), nullptr));

 g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
 g_autoptr(FlMethodChannel) channel =
     fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                          "flutter_pcm_sound/methods",
                          FL_METHOD_CODEC(codec));
 fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                         g_object_ref(plugin),
                                         g_object_unref);
plugin->channel = g_object_ref(channel);

 g_object_unref(plugin);
}