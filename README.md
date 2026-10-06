# webrtc-min

* ~~Install a hypervisor~~
* ~~Download a Linux ISO image~~
* ~~Create a VM/install ISO image~~
* ~~Checkout depot tools~~
* ~~Add depot tools to your path~~
* ~~Run fetch~~
* ~~Wait~~
* ~~Wait~~
* ~~Wait~~
* ~~Rerun fetch from the start because your machine went into standby half way through and the checkout was corrupt~~
* ~~Wait~~
* ~~Wait~~
* ~~Wait~~
* ~~Run sync~~
* ~~Generate targets~~
* ~~Build target~~

webrtc-min has everything you need to build WebRCT for Android and iOS on Windows, Mac or Linux, without the 25GB download and the complicated build steps.

## Checkout

```sh
git clone --recursive https://github.com/komakai/webrtc-min.git
```

**NOTE: be sure to clone recursively**

## Android Build

If you already have an Android build environment set up then you probably already have everything you need to build.

* Android Studio (recommended but not strictly required - a standalone JDK 17+ will suffice)
* Android SDK (with platform 36 support installed)
* Android NDK (r30)
* CMake/ninja (install from "SDK Manager" if not already installed)

Either of the following

* Open the `android` subfolder in Android Studio and select `Build` > `Assemble Project`

or

* Run the following from command line in the `android` subfolder

```sh
ANDROID_NDK_HOME=/path/to/android-ndk-r30 ./gradlew :webrtc:assembleRelease
```

The build output will be located at `webrtc/build/outputs/aar/webrtc-release.aar`
The set of ABIs can be changed by creating a `local.properties` file in the `android`
subfolder and setting the `webrtc.abis` property

## iOS Build

If you already have an iOS build environment set up then you probably already have everything you need to build.

* Xcode
* CMake

First generate the Xcode project by running the following command in the repository root:

```sh
cmake -B out/ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS \
  "-DWEBRTC_IOS_SLICES=device:arm64;simulator:arm64;simulator:x86_64"
# -> out/ios/WebRTC.xcframework
```

Modify the target platforms by changing the `-DWEBRTC_IOS_SLICES` value as necessary.

Then either

* Open the generated Xcode project in the `out/ios/` folder and select `Product` -> `Build`

or

* Run the following command 

```sh
xcodebuild -project out/ios/webrtc_min.xcodeproj -target WebRTC_xcframework
```

## Testing

Minimal sample apps are located in the `webrtcmin-app-android` and `webrtcmin-app-ios`
subfolders. Refer to the `README.md` files in those folders for information on building and running.
A minimal stun/signalling server is located in the `stun-room` subfolder. Refer to the `README.md` in that folder for information on building and running on Local Area Network.

## Misc

The `regen` folder contains tools intended for use in generating updated versions of
`webrtc_min` in the future and can safely be ignored.
