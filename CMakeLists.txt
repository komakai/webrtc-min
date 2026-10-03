# Builds WebRTC's Android library, libjingle_peerconnection_so.so, or its iOS
# framework, WebRTC.framework, from the webrtc (webrtc-src-min) and third_party
# (webrtc-third_party-min) submodules.
#
#   cmake -B out/arm64 -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
#     -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=23
#   ninja -C out/arm64 jingle_peerconnection_so
#
#   cmake -B out/ios-arm64 -G Ninja -DCMAKE_SYSTEM_NAME=iOS \
#     -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
#   ninja -C out/ios-arm64 WebRTC
cmake_minimum_required(VERSION 3.22)
project(webrtc_min C CXX ASM)

# WEBRTC_MIN: build only the third-party files WebRTC links (see
# third_party/RECIPE.md), instead of the libraries' full source lists. Taken
# from the WEBRTC_MIN environment variable (set and not 0/OFF/NO/FALSE means
# on) unless -DWEBRTC_MIN=ON/OFF is given.
if(NOT DEFINED WEBRTC_MIN)
  if(DEFINED ENV{WEBRTC_MIN} AND NOT "$ENV{WEBRTC_MIN}" MATCHES "^(|0|[Oo][Ff][Ff]|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee])$")
    set(WEBRTC_MIN ON)
  else()
    set(WEBRTC_MIN OFF)
  endif()
endif()
message(STATUS "WEBRTC_MIN: ${WEBRTC_MIN}")

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
set(CMAKE_OBJC_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# The code-generation flags of Chromium's //build configs for a release
# Android or iOS build (its warning flags are left out). Optimization is -O2, as in
# gn; a few libraries add -O3 where their BUILD.gn asks for optimize_speed.
set(CMAKE_C_FLAGS_RELEASE "-O2")
set(CMAKE_CXX_FLAGS_RELEASE "-O2")
set(CMAKE_OBJC_FLAGS_RELEASE "-O2")
set(CMAKE_OBJCXX_FLAGS_RELEASE "-O2")
if(ANDROID)
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
elseif(APPLE)
  enable_language(OBJC OBJCXX)
  add_compile_definitions(
    NDEBUG
    NVALGRIND
    DYNAMIC_ANNOTATIONS_ENABLED=0
    __STDC_CONSTANT_MACROS
    __STDC_FORMAT_MACROS
    _LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE
    NS_BLOCK_ASSERTIONS=1
    ABSL_ALLOCATOR_NOTHROW=1
  )
  set(common_flags
    -fno-strict-aliasing
    -fno-delete-null-pointer-checks
    -fno-strict-overflow
    -fno-math-errno
    -fmerge-all-constants
    -ffp-contract=off
    -fstack-protector
    -ftrivial-auto-var-init=pattern
  )
endif()
add_compile_options(
  "$<$<COMPILE_LANGUAGE:C,CXX,ASM,OBJC,OBJCXX>:${common_flags}>"
  "$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-fno-exceptions;-fno-rtti>"
)
if(ANDROID AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)")
  add_compile_options("$<$<COMPILE_LANGUAGE:C,CXX,ASM>:-mbranch-protection=standard>")
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm)")
  add_compile_definitions(__ARM_NEON__=1)
endif()

if(IOS)
  # One architecture per build, like gn; xcframeworks combine the builds.
  # CMake leaves CMAKE_SYSTEM_PROCESSOR at the host's for iOS, so set it from
  # the architecture for the CPU checks in the subdirectories.
  list(LENGTH CMAKE_OSX_ARCHITECTURES n)
  if(NOT n EQUAL 1)
    message(FATAL_ERROR "Set CMAKE_OSX_ARCHITECTURES to one architecture (arm64 or x86_64)")
  endif()
  set(CMAKE_SYSTEM_PROCESSOR ${CMAKE_OSX_ARCHITECTURES})
endif()

add_subdirectory(third_party)
add_subdirectory(webrtc)
