#include "flutter_pcm_sound_plugin.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <sstream>

namespace flutter_pcm_sound {

namespace {
constexpr int kSampleRate = 44100;
constexpr int kChannels = 2;
constexpr int kBitsPerSample = 16;
}  // namespace

void FlutterPcmSoundPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_pcm_sound",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterPcmSoundPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlutterPcmSoundPlugin::FlutterPcmSoundPlugin() {}

FlutterPcmSoundPlugin::~FlutterPcmSoundPlugin() {
  CleanupAudioGraph();
}

void FlutterPcmSoundPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("initialize") == 0) {
    if (InitializeAudioGraph()) {
      result->Success();
    } else {
      result->Error("INIT_FAILED", "Failed to initialize audio graph");
    }
  } else if (method_call.method_name().compare("feed") == 0) {
    const auto* arguments = std::get_if<std::vector<uint8_t>>(method_call.arguments());
    if (!arguments) {
      result->Error("INVALID_ARGUMENT", "Expected byte array");
      return;
    }
    
    if (FeedData(*arguments)) {
      result->Success();
    } else {
      result->Error("FEED_FAILED", "Failed to feed audio data");
    }
  } else if (method_call.method_name().compare("cleanup") == 0) {
    CleanupAudioGraph();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

bool FlutterPcmSoundPlugin::InitializeAudioGraph() {
  if (is_initialized) return true;

  try {
    // Initialize COM for the current thread
    winrt::init_apartment();

    // Create audio graph settings
    winrt::Windows::Media::Audio::AudioGraphSettings settings(
        winrt::Windows::Media::Render::AudioRenderCategory::Media);
    settings.DesiredRenderDeviceAudioProcessing(
        winrt::Windows::Media::AudioProcessing::Raw);
    settings.QuantumSizeSelectionMode(
        winrt::Windows::Media::Audio::QuantumSizeSelectionMode::LowestLatency);

    // Create the audio graph
    auto createGraphResult = winrt::Windows::Media::Audio::AudioGraph::CreateAsync(settings).get();
    if (createGraphResult.Status() != winrt::Windows::Media::Audio::AudioGraphCreationStatus::Success) {
      return false;
    }
    audio_graph = createGraphResult.Graph();

    // Create the input node for raw PCM data
    auto inputNodeResult = audio_graph.CreateFrameInputNode().get();
    input_node = inputNodeResult;

    // Connect the input node to the graph
    input_node.AddOutgoingConnection(audio_graph.CreateDeviceOutputNode().get());

    // Start the audio graph
    audio_graph.Start();
    is_initialized = true;
    return true;
  } catch (...) {
    return false;
  }
}

void FlutterPcmSoundPlugin::CleanupAudioGraph() {
  if (!is_initialized) return;

  if (audio_graph != nullptr) {
    audio_graph.Stop();
    audio_graph = nullptr;
  }
  
  input_node = nullptr;
  is_initialized = false;
}

bool FlutterPcmSoundPlugin::FeedData(const std::vector<uint8_t>& audio_data) {
  if (!is_initialized || input_node == nullptr) return false;

  try {
    // Calculate frame count (2 bytes per sample, 2 channels)
    uint32_t frame_count = audio_data.size() / (kBitsPerSample / 8) / kChannels;
    
    // Create audio frame
    auto frame = winrt::Windows::Media::AudioFrame(frame_count * sizeof(float) * kChannels);
    
    // Get buffer for the frame
    auto buffer = frame.LockBuffer(winrt::Windows::Media::AudioBufferAccessMode::Write);
    auto reference = buffer.CreateReference();
    
    // Get raw buffer pointer
    float* raw_buffer = reinterpret_cast<float*>(reference.data());
    
    // Convert 16-bit PCM to float
    const int16_t* pcm_data = reinterpret_cast<const int16_t*>(audio_data.data());
    for (uint32_t i = 0; i < frame_count * kChannels; i++) {
      raw_buffer[i] = pcm_data[i] / 32768.0f;
    }
    
    // Add the frame to the input node
    input_node.AddFrame(frame);
    return true;
  } catch (...) {
    return false;
  }
}

}  // namespace flutter_pcm_sound