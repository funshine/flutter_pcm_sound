import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'flutter_pcm_sound.dart';

FlutterPcmSoundImpl createWindowsImpl() => FlutterPcmSoundWindows();

class FlutterPcmSoundWindows implements FlutterPcmSoundImpl {
  // WASAPI interfaces
  IAudioClient3? _audioClient;
  IAudioRenderClient? _renderClient;

  // Internal buffer: holds 16-bit PCM samples (iOS-style "mSamples")
  final List<int> _samples = [];

  // Audio configuration
  int _feedThreshold = 0;
  LogLevel _logLevel = LogLevel.standard;

  // Requested format
  int _clientSampleRate = 0;
  int _clientChannelCount = 0;

  // Actual WASAPI format
  int _finalSampleRate = 0;

  // WASAPI buffer
  int _bufferFrameCount = 0;
  bool _isInitialized = false;
  bool _isPlaying = false;

  // Event handling
  int? _eventHandle;
  Isolate? _eventIsolate;
  final _stopWorkerMessage = Object();
  bool _didCoInitialize = false;

  // If we've called feed callback once below threshold, avoid spamming
  bool _didInvokeFeedCallback = false;

  // -----------------------------------------------------------
  //  Logging + WASAPI error checking
  // -----------------------------------------------------------
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

  void check(int hr, [String? operation]) {
    if (FAILED(hr)) {
      final error = WindowsException(hr);
      _logError('${operation ?? "Operation"} failed: $error (0x${hr.toRadixString(16)})');
      throw error;
    }
  }

  // -----------------------------------------------------------
  //  FlutterPcmSoundImpl interface
  // -----------------------------------------------------------
  @override
  Future<void> setLogLevel(LogLevel level) async {
    _logLevel = level;
  }

  @override
  void setFeedCallback(Function(int framesRemaining)? callback) {
    FlutterPcmSound.onFeedSamplesCallback = callback;
    if (callback != null) {
      _log('Feed callback set.');
    } else {
      _log('Feed callback cleared.');
    }
  }

  @override
  Future<void> setFeedThreshold(int threshold) async {
    _feedThreshold = threshold;
    _log('Feed threshold set to $_feedThreshold frames');
  }

