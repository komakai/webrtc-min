# webrtc-min

Builds WebRTC's `libjingle_peerconnection_so.so` for Android without
depot_tools, gclient or the multi-gigabyte Chromium dependency set.

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
pins). arm64-v8a, armeabi-v7a, x86 and x86_64 all build; x86 uses the NDK's
yasm for libjpeg's SIMD.

This build matches the gn one with both options below off: no software video
codecs (video uses MediaCodec) and no protobuf. On arm64 it exports the same
JNI symbols as gn's library, and the stripped size is within 1%. The generated
JNI headers are checked in, so the build needs no python or JDK; regenerating
them (see `webrtc/RECIPE.md`) still uses the gn build below. The compile flags
follow Chromium's release config for Android, minus its warning flags,
`-Werror`, debug-info flags and the `-fsanitize=...`/`-fsanitize-trap=...`
hardening checks (array bounds, return, unreachable).

## Android with gn

`fetch_webrtc_android_mac.sh` (macOS) and `fetch_webrtc_android.sh` (Linux
x86_64) sparse-fetch only what the gn build reads (~295 MB, or ~216 MB with both
options below off) and apply the patches here.

The Linux script has been run on WSL2 (Ubuntu 24.04) with both options below
off; its default configuration hasn't been tried on Linux yet.

```sh
./fetch_webrtc_android_mac.sh . [webrtc-revision]   # or fetch_webrtc_android.sh
cd src
buildtools/mac/gn gen out/android_arm64              # buildtools/linux64 on Linux
ninja -C out/android_arm64 libjingle_peerconnection_so
```

Requirements: git, curl, unzip, python3 (plus Xcode on macOS), an Android NDK matching the
major version in WebRTC's `DEPS` (set `ANDROID_NDK_HOME`), and a JDK.
An installed Android SDK (`ANDROID_HOME`) and a `ninja` on `PATH` are used
when present instead of downloading them. On Linux, the JDK of the `javap` on
`PATH` is also used, and so is the SDK's newest platform when the SDK doesn't
have the version DEPS pins (javap only reads framework class signatures from
it). Together these skip ~470 MB of downloads.

Options (environment variables):

- `SOFTWARE_VIDEO_CODECS=0`: build without libvpx (VP8/VP9), libaom and dav1d
  (AV1). `SoftwareVideo*Factory` then reports no codecs and video relies on
  MediaCodec.
- `PROTOBUF=0`: build without protobuf, so nothing is compiled for the host
  (on Linux, the host sysroot isn't downloaded either). Loses RtcEventLog
  output and audio debug dumps.

Patches:

- `build-ndk-clang.patch`: lets Chromium's `//build` use the NDK's clang.
- `build-mac-host.patch`: allows a Mac host for Android builds.
- `webrtc-no-perfetto.patch`: drops an unneeded Perfetto dependency.
- `webrtc-optional-sw-video-codecs.patch`: adds the
  `rtc_include_software_video_codecs` gn arg.
- `build-xcode-clang.patch`: lets the Apple toolchains use Xcode's tools (iOS).

## iOS: WebRTC.xcframework

`fetch_webrtc_ios.sh` (~285 MB) and `build_webrtc_ios.sh` build
`WebRTC.xcframework` with Xcode's own clang and linker instead of Chromium's
downloaded toolchain:

```sh
./fetch_webrtc_ios.sh ios [webrtc-revision]
SLICES="device:arm64" ./build_webrtc_ios.sh ios   # -> ios/out_ios_libs/WebRTC.xcframework
```

`SLICES` defaults to `device:arm64 simulator:arm64 simulator:x64`, as in
WebRTC's `build_ios_libs.py`; `PROTOBUF=0`, `DEBUG=1` and
`IOS_DEPLOYMENT_TARGET` are also supported. `build-xcode-clang.patch` points
Chromium's Apple toolchains at Xcode's linker, `strip`, `install_name_tool` and
`dsymutil`. Only the `device:arm64` slice has been built and link-tested so far.

The dependency list is maintained by hand, so it can break when WebRTC `main`
adds a dependency; pass a known-good revision for reproducible builds (last
verified: 1a29be5e6348, 2026-10-02).
