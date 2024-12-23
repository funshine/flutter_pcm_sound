import 'dart:ffi';
import 'dart:typed_data';
import 'dart:async';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'flutter_pcm_sound.dart';

class FlutterPcmSoundWindows {
  // WASAPI interfaces
  IAudioClient3? _audioClient;
  IAudioRenderClient? _renderClient;
  
  // Audio configuration
  int _sampleRate = 44100;
  int _channelCount = 2;
  int _feedThreshold = 0;
  LogLevel _logLevel = LogLevel.standard;
  
  // Buffer management
  int _bufferFrameCount = 0;
  bool _isInitialized = false;
  bool _isPlaying = false;
  Timer? _feedTimer;

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
      _logError('${operation ?? 'Operation'} failed: $error (0x${hr.toRadixString(16)})');
      throw error;
    }
  }

  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    IosAudioCategory iosAudioCategory = IosAudioCategory.playback,
  }) async {
    try {
      _sampleRate = sampleRate;
      _channelCount = channelCount;
      
      _log('Initializing WASAPI with sample rate: $sampleRate, channels: $channelCount');
      
      // Initialize COM
      check(CoInitializeEx(nullptr, COINIT.COINIT_APARTMENTTHREADED), 'COM initialization');
      
      // Get default audio endpoint
      final pDeviceEnumerator = MMDeviceEnumerator.createInstance();
      final ppDevice = calloc<COMObject>();
      check(
        pDeviceEnumerator.getDefaultAudioEndpoint(
          EDataFlow.eRender,
          ERole.eConsole,
          ppDevice.cast()
        ),
        'Get default audio endpoint'
      );
      
      // Create Audio Client
      final pDevice = IMMDevice(ppDevice);
      final iidAudioClient = convertToIID(IID_IAudioClient3);
      final ppAudioClient = calloc<COMObject>();
      check(
        pDevice.activate(iidAudioClient, CLSCTX.CLSCTX_ALL, nullptr, ppAudioClient.cast()),
        'Activate audio client'
      );
      free(iidAudioClient);
      
      _audioClient = IAudioClient3(ppAudioClient);
      
      // First get the mix format to understand what the system supports
      final ppMixFormat = calloc<Pointer<WAVEFORMATEX>>();
      check(_audioClient!.getMixFormat(ppMixFormat), 'Get mix format');
      final pMixFormat = ppMixFormat.value;
      
      // Create our format based on the mix format capabilities
      final pWaveFormat = calloc<WAVEFORMATEX>();
      pWaveFormat.ref
        ..wFormatTag = WAVE_FORMAT_PCM
        ..nChannels = channelCount
        ..nSamplesPerSec = sampleRate
        ..wBitsPerSample = 16 // Match Int16 from PcmArrayInt16
        ..nBlockAlign = (16 * channelCount) ~/ 8
        ..nAvgBytesPerSec = sampleRate * ((16 * channelCount) ~/ 8)
        ..cbSize = 0;

      _log('Mix Format: ${pMixFormat.ref.nSamplesPerSec}Hz, ${pMixFormat.ref.nChannels} channels, ${pMixFormat.ref.wBitsPerSample}-bit');
      _log('Requested Format: ${sampleRate}Hz, $channelCount channels, 16-bit PCM');

      // Check if our format is supported
      final pClosestMatch = calloc<Pointer<WAVEFORMATEX>>();
      final hr = _audioClient!.isFormatSupported(
          AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
          pWaveFormat,
          pClosestMatch);

      if (hr == S_OK) {
        _log('Requested format is supported');
      } else if (hr == S_FALSE && pClosestMatch.value != nullptr) {
        _log('Using closest matching format');
        final closest = pClosestMatch.value.ref;
        _log('Closest Format: ${closest.nSamplesPerSec}Hz, ${closest.nChannels} channels, ${closest.wBitsPerSample}-bit');
        
        // Use the closest matching format
        pWaveFormat.ref
          ..nSamplesPerSec = closest.nSamplesPerSec
          ..nChannels = closest.nChannels
          ..wBitsPerSample = closest.wBitsPerSample
          ..nBlockAlign = (closest.wBitsPerSample * closest.nChannels) ~/ 8
          ..nAvgBytesPerSec = closest.nSamplesPerSec * ((closest.wBitsPerSample * closest.nChannels) ~/ 8);
      } else {
        check(hr, 'Format check');
      }
      
      // Initialize audio client
      final bufferDuration = 5000 * 10000; // 5 seconds in 100-nanosecond units
      check(
        _audioClient!.initialize(
          AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
          0,
          bufferDuration,
          0,
          pWaveFormat,
          nullptr
        ),
        'Initialize audio client'
      );
      
      // Get buffer size
      final pBufferFrameCount = calloc<UINT32>();
      check(_audioClient!.getBufferSize(pBufferFrameCount), 'Get buffer size');
      _bufferFrameCount = pBufferFrameCount.value;
      _log('Buffer frame count: $_bufferFrameCount');
      free(pBufferFrameCount);
      
      // Get render client
      final iidAudioRenderClient = convertToIID(IID_IAudioRenderClient);
      final ppRenderClient = calloc<COMObject>();
      check(
        _audioClient!.getService(iidAudioRenderClient, ppRenderClient.cast()),
        'Get render client'
      );
      free(iidAudioRenderClient);
      _renderClient = IAudioRenderClient(ppRenderClient);
      
      // Start the audio client
      check(_audioClient!.start(), 'Start audio client');
      
      _isInitialized = true;
      _log('WASAPI initialization complete');
      
    } catch (e) {
      _logError('Setup failed: $e');
      await release();
      rethrow;
    }
  }

  Future<void> feed(Uint8List buffer) async {
    if (!_isInitialized) {
      _logError('Cannot feed: not initialized');
      return;
    }

    try {
      // Start the feed timer if this is our first feed
      if (!_isPlaying) {
        _isPlaying = true;
        _feedTimer?.cancel();
        _feedTimer = Timer.periodic(Duration(milliseconds: 10), (_) {
          if (FlutterPcmSound.onFeedSamplesCallback != null) {
            FlutterPcmSound.onFeedSamplesCallback!(4800); // Request about 100ms worth at 48kHz
          }
        });
      }

      final pNumFramesPadding = calloc<UINT32>();
      check(_audioClient!.getCurrentPadding(pNumFramesPadding), 'Get current padding');
      final numFramesAvailable = _bufferFrameCount - pNumFramesPadding.value;
      final framesInBuffer = pNumFramesPadding.value;
      free(pNumFramesPadding);

      _logVerbose('Buffer status: $framesInBuffer buffered, $numFramesAvailable available');

      if (numFramesAvailable > 0) {
        final pData = calloc<Pointer<BYTE>>();
        check(_renderClient!.getBuffer(numFramesAvailable, pData), 'Get buffer');
        
        final src = buffer.buffer.asInt16List();
        final framesToCopy = (buffer.lengthInBytes ~/ 2) < numFramesAvailable
            ? (buffer.lengthInBytes ~/ 2)
            : numFramesAvailable;

        if (framesToCopy > 0) {
          final dst = pData.value.cast<Float>();
          for (var i = 0; i < framesToCopy; i++) {
            final float = src[i] / 32768.0;
            dst[i * 2] = float;
            dst[i * 2 + 1] = float;
          }

          check(_renderClient!.releaseBuffer(framesToCopy, 0), 'Release buffer');
          _logVerbose('Fed $framesToCopy frames');
        }
        free(pData);
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
    
    _isPlaying = false;
    _feedTimer?.cancel();
    _feedTimer = null;

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
}