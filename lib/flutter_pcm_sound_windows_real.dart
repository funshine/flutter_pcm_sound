import 'dart:ffi';
import 'dart:typed_data';
import 'dart:async';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'flutter_pcm_sound.dart';

FlutterPcmSoundImpl createWindowsImpl() => FlutterPcmSoundWindows();

class FlutterPcmSoundWindows implements FlutterPcmSoundImpl {
  // WASAPI interfaces
  IAudioClient3? _audioClient;
  IAudioRenderClient? _renderClient;

  // Audio configuration
  int _feedThreshold = 0;
  LogLevel _logLevel = LogLevel.standard;

  // Client format (what the app provides)
  int _clientSampleRate = 0;

  // Final format (what the system wants)
  int _finalSampleRate = 0;

  // Buffer management
  int _bufferFrameCount = 0;
  bool _isInitialized = false;
  Timer? _checkTimer;

  void _log(String message) {
    if (_logLevel.index >= LogLevel.standard.index) {
      print('[PCM Windows] $message');
    }
  }

  void _logError(String message) {
    if (_logLevel.index >= LogLevel.error.index) {
      print('[PCM Windows ERROR] $message');
    }
  }

  void _logVerbose(String message) {
    if (_logLevel.index >= LogLevel.verbose.index) {
      print('[PCM Windows VERBOSE] $message');
    }
  }

  Future<void> setLogLevel(LogLevel level) async {
    _logLevel = level;
  }

  void check(int hr, [String? operation]) {
    if (FAILED(hr)) {
      final error = WindowsException(hr);
      _logError(
          '${operation ?? 'Operation'} failed: $error (0x${hr.toRadixString(16)})');
      throw error;
    }
  }

