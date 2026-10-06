# webrtcmin-app-android

Open this folder in Android Studio and build/install. Defaults to using the release `.aar` built by the Android webrtc-min located at `../android/webrtc/build/outputs/aar/webrtc-release.aar`

## Use

Run on 2 phones.
Ensure the stun-room server at `../stun-room` is running on a machine accessible to the phones.
Tap the settings icon and enter the `stun-room` server's local IP address and HTTP port, e.g. `192.168.11.12:8080`
Enter a room by tapping on one of the four buttons. Enter the same room on another phone to start a video call.