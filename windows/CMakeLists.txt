cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_pcm_sound")
project(${PROJECT_NAME} LANGUAGES CXX)
# per just_audio_windows
set(CPPWINRT_VERSION 2.0.210806.1)
set(CMAKE_CXX_STANDARD 17)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_pcm_sound_plugin")

# Plugin sources
add_library(${PLUGIN_NAME} SHARED
  "flutter_pcm_sound_plugin.cpp"
  "flutter_pcm_sound_plugin.h"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_pcm_sound_bundled_libraries
  ""
  PARENT_SCOPE
)