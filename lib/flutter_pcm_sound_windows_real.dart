import 'dart:ffi';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math' as math;
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
  // rationale: nice to store it, and the current implementation
  // is a bit hacky in that it assumes the only use cases are 24/48 kHz
  // single channel audio, i.e. OpenAI realtime voice synthesis.
  // ignore: unused_field
  int _clientChannelCount = 0;
  CircularAudioBuffer? _circularBuffer;


  // System format (what WASAPI wants)
  int _finalSampleRate = 0;

  // Buffer management
  int _bufferFrameCount = 0;
  bool _isInitialized = false;
  int? _eventHandle;
  StreamSubscription? _eventSubscription;
  
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

  Future<void> _handleAudioEvent() async {
  if (!_isInitialized) return;
  
  try {
    final pNumFramesPadding = calloc<UINT32>();
    check(_audioClient!.getCurrentPadding(pNumFramesPadding));
    final numFramesAvailable = _bufferFrameCount - pNumFramesPadding.value;
    var wasapiBufferMs = (pNumFramesPadding.value * 1000) ~/ _clientSampleRate;
    free(pNumFramesPadding);
    
    if (numFramesAvailable > 0 && _circularBuffer!.available > 0) {
      final readBuffer = Int16List(numFramesAvailable);
      final framesRead = _circularBuffer!.read(readBuffer, numFramesAvailable);
      
      if (framesRead > 0) {
        wasapiBufferMs += (framesRead * 1000) ~/ _clientSampleRate;
        
        final Float32List stereoData = Float32List(framesRead * 2);
        for (int i = 0; i < framesRead; i++) {
          final float = readBuffer[i] / 32768.0;
          stereoData[i * 2] = float;
          stereoData[i * 2 + 1] = float;
        }

        final pData = calloc<Pointer<Float>>();
        check(_renderClient!.getBuffer(framesRead, pData.cast()));
        final dst = pData.value.asTypedList(framesRead * 2);
        dst.setRange(0, framesRead * 2, stereoData);
        check(_renderClient!.releaseBuffer(framesRead, 0));
        _logVerbose('Copied $framesRead frames from circular buffer to WASAPI buffer');
        free(pData);
      }
    }

    if (_circularBuffer!.available < _feedThreshold && 
        wasapiBufferMs < _feedThreshold &&
        FlutterPcmSound.onFeedSamplesCallback != null) {
      FlutterPcmSound.onFeedSamplesCallback!(_circularBuffer!.available);
    }
  } catch (e) {
    _logError('Buffer handling failed: $e');
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
      // 25-01-25: Went from 1 MB to 10 MB after hearing skipping around 20 
      // seconds. Tested it worked via Edgar Allan Poe's The Raven.
      _circularBuffer = CircularAudioBuffer(10048576);


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
      
      // Store system format for potential upsampling later
      _finalSampleRate = pMixFormat.ref.nSamplesPerSec;
      
      _log('System Mix Format: ${pMixFormat.ref.nSamplesPerSec} Hz, ${pMixFormat.ref.nChannels} channels, ${pMixFormat.ref.wBitsPerSample}-bit');

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

      // Create event handle for notifications
      _eventHandle = CreateEventEx(
        nullptr,
        nullptr,
        0,
        // https://learn.microsoft.com/en-us/windows/win32/sync/synchronization-object-security-and-access-rights
        0x1F0003 /* EVENT_ALL_ACCESS */, 
      );
      if (_eventHandle == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }

      // Initialize audio client with event notifications
      // 25-01-25: Went from 2 sec to 30 sec after hearing skipping around 20 
      // seconds. Tested it worked via Edgar Allan Poe's The Raven.
      // n.b. this *probably* wasn't required: i.e. the circular buffer should
      // be defending against this, so the capacity increase in it from 1 MB to
      // 10 MB is probably what fixed the skipping.
      final bufferDuration = 30000 * 10000; // 30 seconds in 100-ns units
      check(
          _audioClient!.initialize(
              AUDCLNT_SHAREMODE.AUDCLNT_SHAREMODE_SHARED,
              0x80000000 | 0x08000000 | 0x00040000, // Add AUDCLNT_STREAMFLAGS_EVENTCALLBACK
              bufferDuration,
              0,
              formatToUse,
              nullptr),
          'Initialize audio client');

      // Set the event handle
      check(_audioClient!.setEventHandle(_eventHandle!),
          'Set event handle');

      // Start listening for events
      _startEventHandling();

      // Get buffer size
      final pBufferFrameCount = calloc<UINT32>();
      check(_audioClient!.getBufferSize(pBufferFrameCount), 'Get buffer size');
      _bufferFrameCount = pBufferFrameCount.value;
      free(pBufferFrameCount);

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
      free(pWaveFormat);

      _isInitialized = true;
      _log('WASAPI initialization complete');
    } catch (e) {
      _logError('Setup failed: $e');
      await release();
      rethrow;
    }
  }

  void _startEventHandling() {
    _eventSubscription = Stream.periodic(const Duration(milliseconds: 1)).listen((_) async {
      final result = WaitForSingleObject(_eventHandle!, 0);
      // WAIT_OBJECT_0 == 0x00000000L
      if (result == 0) {
        await _handleAudioEvent();
      }
    });
  }
  
  Future<void> _stopEventHandling() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    if (_eventHandle != null) {
      CloseHandle(_eventHandle!);
      _eventHandle = null;
    }
  }
  
Future<void> feed(PcmArrayInt16 buffer) async {
  if (!_isInitialized) return;
  
  final inputSamples = buffer.bytes.buffer.asInt16List();
  // Handle 24kHz -> 48kHz upsampling if needed
  Int16List dataToWrite;
  if (_clientSampleRate == 24000 && _finalSampleRate == 48000) {
    dataToWrite = Int16List(inputSamples.length * 2);
    for (int i = 0; i < inputSamples.length; i++) {
      dataToWrite[i * 2] = inputSamples[i];
      dataToWrite[i * 2 + 1] = inputSamples[i];
    }
  } else {
    dataToWrite = inputSamples;
  }
  
  final written = _circularBuffer!.write(dataToWrite);
  if (written < dataToWrite.length) {
    _logError('Buffer overflow - dropped ${dataToWrite.length - written} samples');
  }
}

  Future<void> setFeedThreshold(int threshold) async {
    _feedThreshold = threshold;
    _log('Feed threshold set to $_feedThreshold frames');
  }

  Future<void> release() async {
    _log('Releasing resources');
  
    await _stopEventHandling();

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
    FlutterPcmSound.onFeedSamplesCallback = callback;
  }

  @override
  void start() {
    FlutterPcmSound.onFeedSamplesCallback?.call(0);
  }
}

class CircularAudioBuffer {
  final Int16List _buffer;
  int _writePos = 0;
  int _readPos = 0;
  int _available = 0;
  final int _capacity;

  CircularAudioBuffer(this._capacity) : _buffer = Int16List(_capacity);

  int write(Int16List data) {
    final toWrite = math.min(data.length, _capacity - _available);
    for (var i = 0; i < toWrite; i++) {
      _buffer[_writePos] = data[i];
      _writePos = (_writePos + 1) % _capacity;
    }
    _available += toWrite;
    return toWrite;
  }

  int read(Int16List dest, int count) {
    final toRead = math.min(count, _available);
    for (var i = 0; i < toRead; i++) {
      dest[i] = _buffer[_readPos];
      _readPos = (_readPos + 1) % _capacity;
    }
    _available -= toRead;
    return toRead;
  }

  int get available => _available;
  int get free => _capacity - _available;
}