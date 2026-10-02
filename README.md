# webrtc-min

Builds WebRTC's `libjingle_peerconnection_so.so` for Android (arm64) on a Mac
without depot_tools, gclient or the multi-gigabyte Chromium dependency set.
`fetch_webrtc_android_mac.sh` sparse-fetches only what the build reads
(~330 MB, or ~216 MB with both options below off) and applies the patches
here.

```sh
./fetch_webrtc_android_mac.sh . [webrtc-revision]
cd src
buildtools/mac/gn gen out/android_arm64
ninja -C out/android_arm64 libjingle_peerconnection_so
```

Requirements: Xcode, git, curl, unzip, python3, an Android NDK matching the
major version in WebRTC's `DEPS` (set `ANDROID_NDK_HOME`), and a JDK.
An installed Android SDK (`ANDROID_HOME`) and a `ninja` on `PATH` are used
when present instead of downloading them.

Options (environment variables):

- `SOFTWARE_VIDEO_CODECS=0`: build without libvpx (VP8/VP9), libaom and dav1d
  (AV1). `SoftwareVideo*Factory` then reports no codecs and video relies on
  MediaCodec.
- `PROTOBUF=0`: build without protobuf, so nothing is compiled for the host.
  Loses RtcEventLog output and audio debug dumps.

Patches:

- `build-ndk-clang.patch`, `build-mac-host.patch`: let Chromium's `//build`
  use the NDK's clang and a Mac host.
- `webrtc-no-perfetto.patch`: drops an unneeded Perfetto dependency.
- `webrtc-optional-sw-video-codecs.patch`: adds the
  `rtc_include_software_video_codecs` gn arg.

The dependency list is maintained by hand, so it can break when WebRTC `main`
adds a dependency; pass a known-good revision for reproducible builds (last
verified: 1a29be5e6348, 2026-10-02).
