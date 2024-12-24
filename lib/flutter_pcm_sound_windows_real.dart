import 'dart:ffi';
import 'dart:math';
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

  // System (mix) format after WASAPI init
  int _finalSampleRate = 0;
  int _finalChannelCount = 0;

  int _clientSampleRate = 0;
  int _clientChannelCount = 0;

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
      _logError('${operation ?? 'Operation'} failed: $error (0x${hr.toRadixString(16)})');
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
      check(_audioClient!.getCurrentPadding(pNumFramesPadding), 'Get current padding');
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
    _clientChannelCount = channelCount;

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
      
      // First get the mix format (system / shared mode format)
      final ppMixFormat = calloc<Pointer<WAVEFORMATEX>>();
      check(_audioClient!.getMixFormat(ppMixFormat), 'Get mix format');
      final pMixFormat = ppMixFormat.value;

      // Store final system format details
      _finalSampleRate = pMixFormat.ref.nSamplesPerSec;
      _finalChannelCount = pMixFormat.ref.nChannels;

      _log('System Mix Format: $_finalSampleRate Hz, $_finalChannelCount channels, ${pMixFormat.ref.wBitsPerSample}-bit');

      // Construct a wave format that we’d like to use.
      // For shared mode, we’re allowed to request something, but the OS may force us to the mix format.
      // We'll still try for 16-bit with the specified sampleRate/channelCount from the user.
      final pWaveFormat = calloc<WAVEFORMATEX>();
      pWaveFormat.ref
        ..wFormatTag = WAVE_FORMAT_PCM
        ..nChannels = channelCount
        ..nSamplesPerSec = sampleRate
        ..wBitsPerSample = 16
        ..nBlockAlign = (16 * channelCount) ~/ 8
        ..nAvgBytesPerSec = sampleRate * ((16 * channelCount) ~/ 8)
        ..cbSize = 0;

      // Check if the requested format is supported
      final pClosestMatch = calloc<Pointer<WAVEFORMATEX>>();
      final hr = _audioClient!.isFormatSupported(
        AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
        pWaveFormat,
        pClosestMatch
      );
      
      if (hr == S_OK) {
        _log('Requested format is supported: ${sampleRate}Hz, $channelCount channel(s).');
      } else if (hr == S_FALSE && pClosestMatch.value != nullptr) {
        final closest = pClosestMatch.value.ref;
        _log('Requested format not fully supported. Using closest match: '
             '${closest.nSamplesPerSec}Hz, ${closest.nChannels} channel(s).');

        // Update our wave format struct to the closest match
        pWaveFormat.ref
          ..nSamplesPerSec = closest.nSamplesPerSec
          ..nChannels = closest.nChannels
          ..wBitsPerSample = closest.wBitsPerSample
          ..nBlockAlign = (closest.wBitsPerSample * closest.nChannels) ~/ 8
          ..nAvgBytesPerSec = closest.nSamplesPerSec *
                              ((closest.wBitsPerSample * closest.nChannels) ~/ 8);
      } else {
        check(hr, 'Format check');
      }

      // Re-check what the final format we’re actually using is (pWaveFormat)
      _log('Final format for initialization: '
           '${pWaveFormat.ref.nSamplesPerSec} Hz, '
           '${pWaveFormat.ref.nChannels} channel(s), '
           '${pWaveFormat.ref.wBitsPerSample}-bit');

      // Initialize audio client
      final bufferDuration = 2000 * 10000; // 2 seconds in 100-ns units
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
      free(pBufferFrameCount);

      _log('Buffer frame count: $_bufferFrameCount');

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

  /// Feed raw PCM data to WASAPI.
  ///
  /// [buffer] is the client’s PCM data in 16-bit, interleaved format.
  /// [clientSampleRate] is e.g., 24000
  /// [clientChannels] is e.g., 1 (mono)
  Future<void> feed(PcmArrayInt16 buffer) async {
    if (!_isInitialized) {
      _logError('Cannot feed: not initialized');
      return;
    }

    int clientSampleRate = _clientSampleRate;
    int clientChannels = _clientChannelCount;

    try {
      // Start periodic buffer checks if not already running
      _checkTimer?.cancel();
      _checkTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) {
        _checkBuffer();
      });

      final pNumFramesPadding = calloc<UINT32>();
      check(_audioClient!.getCurrentPadding(pNumFramesPadding), 'Get current padding');
      final framesInBuffer = pNumFramesPadding.value;
      final numFramesAvailable = _bufferFrameCount - framesInBuffer;
      free(pNumFramesPadding);

      _logVerbose('Buffer status: $framesInBuffer buffered, $numFramesAvailable available');

      if (numFramesAvailable > 0) {
        // Convert incoming buffer to Int16List
        final inputSamples = buffer.bytes.buffer.asInt16List();

        // If client format != final system mix format, resample/upmix
        final Float32List finalData = _resampleIfNeeded(
          inputSamples,
          clientSampleRate,
          clientChannels,
          _finalSampleRate,
          _finalChannelCount
        );

        final totalFrames = finalData.length ~/ _finalChannelCount; // each frame has `_finalChannelCount` floats

        // Decide how many frames we can copy into WASAPI right now
        final framesToCopy = totalFrames < numFramesAvailable
            ? totalFrames
            : numFramesAvailable;

        // Lock the WASAPI buffer
        final pData = calloc<Pointer<Float>>();
        check(_renderClient!.getBuffer(framesToCopy, pData.cast()), 'Get buffer');

// Just before buffer copy:
final minValue = finalData.reduce(min);
final maxValue = finalData.reduce(max);
_log('Audio values - min: $minValue, max: $maxValue');

// Sample first few values
_log('First 10 samples: ${finalData.take(10).toList()}');

        // Copy finalData into the WASAPI buffer
final dst = pData.value.asTypedList(framesToCopy * _finalChannelCount);
dst.setRange(0, framesToCopy * _finalChannelCount, finalData);

// Check what actually got copied
_log('First 10 samples after copy: ${dst.take(10).toList()}');
        // Release the WASAPI buffer
        check(_renderClient!.releaseBuffer(framesToCopy, 0), 'Release buffer');
        free(pData);

        _logVerbose('Fed $framesToCopy frames (client: $clientSampleRate Hz, $clientChannels ch)');
      }
    } catch (e) {
      _logError('Feed failed: $e');
      rethrow;
    }
  }

  /// A minimal up-sampling / up-mixing routine that:
  /// - If clientSampleRate == finalSampleRate and clientChannels == finalChannels, pass through.
  /// - Else if (24->48 and 1->2) do a basic linear interpolation upsample (2x) and stereo duplication.
  /// - Otherwise, also pass through (you can expand logic if you want other ratios).
  Float32List _resampleIfNeeded(
    Int16List inputSamples,
    int inSampleRate,
    int inChannels,
    int outSampleRate,
    int outChannels
  ) {
    // If the format matches, just pass through
    if (inSampleRate == outSampleRate && inChannels == outChannels) {
      // Convert 16-bit int to float32, because the WASAPI code writes floats
      final outData = Float32List(inputSamples.length);
      for (int i = 0; i < inputSamples.length; i++) {
        outData[i] = inputSamples[i] / 32768.0;
      }
      return outData;
    }

    // For simplicity, handle only the “24 kHz mono → 48 kHz stereo” case
    // If it’s not that, we’ll just do a direct pass-through (but disclaim it)
    if (inSampleRate == 24000 && outSampleRate == 48000 &&
        inChannels == 1 && outChannels == 2) {
      return _upsample24kTo48kStereo(inputSamples);
    }
    print(
        'In sample rate: $inSampleRate, In channels: $inChannels, Out sample rate: $outSampleRate, Out channels: $outChannels');

    if (inSampleRate == 48000 && inChannels == 1 && outSampleRate ==48000 && outChannels == 2) {
      final outData = Float32List(inputSamples.length * 2);
  // Add these debug prints:
  print('Original samples min: ${inputSamples.reduce(min)}, max: ${inputSamples.reduce(max)}');
  print('First 10 original samples: ${inputSamples.take(10).toList()}');
  
      for (int i = 0; i < inputSamples.length; i++) {
        outData[i * 2] = inputSamples[i].toDouble();
        outData[i * 2 + 1] = inputSamples[i].toDouble();
      }
      return outData;
    }

    _logError(
      'Unsupported resampling from $inSampleRate/$inChannels to '
      '$outSampleRate/$outChannels. Falling back to pass-through; audio may sound incorrect!'
    );

    // Just pass-through (16-bit → float only)
    final outData = Float32List(inputSamples.length);
    for (int i = 0; i < inputSamples.length; i++) {
      outData[i] = inputSamples[i] / 32768.0;
    }
    return outData;
  }

  /// Simple 2× upsampling (linear interpolation) from 24 kHz mono
  /// → 48 kHz stereo float32
  Float32List _upsample24kTo48kStereo(Int16List mono24k) {
    print(
        'upsample24kTo48kStereo. First 10 samples: ${mono24k.take(10).toList()}');
    final inNumFrames = mono24k.length; // each sample is 1 channel
    final outNumFrames = inNumFrames * 2; // 2× upsample
    // stereo => 2 channels → total out samples = outNumFrames * 2
    final out = Float32List(outNumFrames * 2);

    for (int i = 0; i < inNumFrames - 1; i++) {
      final s1 = mono24k[i].toDouble();
      final s2 = mono24k[i + 1].toDouble();
      final outIndex = i * 4; // each input frame → 2 output frames, 2 channels each = 4 floats

      // first output frame (same as s1, duplicated L+R)
      out[outIndex]     = s1; // left
      out[outIndex + 1] = s1; // right

      // second output frame = linear interpolation
      final mid = (s1 + s2) * 0.5;
      out[outIndex + 2] = s1; // left
      out[outIndex + 3] = s1; // right
    }

    // Handle last sample
    final sLast = mono24k[inNumFrames - 1] / 32768.0;
    final lastIndex = (inNumFrames - 1) * 4;
    // first frame
    out[lastIndex]     = sLast;
    out[lastIndex + 1] = sLast;
    // second frame
    out[lastIndex + 2] = sLast;
    out[lastIndex + 3] = sLast;

    print(
        'upsample24kTo48kStereo. First 20 samples after upsample: ${out.take(20).toList()}');
    return out;
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
      //  assert(onFeedSamplesCallback != null);
      // onFeedSamplesCallback!(0);
  }
}
