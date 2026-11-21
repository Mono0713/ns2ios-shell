# oodle_serve: see oodle_serve.cpp. Built for Windows by .github/workflows/shell.yml (the packer's tools); on Linux / macOS:
#   cmake -S dm/tools/oodle_serve -B build/oodle_serve && cmake --build build/oodle_serve --config Release
cmake_minimum_required(VERSION 3.10)
project(oodle_serve CXX)
set(CMAKE_CXX_STANDARD 11)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()
add_executable(oodle_serve oodle_serve.cpp ooz/kraken.cpp ooz/lzna.cpp ooz/bitknit.cpp)
if(MSVC)
  # one self-contained .exe: no Visual C++ runtime to install on the user's PC
  set_property(TARGET oodle_serve PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
  target_compile_options(oodle_serve PRIVATE /O2 /W1)
else()
  target_compile_options(oodle_serve PRIVATE -O2 -w -msse4.1)
endif()
