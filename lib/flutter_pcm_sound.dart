import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';

import 'flutter_pcm_sound_windows.dart';

enum LogLevel {
  none,
  error,
  standard,
  verbose,
}

enum IosAudioCategory {
  soloAmbient,
  ambient,
  playback,
  playAndRecord,
}

class FlutterPcmSound {
  static const MethodChannel _channel = MethodChannel('flutter_pcm_sound/methods');
  static late final dynamic _platformImplementation = _getPlatformImplementation();

  static Function(int)? onFeedSamplesCallback;

  static LogLevel _logLevel = LogLevel.standard;

  /// Determines which platform implementation to use
  static dynamic _getPlatformImplementation() {
    if (Platform.isWindows) {
      return FlutterPcmSoundWindows();
    }
    return FlutterPcmSound(); // Default to the existing implementation
  }

  /// Set log level
  static Future<void> setLogLevel(LogLevel level) async {
    _logLevel = level;
    await _platformImplementation.setLogLevel(level);
  }

  /// Setup audio
  static Future<void> setup({
    required int sampleRate,
    required int channelCount,
    IosAudioCategory iosAudioCategory = IosAudioCategory.playback,
  }) async {
    await _platformImplementation.setup(
      sampleRate: sampleRate,
      channelCount: channelCount,
      iosAudioCategory: iosAudioCategory,
    );
  }

  /// Feed PCM data
  static Future<void> feed(PcmArrayInt16 buffer) async {
    await _platformImplementation.feed(buffer.bytes.buffer.asUint8List());
  }

  /// Set feed threshold
  static Future<void> setFeedThreshold(int threshold) async {
    await _platformImplementation.setFeedThreshold(threshold);
  }

  /// Set feed callback
  static void setFeedCallback(Function(int)? callback) {
    onFeedSamplesCallback = callback;
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  /// Start callback
  static void start() {
    assert(onFeedSamplesCallback != null);
    onFeedSamplesCallback!(0);
  }

  /// Release resources
  static Future<void> release() async {
    await _platformImplementation.release();
  }
  
  static Future<dynamic> _methodCallHandler(MethodCall call) async {
    if (_logLevel.index >= LogLevel.standard.index) {
      String func = '[[ ${call.method} ]]';
      String args = call.arguments.toString();
      print("[PCM] $func $args");
    }
    switch (call.method) {
      case 'OnFeedSamples':
        int remainingFrames = call.arguments["remaining_frames"];
        if (onFeedSamplesCallback != null) {
          onFeedSamplesCallback!(remainingFrames);
        }
        break;
      default:
        print('Method not implemented');
    }
  }
}


class PcmArrayInt16 {
  final ByteData bytes;

  PcmArrayInt16({required this.bytes});

  factory PcmArrayInt16.zeros({required int count}) {
    Uint8List list = Uint8List(count * 2);
    return PcmArrayInt16(bytes: list.buffer.asByteData());
  }

  factory PcmArrayInt16.empty() {
    return PcmArrayInt16.zeros(count: 0);
  }

  factory PcmArrayInt16.fromList(List<int> list) {
    var byteData = ByteData(list.length * 2);
    for (int i = 0; i < list.length; i++) {
      byteData.setInt16(i * 2, list[i], Endian.host);
    }
    return PcmArrayInt16(bytes: byteData);
  }

  operator [](int idx) {
    int vv = bytes.getInt16(idx * 2, Endian.host);
    return vv;
  }

  operator []=(int idx, int value) {
    return bytes.setInt16(idx * 2, value, Endian.host);
  }
}

// for testing
class MajorScale {
  int _periodCount = 0;
  int sampleRate = 44100;
  double noteDuration = 0.25;

  MajorScale({required this.sampleRate, required this.noteDuration});

  // C Major Scale (Just Intonation)
  List<double> get scale {
    List<double> c = [261.63, 294.33, 327.03, 348.83, 392.44, 436.05, 490.55, 523.25];
    return [c[0]] + c + c.reversed.toList().sublist(0, c.length - 1);
  }

  // total periods needed to play the entire note
  int _periodsForNote(double freq) {
    int nFramesPerPeriod = (sampleRate / freq).round();
    int totalFramesForDuration = (noteDuration * sampleRate).round();
    return totalFramesForDuration ~/ nFramesPerPeriod;
  }

  // total periods needed to play the whole scale
  int get _periodsForScale {
    int total = 0;
    for (double freq in scale) {
      total += _periodsForNote(freq);
    }
    return total;
  }

  // what note are we currently playing
  int get noteIdx {
    int accum = 0;
    for (int n = 0; n < scale.length; n++) {
      accum += _periodsForNote(scale[n]);
      if (_periodCount < accum) {
        return n;
      }
    }
    return scale.length - 1;
  }

  // generate a sine wave
  List<int> cosineWave({int periods = 1, int sampleRate = 44100, double freq = 440, double volume = 0.5}) {
    final period = 1.0 / freq;
    final nFramesPerPeriod = (period * sampleRate).toInt();
    final totalFrames = nFramesPerPeriod * periods;
    final step = math.pi * 2 / nFramesPerPeriod;
    List<int> data = List.filled(totalFrames, 0);
    for (int i = 0; i < totalFrames; i++) {
      data[i] = (math.cos(step * (i % nFramesPerPeriod)) * volume * 32768).toInt() - 16384;
    }
    return data;
  }

  void reset() {
    _periodCount = 0;
  }

  // generate the next X periods of the major scale
  List<int> generate({required int periods, double volume = 0.5}) {
    List<int> frames = [];
    for (int i = 0; i < periods; i++) {
      _periodCount %= _periodsForScale;
      frames += cosineWave(periods: 1, sampleRate: sampleRate, freq: scale[noteIdx], volume: volume);
      _periodCount++;
    }
    return frames;
  }
}
