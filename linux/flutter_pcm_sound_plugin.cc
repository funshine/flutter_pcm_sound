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

struct FeedCallbackData {
  FlutterPcmSoundPlugin* plugin;
  size_t remaining_frames;
};

static gboolean feed_callback(gpointer user_data) {
  FeedCallbackData* data = static_cast<FeedCallbackData*>(user_data);
  g_print("Feed callback triggered with remaining frames: %zu\n", data->remaining_frames);
  
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "remaining_frames", fl_value_new_int(data->remaining_frames));
  fl_method_channel_invoke_method(data->plugin->channel, "OnFeedSamples", map, NULL, NULL, NULL);
  
  delete data;
  return G_SOURCE_REMOVE;
}



G_DEFINE_TYPE(FlutterPcmSoundPlugin, flutter_pcm_sound_plugin, g_object_get_type())

static void playback_thread_func(FlutterPcmSoundPlugin* self);
static FlMethodResponse* setup_alsa(FlutterPcmSoundPlugin* self, FlValue* args) {
  int err;
  g_print("Setup args: %s\n", fl_value_to_string(args));

  FlValue* sample_rate_value = fl_value_lookup_string(args, "sample_rate");
  FlValue* channel_value = fl_value_lookup_string(args, "num_channels"); 
  
  if (!sample_rate_value || !channel_value) {
    g_autofree gchar* args_str = fl_value_to_string(args);
    const char* err_msg = g_strdup_printf("Missing args. Setup called with args: %s", args_str);
    g_print("Missing args - sample_rate: %p, channels: %p\n", sample_rate_value, channel_value);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("DEBUG", err_msg, nullptr));
  }

  self->sample_rate = fl_value_get_int(sample_rate_value);
  self->channels = fl_value_get_int(channel_value);

  // Open PCM device
  if ((err = snd_pcm_open(&self->handle, "default", SND_PCM_STREAM_PLAYBACK, 0)) < 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Configure hardware parameters
  snd_pcm_hw_params_t* hw_params;
  snd_pcm_hw_params_alloca(&hw_params);
  
  // Fill params with a full configuration space for the PCM
  snd_pcm_hw_params_any(self->handle, hw_params);

  // Set access type to interleaved
  if ((err = snd_pcm_hw_params_set_access(self->handle, hw_params, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Set sample format
  if ((err = snd_pcm_hw_params_set_format(self->handle, hw_params, SND_PCM_FORMAT_S16_LE)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Set sample rate
  unsigned int actual_rate = self->sample_rate;
  if ((err = snd_pcm_hw_params_set_rate_near(self->handle, hw_params, &actual_rate, 0)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Set channels
  if ((err = snd_pcm_hw_params_set_channels(self->handle, hw_params, self->channels)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Set buffer and period sizes - use 4 periods
  snd_pcm_uframes_t buffer_size = 16384;  // Total buffer
  snd_pcm_uframes_t period_size = 4096;   // Period size (chunk size)
  
  if ((err = snd_pcm_hw_params_set_buffer_size_near(self->handle, hw_params, &buffer_size)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  if ((err = snd_pcm_hw_params_set_period_size_near(self->handle, hw_params, &period_size, 0)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Apply hw params
  if ((err = snd_pcm_hw_params(self->handle, hw_params)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Get actual configured values
  snd_pcm_uframes_t actual_buffer_size;
  snd_pcm_hw_params_get_buffer_size(hw_params, &actual_buffer_size);
  g_print("ALSA configured - rate: %u, channels: %d, buffer: %lu frames\n", 
          actual_rate, self->channels, actual_buffer_size);

  // Configure software params
  snd_pcm_sw_params_t* sw_params;
  snd_pcm_sw_params_alloca(&sw_params);
  snd_pcm_sw_params_current(self->handle, sw_params);

  // Start playing when we're 75% full
  if ((err = snd_pcm_sw_params_set_start_threshold(self->handle, sw_params, 
      (actual_buffer_size / 4) * 3)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Allow transfer when at least period_size samples can be processed
  if ((err = snd_pcm_sw_params_set_avail_min(self->handle, sw_params, period_size)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  if ((err = snd_pcm_sw_params(self->handle, sw_params)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  // Prepare device
  if ((err = snd_pcm_prepare(self->handle)) < 0) {
    snd_pcm_close(self->handle);
    return FL_METHOD_RESPONSE(fl_method_error_response_new("ALSA_ERROR", snd_strerror(err), nullptr));
  }

  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(true)));
}

static void flutter_pcm_sound_plugin_init(FlutterPcmSoundPlugin* self) {
  self->handle = NULL;
  self->feed_threshold = 1024;  // Will feed when one period worth of data remains
  self->did_invoke_feed_callback = false;
  self->should_stop = false;
  self->playback_thread = nullptr;
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
}static void playback_thread_func(FlutterPcmSoundPlugin* self) {
  // Write larger chunks to reduce thread overhead
  const size_t frames_per_write = 2048;  // Increased from 1024
  const size_t bytes_per_write = frames_per_write * self->channels * 2;
  
  while (!self->should_stop) {
    std::vector<uint8_t> chunk;
    size_t remaining_frames;
    bool need_more_data = false;
    
    {
      std::lock_guard<std::mutex> lock(self->samples_mutex);
      if (self->samples.empty()) {
        if (!self->did_invoke_feed_callback) {
          self->did_invoke_feed_callback = true;
          need_more_data = true;
          g_print("Buffer empty - requesting more data\n");  // Add this back
        }
        // Don't sleep if we're empty, just try again
        continue;
      }

      size_t bytes_to_take = std::min(bytes_per_write, self->samples.size());
      chunk.assign(self->samples.begin(), self->samples.begin() + bytes_to_take);
      self->samples.erase(self->samples.begin(), self->samples.begin() + bytes_to_take);
      
      remaining_frames = self->samples.size() / (self->channels * 2);
      
      if (remaining_frames <= self->feed_threshold && !self->did_invoke_feed_callback) {
        self->did_invoke_feed_callback = true;
        need_more_data = true;
      }
    }

    // Request more data outside the lock if needed
    if (need_more_data) {
      FeedCallbackData* data = new FeedCallbackData{self, remaining_frames};
      g_idle_add(feed_callback, data);
    }

    // Write to ALSA without holding the lock
    if (!chunk.empty()) {
      snd_pcm_sframes_t frames;
      while ((frames = snd_pcm_writei(self->handle, chunk.data(), 
             chunk.size() / (self->channels * 2))) == -EAGAIN) {
        // If buffer is full, keep trying without sleeping
        continue;
      }

      if (frames < 0) {
        if (frames == -EPIPE) {  // Underrun
          frames = snd_pcm_recover(self->handle, frames, 0);
          if (frames < 0) {
            g_print("Failed to recover from underrun: %s\n", snd_strerror(frames));
            break;
          }
          snd_pcm_prepare(self->handle);
          continue;
        }
        g_print("ALSA write error: %s\n", snd_strerror(frames));
        break;
      }
    }
  }
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
 plugin->channel = FL_METHOD_CHANNEL(g_object_ref(channel));

 g_object_unref(plugin);
}