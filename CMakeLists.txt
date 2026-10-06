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

# With WEBRTC_IOS_SLICES (a list of environment:architecture, e.g.
# "device:arm64;simulator:arm64;simulator:x86_64"), this project builds only
# WebRTC.xcframework: each slice is a sub-build of this source tree for one
# SDK and architecture, with the same generator (so with -G Xcode, each is an
# Xcode project under slices/), and the WebRTC_xcframework target builds them
# all and combines their frameworks:
#
#   cmake -B out/ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
#     "-DWEBRTC_IOS_SLICES=device:arm64;simulator:arm64;simulator:x86_64"
#   xcodebuild -project out/ios/webrtc_min.xcodeproj -target WebRTC_xcframework
#     # -> out/ios/WebRTC.xcframework
if(IOS AND WEBRTC_IOS_SLICES)
  include(ExternalProject)
  if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
  endif()
  # The slices are configured and built from inside this project's build
  # (e.g. by Xcode), whose environment (SDKROOT, ARCHS, ...) would break their
  # compiler detection, so they get a clean one.
  set(clean_env /usr/bin/env -i "PATH=$ENV{PATH}" "HOME=$ENV{HOME}")
  if(DEFINED ENV{DEVELOPER_DIR})
    list(APPEND clean_env "DEVELOPER_DIR=$ENV{DEVELOPER_DIR}")
  endif()
  set(slice_targets)
  set(slice_dirs)
  foreach(slice IN LISTS WEBRTC_IOS_SLICES)
    if(NOT slice MATCHES "^(device|simulator):(arm64|x86_64)$")
      message(FATAL_ERROR "WEBRTC_IOS_SLICES: unknown slice ${slice}; use "
        "device:arm64, simulator:arm64 or simulator:x86_64")
    endif()
    set(environment ${CMAKE_MATCH_1})
    set(arch ${CMAKE_MATCH_2})
    if(environment STREQUAL "device")
      set(sdk iphoneos)
    else()
      set(sdk iphonesimulator)
    endif()
    set(dir ${CMAKE_CURRENT_BINARY_DIR}/slices/${environment}_${arch})
    ExternalProject_Add(webrtc_${environment}_${arch}
      SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}
      BINARY_DIR ${dir}
      CONFIGURE_COMMAND ${clean_env} ${CMAKE_COMMAND}
        -S ${CMAKE_CURRENT_SOURCE_DIR} -B ${dir} -G ${CMAKE_GENERATOR}
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_SYSROOT=${sdk}
        -DCMAKE_OSX_ARCHITECTURES=${arch}
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_CONFIGURATION_TYPES=Release
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
        -DWEBRTC_MIN=${WEBRTC_MIN}
      BUILD_COMMAND ${clean_env} ${CMAKE_COMMAND}
        --build ${dir} --config Release --target WebRTC
      INSTALL_COMMAND ""
      BUILD_ALWAYS ON
      USES_TERMINAL_BUILD ON
    )
    list(APPEND slice_targets webrtc_${environment}_${arch})
    list(APPEND slice_dirs ${environment}=${dir})
  endforeach()
  string(REPLACE ";" "|" slice_dirs "${slice_dirs}")
  add_custom_target(WebRTC_xcframework ALL
    COMMAND ${CMAKE_COMMAND}
      -DOUTPUT=${CMAKE_CURRENT_BINARY_DIR}/WebRTC.xcframework
      -DSLICES=${slice_dirs}
      -P ${CMAKE_CURRENT_SOURCE_DIR}/ios/ios_xcframework.cmake
    DEPENDS ${slice_targets}
    COMMENT "Creating WebRTC.xcframework"
    VERBATIM
  )
  return()
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