  @override
  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    IosAudioCategory iosAudioCategory = IosAudioCategory.playback,
  }) async {
    try {
      _log('Initializing WASAPI: sampleRate=$sampleRate, channels=$channelCount');
      _clientSampleRate = sampleRate;
      _clientChannelCount = channelCount;

      // COM init
      final hrCoInit = CoInitializeEx(nullptr, COINIT.COINIT_APARTMENTTHREADED);
      if (!FAILED(hrCoInit)) {
        _didCoInitialize = true;
      } else if (hrCoInit != RPC_E_CHANGED_MODE) {
        throw WindowsException(hrCoInit);
      }

      // Device
      final pDeviceEnumerator = MMDeviceEnumerator.createInstance();
      final ppDevice = calloc<COMObject>();
      check(
        pDeviceEnumerator.getDefaultAudioEndpoint(EDataFlow.eRender, ERole.eConsole, ppDevice.cast()),
        'Get default audio endpoint'
      );
      final pDevice = IMMDevice(ppDevice);

      // Audio client
      final iidAudioClient = convertToIID(IID_IAudioClient3);
      final ppAudioClient = calloc<COMObject>();
      check(
        pDevice.activate(iidAudioClient, CLSCTX.CLSCTX_ALL, nullptr, ppAudioClient.cast()),
        'Activate audio client'
      );
      free(iidAudioClient);
      _audioClient = IAudioClient3(ppAudioClient);

      // Client props
      final props = calloc<AudioClientProperties>();
      props.ref
        ..cbSize = sizeOf<AudioClientProperties>()
        ..bIsOffload = 0
        ..eCategory = 3 // communications
        ..Options = AUDCLNT_STREAMOPTIONS.AUDCLNT_STREAMOPTIONS_MATCH_FORMAT;
      check(_audioClient!.setClientProperties(props), 'Set client properties');
      free(props);

      // Mix format
      final ppMixFormat = calloc<Pointer<WAVEFORMATEX>>();
      check(_audioClient!.getMixFormat(ppMixFormat), 'getMixFormat');
      final pMixFormat = ppMixFormat.value;
      _finalSampleRate = pMixFormat.ref.nSamplesPerSec;
      _log('System Mix Format: '
          '${pMixFormat.ref.nSamplesPerSec} Hz, '
          '${pMixFormat.ref.nChannels} channels, '
          '${pMixFormat.ref.wBitsPerSample}-bit');

      // Desired wave format
      final pWaveFormat = calloc<WAVEFORMATEX>();
      pWaveFormat.ref
        ..wFormatTag = WAVE_FORMAT_PCM
        ..nChannels = channelCount
        ..nSamplesPerSec = sampleRate
        ..wBitsPerSample = 16
        ..nBlockAlign = (16 * channelCount) ~/ 8
        ..nAvgBytesPerSec = sampleRate * ((16 * channelCount) ~/ 8)
        ..cbSize = 0;

      final pClosestMatch = calloc<Pointer<WAVEFORMATEX>>();
      final hr = _audioClient!.isFormatSupported(
        AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
        pWaveFormat,
        pClosestMatch
      );

      Pointer<WAVEFORMATEX> formatToUse;
      if (hr == S_OK) {
        _log('Requested format is directly supported');
        formatToUse = pWaveFormat;
      } else if (hr == S_FALSE && pClosestMatch.value != nullptr) {
        _log('Using closest supported format');
        formatToUse = pClosestMatch.value;
      } else {
        _log('Using system mix format fallback');
        formatToUse = pMixFormat;
      }

      // Create event handle
      _eventHandle = CreateEventEx(nullptr, nullptr, 0, 0x00100002 /* EVENT_MODIFY_STATE_SYNCHRONIZE */);
      if (_eventHandle == 0 || _eventHandle == null) {
        final le = GetLastError();
        final hrErr = HRESULT_FROM_WIN32(le);
        throw WindowsException(hrErr);
      }

      // Initialize audio client in event-driven mode
      final bufferDuration = 2000 * 10000; // 2 seconds in 100-ns
      check(
              _audioClient!.initialize(
              AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
              0x80000000 | 0x08000000 | 0x00040000,
              /*  
              AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
              AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
              AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
              */
              bufferDuration,
              0,
              formatToUse,
              nullptr),
        'Initialize audio client'
      );

      // Set the event handle
      check(_audioClient!.setEventHandle(_eventHandle!), 'Set event handle');

      // Start the isolate
      _startEventIsolate();

      // Get the buffer size
      final pBufferCount = calloc<UINT32>();
      check(_audioClient!.getBufferSize(pBufferCount), 'getBufferSize');
      _bufferFrameCount = pBufferCount.value;
      free(pBufferCount);
      _log('Buffer frame count: $_bufferFrameCount');

      // Render client
      final iidAudioRenderClient = convertToIID(IID_IAudioRenderClient);
      final ppRenderClient = calloc<COMObject>();
      check(
        _audioClient!.getService(iidAudioRenderClient, ppRenderClient.cast()),
        'Get render client'
      );
      free(iidAudioRenderClient);
      _renderClient = IAudioRenderClient(ppRenderClient);

      // Cleanup wave format data
      CoTaskMemFree(ppMixFormat.value.cast());
      free(ppMixFormat);
      free(pWaveFormat);

      _isInitialized = true;
      _log('WASAPI initialization complete');
    } catch (e) {
      _logError('Setup failed: $e');
      await release();
      rethrow;
    }
  }

  @override
  Future<void> feed(PcmArrayInt16 buffer) async {
    if (!_isInitialized) {
      _logError('Cannot feed: not initialized');
      return;
    }

    // Convert the input to Int16
    final inputSamples = buffer.bytes.buffer.asInt16List();

    // If needed, upsample 24k->48k
    Int16List upsampled;
    if (_clientSampleRate == 24000 && _finalSampleRate == 48000) {
      upsampled = Int16List(inputSamples.length * 2);
      for (int i = 0; i < inputSamples.length; i++) {
        final s = inputSamples[i];
        upsampled[i * 2] = s;
        upsampled[i * 2 + 1] = s;
      }
    } else {
      upsampled = inputSamples;
    }

    // Duplicate for stereo if needed
    Int16List finalData;
    if (_clientChannelCount == 2) {
      finalData = Int16List(upsampled.length * 2);
      for (int i = 0; i < upsampled.length; i++) {
        final s = upsampled[i];
        finalData[i * 2] = s;     // left
        finalData[i * 2 + 1] = s; // right
      }
    } else {
      finalData = upsampled;
    }

    // Append to internal buffer
    _samples.addAll(finalData);

    // If not playing, start the audio client
    if (!_isPlaying && _audioClient != null) {
      final hr = _audioClient!.start();
      if (SUCCEEDED(hr)) {
        _isPlaying = true;
        _logVerbose('Audio client started due to new feed data.');
      } else {
        _logError('Audio client failed to start: 0x${hr.toRadixString(16)}');
      }
    }

    // Attempt to fill the WASAPI buffer right now in case there's space
    // (Approach B: immediate fill)
    _tryFillNow();
  }

  @override
  Future<void> release() async {
    _log('Releasing resources');
    await _stopEventIsolate();

    if (_audioClient != null) {
      try {
        _audioClient!.stop();
      } catch (e) {
        _logError('Error stopping audio client: $e');
      }
      _audioClient = null;
    }
    _renderClient = null;

    _isInitialized = false;
    _isPlaying = false;
    _samples.clear();

    if (_didCoInitialize) {
      CoUninitialize();
      _didCoInitialize = false;
      _log('COM uninitialized.');
    }

    _log('Resources released');
  }

  @override
  void start() {
    // If you want a "manual start," you can call onFeedSamplesCallback
    // or just rely on feed() to start the audio client automatically.
    FlutterPcmSound.onFeedSamplesCallback?.call(0);
  }

  // -----------------------------------------------------------
  //  Attempt to fill WASAPI now, in case the user just fed data
  // -----------------------------------------------------------
  void _tryFillNow() {
    if (!_isInitialized || !_isPlaying || _renderClient == null) return;

    // We'll do a "while space remains" loop to fill as much as possible
    while (true) {
      final pPadding = calloc<UINT32>();
      final hrPad = _audioClient!.getCurrentPadding(pPadding);
      if (FAILED(hrPad)) {
        free(pPadding);
        return;
      }
      final framesInBuffer = pPadding.value;
      free(pPadding);

      final framesAvailable = _bufferFrameCount - framesInBuffer;
      if (framesAvailable <= 0) break;

      final framesInQueue = _samples.length ~/ _clientChannelCount;
      if (framesInQueue == 0) break;

      final framesToCopy = (framesInQueue < framesAvailable)
          ? framesInQueue
          : framesAvailable;

      final pData = calloc<Pointer<Int16>>();
      final hrGet = _renderClient!.getBuffer(framesToCopy, pData.cast());
      if (!SUCCEEDED(hrGet)) {
        free(pData);
        break;
      }

      final totalSamples = framesToCopy * _clientChannelCount;
      final dst = pData.value.asTypedList(totalSamples);
      for (int i = 0; i < totalSamples; i++) {
        dst[i] = _samples[i];
      }
      check(_renderClient!.releaseBuffer(framesToCopy, 0), 'releaseBuffer');
      _samples.removeRange(0, totalSamples);

      free(pData);
    }

    // If after filling, framesRemaining < threshold => feed callback
    final framesRemaining = _samples.length ~/ _clientChannelCount;
    if (framesRemaining <= _feedThreshold) {
      if (!_didInvokeFeedCallback) {
        _log('Invoking feed callback, framesRemaining=$framesRemaining');
        FlutterPcmSound.onFeedSamplesCallback?.call(framesRemaining);
        _didInvokeFeedCallback = true;
      }
    } else {
      _didInvokeFeedCallback = false;
    }
  }

  // -----------------------------------------------------------
  //  Worker isolate: event signaled => we try to fill again
  // -----------------------------------------------------------
  void _startEventIsolate() async {
    if (_eventHandle == null) return;
    final rp = ReceivePort();
    _eventIsolate = await Isolate.spawn<_EventIsolateParams>(
      _eventIsolateEntry,
      _EventIsolateParams(
        sendPort: rp.sendPort,
        eventHandle: _eventHandle!,
        stopMessage: _stopWorkerMessage,
      ),
      debugName: 'PCM-WASAPI-EventIsolate',
    );

    rp.listen((msg) async {
      if (msg == null) return;
      if (msg == _stopWorkerMessage) {
        _eventIsolate = null;
        return;
      }
      if (msg is String && msg == 'event_signaled') {
        // Approach A: multi-pass fill
        _tryFillNow();
      }
    });
  }

  Future<void> _stopEventIsolate() async {
    if (_eventHandle != null) {
      CloseHandle(_eventHandle!);
      _eventHandle = null;
    }
    _eventIsolate?.kill(priority: Isolate.immediate);
    _eventIsolate = null;
  }
}

// Data for the isolate
class _EventIsolateParams {
  final SendPort sendPort;
  final int eventHandle;
  final Object stopMessage;
  _EventIsolateParams({
    required this.sendPort,
    required this.eventHandle,
    required this.stopMessage,
  });
}

// The isolate entry: wait on the event handle
void _eventIsolateEntry(_EventIsolateParams params) {
  final sp = params.sendPort;
  final handle = params.eventHandle;
  final stopMsg = params.stopMessage;

  while (true) {
    final result = WaitForSingleObject(handle, INFINITE);
    if (result == 0xffffffff /* WAIT_FAILED */) {
      break;
    }
    if (result == 0 /* WAIT_OBJECT_0 */) {
      sp.send('event_signaled');
    }
  }
  sp.send(stopMsg);
}