  Future<void> _checkBuffer() async {
    if (!_isInitialized || FlutterPcmSound.onFeedSamplesCallback == null) {
      _checkTimer?.cancel();
      _checkTimer = null;
      return;
    }

    try {
      final pNumFramesPadding = calloc<UINT32>();
      check(_audioClient!.getCurrentPadding(pNumFramesPadding),
          'Get current padding');
      final framesInBuffer = pNumFramesPadding.value;
      free(pNumFramesPadding);

      if (framesInBuffer <= _feedThreshold) {
        _logVerbose('Buffer needs more data: $framesInBuffer frames remaining');
        FlutterPcmSound.onFeedSamplesCallback!(framesInBuffer);
      }
    } catch (e) {
      _logError('Buffer check failed: $e');
    }
  }

  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    IosAudioCategory iosAudioCategory = IosAudioCategory.playback,
  }) async {
    try {
      _log('Initializing WASAPI with sample rate: $sampleRate, channels: $channelCount');
      _clientSampleRate = sampleRate;

      // Initialize COM
      check(CoInitializeEx(nullptr, COINIT.COINIT_APARTMENTTHREADED),
          'COM initialization');

      // Get default audio endpoint
      final pDeviceEnumerator = MMDeviceEnumerator.createInstance();
      final ppDevice = calloc<COMObject>();
      check(
          pDeviceEnumerator.getDefaultAudioEndpoint(
              EDataFlow.eRender, ERole.eConsole, ppDevice.cast()),
          'Get default audio endpoint');

      // Create Audio Client
      final pDevice = IMMDevice(ppDevice);
      final iidAudioClient = convertToIID(IID_IAudioClient3);
      final ppAudioClient = calloc<COMObject>();
      check(
          pDevice.activate(
              iidAudioClient, CLSCTX.CLSCTX_ALL, nullptr, ppAudioClient.cast()),
          'Activate audio client');
      free(iidAudioClient);

      _audioClient = IAudioClient3(ppAudioClient);

      // Set client properties before any other audio client operations
      final props = calloc<AudioClientProperties>();
      props.ref
        ..cbSize = sizeOf<AudioClientProperties>()
        ..bIsOffload = 0
        ..eCategory = 3 /* communications */
        ..Options = AUDCLNT_STREAMOPTIONS.AUDCLNT_STREAMOPTIONS_MATCH_FORMAT;

      check(_audioClient!.setClientProperties(props),
          'Set client properties');
      free(props);

      // First get mix format to see what the system wants
      final ppMixFormat = calloc<Pointer<WAVEFORMATEX>>();
      check(_audioClient!.getMixFormat(ppMixFormat), 'Get mix format');
      final pMixFormat = ppMixFormat.value;
      
      _log('System Mix Format: ${pMixFormat.ref.nSamplesPerSec} Hz, ${pMixFormat.ref.nChannels} channels, ${pMixFormat.ref.wBitsPerSample}-bit');
      _finalSampleRate = pMixFormat.ref.nSamplesPerSec;
      // Construct our desired wave format
      final pWaveFormat = calloc<WAVEFORMATEX>();
      pWaveFormat.ref
        ..wFormatTag = WAVE_FORMAT_PCM
        ..nChannels = channelCount
        ..nSamplesPerSec = sampleRate
        ..wBitsPerSample = 16
        ..nBlockAlign = (16 * channelCount) ~/ 8
        ..nAvgBytesPerSec = sampleRate * ((16 * channelCount) ~/ 8)
        ..cbSize = 0;

      // Check if format is supported
      final pClosestMatch = calloc<Pointer<WAVEFORMATEX>>();
      final hr = _audioClient!.isFormatSupported(
          AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
          pWaveFormat,
          pClosestMatch);

      Pointer<WAVEFORMATEX> formatToUse;
      
      if (hr == S_OK) {
        _log('Requested format is directly supported');
        formatToUse = pWaveFormat;
      } else if (hr == S_FALSE && pClosestMatch.value != nullptr) {
        _log('Using closest supported format:');
        _log('Sample rate: ${pClosestMatch.value.ref.nSamplesPerSec}');
        _log('Channels: ${pClosestMatch.value.ref.nChannels}');
        _log('Bits per sample: ${pClosestMatch.value.ref.wBitsPerSample}');
        formatToUse = pClosestMatch.value;
      } else {
        _log('Using mix format as fallback');
        formatToUse = pMixFormat;
      }

      // Initialize audio client with format conversion
      final bufferDuration = 2000 * 10000; // 2 seconds in 100-ns units
      check(
          _audioClient!.initialize(AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
              0x80000000 | 0x08000000, // AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
              bufferDuration, 
              0, 
              formatToUse, 
              nullptr),
          'Initialize audio client');

      // Get buffer size
      final pBufferFrameCount = calloc<UINT32>();
      check(_audioClient!.getBufferSize(pBufferFrameCount), 'Get buffer size');
      _bufferFrameCount = pBufferFrameCount.value;
      free(pBufferFrameCount);

      _log('Buffer frame count: $_bufferFrameCount');

      // Get render client
      final iidAudioRenderClient = convertToIID(IID_IAudioRenderClient);
      final ppRenderClient = calloc<COMObject>();
      check(
          _audioClient!.getService(iidAudioRenderClient, ppRenderClient.cast()),
          'Get render client');
      free(iidAudioRenderClient);
      _renderClient = IAudioRenderClient(ppRenderClient);

      // Start the audio client
      check(_audioClient!.start(), 'Start audio client');

      // Clean up format allocations
      CoTaskMemFree(ppMixFormat.value.cast());
      free(ppMixFormat);
      if (pClosestMatch.value != nullptr) {
        CoTaskMemFree(pClosestMatch.value.cast());
      }
      free(pClosestMatch);
      free(pWaveFormat);

      _isInitialized = true;
      _log('WASAPI initialization complete');
    } catch (e) {
      _logError('Setup failed: $e');
      await release();
      rethrow;
    }
  }

  Future<void> feed(PcmArrayInt16 buffer) async {
    if (!_isInitialized) {
      _logError('Cannot feed: not initialized');
      return;
    }

    try {
      // Start periodic buffer checks if not already running
      _checkTimer?.cancel();
      _checkTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) {
        _checkBuffer();
      });

      final pNumFramesPadding = calloc<UINT32>();
      check(_audioClient!.getCurrentPadding(pNumFramesPadding),
          'Get current padding');
      final framesInBuffer = pNumFramesPadding.value;
      final numFramesAvailable = _bufferFrameCount - framesInBuffer;
      free(pNumFramesPadding);

      _logVerbose(
          'Buffer status: $framesInBuffer buffered, $numFramesAvailable available');

      if (numFramesAvailable > 0) {
        // Convert incoming buffer to Float32List
        final inputSamples = buffer.bytes.buffer.asInt16List();
        
        // Handle 24kHz -> 48kHz upsampling if needed
        Int16List upsampledData;
        if (_clientSampleRate == 24000 && _finalSampleRate == 48000) {
          // Simple 2x upsampling - each sample becomes two samples
          upsampledData = Int16List(inputSamples.length * 2);
          for (int i = 0; i < inputSamples.length; i++) {
            upsampledData[i * 2] = inputSamples[i];
            upsampledData[i * 2 + 1] = inputSamples[i];
          }
        } else {
          upsampledData = inputSamples;
        }
        
        // Calculate frame counts based on input mono data
        final inputFrames = upsampledData.length; // Each mono sample is one frame
        final outputFrames = inputFrames; // Same number of frames, but stereo
        
        // Create output buffer with space for stereo data
        final Float32List finalData = Float32List(outputFrames * 2); // * 2 for stereo
        
        // Convert and duplicate mono samples to stereo
        for (int i = 0; i < inputFrames; i++) {
          final float = inputSamples[i] / 32768.0;
          finalData[i * 2] = float;     // Left channel
          finalData[i * 2 + 1] = float; // Right channel
        }

        final framesToCopy = outputFrames < numFramesAvailable ? outputFrames : numFramesAvailable;

        // Lock the WASAPI buffer
        final pData = calloc<Pointer<Float>>();
        check(_renderClient!.getBuffer(framesToCopy, pData.cast()), 'Get buffer');

        // Copy finalData into the WASAPI buffer (now properly stereo)
        final dst = pData.value.asTypedList(framesToCopy * 2); // * 2 for stereo
        dst.setRange(0, framesToCopy * 2, finalData);

        // Release the WASAPI buffer
        check(_renderClient!.releaseBuffer(framesToCopy, 0), 'Release buffer');
        free(pData);

        _logVerbose('Fed $framesToCopy frames');
      }
    } catch (e) {
      _logError('Feed failed: $e');
      rethrow;
    }
  }

  Future<void> setFeedThreshold(int threshold) async {
    _feedThreshold = threshold;
    _log('Feed threshold set to $_feedThreshold frames');
  }

  Future<void> release() async {
    _log('Releasing resources');

    _checkTimer?.cancel();
    _checkTimer = null;

    if (_audioClient != null) {
      try {
        _audioClient!.stop();
      } catch (e) {
        _logError('Error stopping audio client: $e');
      }
    }

    _audioClient = null;
    _renderClient = null;
    _isInitialized = false;
    _log('Resources released');
  }

  @override
  void setFeedCallback(Function(int p1)? callback) {
    // TODO: implement setFeedCallback
  }

  @override
  void start() {
    // TODO: implement start
  }
}