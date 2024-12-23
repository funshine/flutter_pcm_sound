export 'flutter_pcm_sound.dart';

// Conditional export based on platform
export 'flutter_pcm_sound_windows_stub.dart'
    if (dart.library.ffi) 'flutter_pcm_sound_windows_real.dart';