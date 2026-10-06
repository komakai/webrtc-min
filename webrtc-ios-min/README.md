# webrtc-ios-min

An iOS app for testing webrtc-min, the counterpart of `../webrtc-android-min`:
a video call between two phones through a stun-room server, with SwiftUI. It's
two files: `WebRTCMin/WebRTCMinApp.swift` (the screens) and
`WebRTCMin/Call.swift` (signaling and the PeerConnection).

Requirements: Xcode, and webrtc-min's `WebRTC.xcframework` at
`../out/ios/WebRTC.xcframework`: build it first, from the repository root,
with

```sh
cmake -B out/ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
  "-DWEBRTC_IOS_SLICES=device:arm64;simulator:arm64;simulator:x86_64"
xcodebuild -project out/ios/webrtc_min.xcodeproj -target WebRTC_xcframework
```

Then open `WebRTCMin.xcodeproj`, choose your team under Signing & Capabilities
(and change the bundle identifier, `com.example.webrtcmin`, if it's taken), and
run it on an iPhone or iPad (iOS 16 or later). From the command line:

```sh
xcodebuild -project WebRTCMin.xcodeproj -scheme WebRTCMin \
  -destination 'platform=iOS,name=<device name>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<team id> build
```

The simulator runs the app too, but has no camera.

## Use

As on Android: run `../stun-room` (`./gradlew run` in it) on a machine both
phones can reach, and set its address (host:port, e.g. `192.168.11.12:8080`)
with the settings icon on each phone. The STUN server is taken to be at the
same host, on UDP 3478. Tap the same room's button on both phones to call: the
app asks for the camera, microphone and local network permissions the first
time. The call screen has mute and hang-up buttons.

The phone already in the room sends the Offer when the other's Join arrives.
webrtc-min's framework has no software video codecs, so video uses
VideoToolbox's H.264 (or H.265): a call with an Android phone shows video only
if the Android phone has an H.264 codec too, as nearly all do. Audio plays on
the speaker, and the screen stays on during a call.

The app polls the room's messages once a second, which is also the heartbeat
that keeps it in the room. If the server can't be reached, or has dropped the
phone from the room, the call ends with the reason shown on the home screen.
