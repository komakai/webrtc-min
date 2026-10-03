# Builds WebRTC's Android library, libjingle_peerconnection_so.so, from the
# webrtc (webrtc-src-min) and third_party (webrtc-third_party-min) submodules.
#
#   cmake -B out/arm64 -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=23
#   ninja -C out/arm64 jingle_peerconnection_so
cmake_minimum_required(VERSION 3.22)
project(webrtc_min C CXX ASM)

option(WEBRTC_MIN "Build only the third-party code WebRTC uses" ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# The code-generation flags of Chromium's //build configs for a release
# Android build (its warning flags are left out). Optimization is -O2, as in
# gn; a few libraries add -O3 where their BUILD.gn asks for optimize_speed.
set(CMAKE_C_FLAGS_RELEASE "-O2")
set(CMAKE_CXX_FLAGS_RELEASE "-O2")
add_compile_definitions(
  NDEBUG
  NVALGRIND
  DYNAMIC_ANNOTATIONS_ENABLED=0
  _GNU_SOURCE
  HAVE_SYS_UIO_H
  __STDC_CONSTANT_MACROS
  __STDC_FORMAT_MACROS
  _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE
  __ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__
)
# (Not for NASM, which takes different options.)
set(common_flags
  -ffunction-sections
  -fdata-sections
  -fno-strict-aliasing
  -fno-delete-null-pointer-checks
  -fno-strict-overflow
  -fno-math-errno
  -fmerge-all-constants
  -ffp-contract=off
  -fno-short-enums
  -fstack-protector
  -funwind-tables
  -ftrivial-auto-var-init=pattern
)
add_compile_options(
  "$<$<COMPILE_LANGUAGE:C,CXX,ASM>:${common_flags}>"
  "$<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions;-fno-rtti>"
)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)")
  add_compile_options("$<$<COMPILE_LANGUAGE:C,CXX,ASM>:-mbranch-protection=standard>")
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm)")
  add_compile_definitions(__ARM_NEON__=1)
endif()

add_subdirectory(third_party)
add_subdirectory(webrtc)
