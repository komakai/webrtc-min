# webrtc-android-min

An Android app for testing webrtc-min: a video call between two phones through
a stun-room server, with Jetpack Compose. It's two files:
`MainActivity.kt` (the screen) and `Call.kt` (signaling and the
PeerConnection).

```sh
./gradlew installDebug
```

Requirements: JDK 17+, an Android SDK with platform 37.2 (`ANDROID_HOME` or
`sdk.dir` in `local.properties`), and webrtc-min's AAR: build it first with
`./gradlew :webrtc:assembleRelease` in `../android` (`webrtc.aar` in
`gradle.properties` gives its path). The AAR has only the ABIs it was built for
(arm64-v8a by default), so the app runs on phones but not on x86 emulators.

## Use

Run `../stun-room` (`./gradlew run` in it) on a machine both phones can reach,
and set its address (host:port, e.g. `192.168.11.12:8080`) with the settings
icon on each phone. The STUN server is taken to be at the same host, on UDP
3478. Tap the same room's button on both phones to call: the app asks for the
camera and microphone permissions the first time. The call screen has mute and
hang-up buttons.

The phone already in the room sends the Offer when the other's Join arrives.
Video uses the phones' hardware codecs (the AAR has no software ones), so the
two phones need one in common, e.g. VP8 or H.264. Audio plays on the speaker.

The app polls the room's messages once a second, which is also the heartbeat
that keeps it in the room. If the server can't be reached, or has dropped the
phone from the room, the call ends with the reason shown on the home screen.
