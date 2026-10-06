# webrtc-min

Builds WebRTC's `libjingle_peerconnection_so.so` for Android and
`WebRTC.framework` for iOS without depot_tools, gclient or the multi-gigabyte
Chromium dependency set.

## Android with CMake

The `webrtc` and `third_party` submodules are trimmed forks of WebRTC and of
the Chromium libraries it uses (~90 MB checked out), each with plain CMake
files in place of gn. Every fork's `main-min` branch starts from an upstream
snapshot, and its `RECIPE.md` lists what was removed and changed.

```sh
git clone --recursive https://github.com/komakai/webrtc-min.git
cd webrtc-min
cmake -B out/arm64 -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=23
ninja -C out/arm64 jingle_peerconnection_so   # -> out/arm64/webrtc/sdk/libjingle_peerconnection_so.so
```

Requirements: CMake 3.22+, Ninja and an Android NDK (r30, as WebRTC's DEPS
pins). arm64-v8a, armeabi-v7a, x86 and x86_64 all build.

This build matches the gn one (`gn/README.md`) with both its options off: no software video
codecs (video uses MediaCodec) and no protobuf. On arm64 it exports the same
JNI symbols as gn's library, and the stripped size is within 1%. The generated
JNI headers are checked in, so the build needs no python or JDK; regenerating
them (see `webrtc/RECIPE.md`) still uses the gn build. The compile flags
follow Chromium's release config for Android, minus its warning flags,
`-Werror`, debug-info flags and the `-fsanitize=...`/`-fsanitize-trap=...`
hardening checks (array bounds, return, unreachable).

Set the environment variable `WEBRTC_MIN` (e.g. `WEBRTC_MIN=1 cmake -B ...`)
to compile only the third-party files WebRTC links: Abseil, BoringSSL, libyuv,
Opus and sframe without the files no WebRTC build loads (about 220 fewer files
on Android, 100 on iOS). The library is the same size
with the same exports; `third_party/RECIPE.md` has how the lists were made and
checked. `-DWEBRTC_MIN=ON/OFF` overrides the variable.

## Android AAR with Gradle

`android/` is a Gradle project (Kotlin DSL) that builds `webrtc.aar`: the
Java API from `webrtc/sdk/android` (the classes of gn's `libwebrtc` jar,
without the software video codecs') and `libjingle_peerconnection_so.so` for
each ABI, which the Android Gradle plugin builds with the CMake build above
(with `WEBRTC_MIN`).

```sh
cd android
ANDROID_NDK_HOME=/path/to/android-ndk-r30 ./gradlew :webrtc:assembleRelease
# -> webrtc/build/outputs/aar/webrtc-release.aar
```

Requirements: JDK 17+, an Android SDK with platform 36 (`ANDROID_HOME` or
`sdk.dir` in `android/local.properties`), the r30 NDK (in the SDK, or
`ANDROID_NDK_HOME`), and CMake 3.22+ with Ninja: the SDK's CMake package, or
another one named by `cmake.dir` in `local.properties` (e.g. `cmake.dir=/usr`).
It builds `arm64-v8a` by default however it is possible to configure by
setting `webrtc.abis=...` in `local.properties`.

jni_zero's generated Java (the `*Jni` classes and the `GEN_JNI`/`J.N` proxies
whose hashed natives the library exports) is checked in next to the generated
headers. The AAR's `proguard.txt` carries jni_zero's keep rules for apps that
use R8. Apps load the library with `System.loadLibrary("jingle_peerconnection_so")`,
which `PeerConnectionFactory.initialize` does by default. As with upstream's
AAR, apps must declare the `INTERNET` and `ACCESS_NETWORK_STATE` permissions
themselves: without the latter, WebRTC's network monitor aborts the process.

`webrtc/src/androidTest` is a smoke test: it loads the library through the
Java API, converts video frame buffers, lists the MediaCodec video codecs and
connects two PeerConnections over loopback (audio, video and a data channel
with a message sent across, so ICE, DTLS-SRTP and SCTP). Run it on a device
with `./gradlew :webrtc:connectedAndroidTest`, or build it with
`assembleDebugAndroidTest`, install the APK and run
`adb shell am instrument -w org.webrtc.test/androidx.test.runner.AndroidJUnitRunner`.
It passes on a Pixel 8a (Android 16, arm64).

## iOS with CMake

The same submodules build `WebRTC.xcframework` (device arm64, simulator arm64
and x86_64) with Xcode's clang, in two steps:

```sh
cmake -B out/ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
  "-DWEBRTC_IOS_SLICES=device:arm64;simulator:arm64;simulator:x86_64"
xcodebuild -project out/ios/webrtc_min.xcodeproj -target WebRTC_xcframework
# -> out/ios/WebRTC.xcframework
```

`WEBRTC_IOS_SLICES` lists the slices (any of `device:arm64`,
`simulator:arm64` and `simulator:x86_64`; `CMAKE_OSX_DEPLOYMENT_TARGET`
defaults to 14.0). Each is a sub-build of this source tree for one SDK and
architecture, with the same generator (with `-G Xcode`, an Xcode project under
`out/ios/slices/`); `WebRTC_xcframework` builds them, merges the simulator
slices with `lipo` and runs `xcodebuild -create-xcframework`.

A single slice can also be built directly, giving `WebRTC.framework`:

```sh
cmake -B out/ios-arm64 -G Ninja -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
ninja -C out/ios-arm64 WebRTC   # -> out/ios-arm64/webrtc/sdk/WebRTC.framework
```

(for the simulator, add `-DCMAKE_OSX_SYSROOT=iphonesimulator`).

Like the Android build, it has no software video codecs (video uses
VideoToolbox's H.264/H.265; the VP8/VP9/AV1 classes and headers are left out)
and no protobuf. Otherwise the framework has the same public headers, module
map and exported `RTC*` classes as gn's (see `webrtc/RECIPE.md`).

## gn builds

`gn/` has scripts that sparse-fetch the minimal upstream WebRTC checkout and
build it with gn instead (Android from macOS or Linux, iOS from macOS), with
the patches they apply: see `gn/README.md`. The CMake build doesn't need them,
but they're how the forks' pregenerated JNI headers and Java are regenerated
(see `webrtc/RECIPE.md`).

## Testing on phones

`webrtc-android-min/` is a Jetpack Compose app that uses the AAR for a video
call between two Android phones, and `stun-room/` is the STUN and signaling
server it calls through (Kotlin with Ktor, for a LAN). Their READMEs have how
to build and use them.
