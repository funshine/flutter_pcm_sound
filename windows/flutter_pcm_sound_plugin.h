#ifndef FLUTTER_PLUGIN_FLUTTER_PCM_SOUND_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_PCM_SOUND_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <winrt/Windows.Media.Audio.h>
#include <winrt/Windows.Foundation.h>

namespace flutter_pcm_sound {

class FlutterPcmSoundPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterPcmSoundPlugin();
  virtual ~FlutterPcmSoundPlugin();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  winrt::Windows::Media::Audio::AudioGraph audio_graph{nullptr};
  winrt::Windows::Media::Audio::AudioFrameInputNode input_node{nullptr};
  bool is_initialized = false;
  
  bool InitializeAudioGraph();
  void CleanupAudioGraph();
  bool FeedData(const std::vector<uint8_t>& audio_data);
};

}  // namespace flutter_pcm_sound

#endif  // FLUTTER_PLUGIN_FLUTTER_PCM_SOUND_PLUGIN_H_