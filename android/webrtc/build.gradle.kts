import java.util.Properties

// webrtc.aar: WebRTC's Android Java API (sdk/android, as gn's libwebrtc
// jar, without the software video codec classes) and libjingle_peerconnection_so.so,
// which the Android Gradle plugin builds with webrtc-min's CMakeLists.txt.
plugins {
    id("com.android.library")
}

// The webrtc-min checkout (this project is its android/ directory).
val webrtcMin: File = rootDir.parentFile

// The ABIs to build: -Pwebrtc.abis, else webrtc.abis in the (untracked)
// local.properties, else the default in gradle.properties.
val webrtcAbis: String = gradle.startParameter.projectProperties["webrtc.abis"]
    ?: rootDir.resolve("local.properties").takeIf { it.isFile }
        ?.let { file -> Properties().apply { file.reader().use { load(it) } } }
        ?.getProperty("webrtc.abis")
    ?: providers.gradleProperty("webrtc.abis").get()

android {
    namespace = "org.webrtc"
    compileSdk = 36
    // The NDK WebRTC's DEPS pins. ANDROID_NDK_HOME may point at one outside
    // the Android SDK.
    ndkVersion = "30.0.16248370"
    System.getenv("ANDROID_NDK_HOME")?.let { ndkPath = it }

    defaultConfig {
        minSdk = 23
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Keeps the JNI entry points (and @CalledByNative methods) in apps
        // that use R8.
        consumerProguardFiles(webrtcMin.resolve("third_party/jni_zero/proguard.flags"))
        externalNativeBuild {
            cmake {
                targets("jingle_peerconnection_so")
                arguments("-DWEBRTC_MIN=ON", "-DCMAKE_BUILD_TYPE=Release")
            }
        }
        ndk {
            abiFilters += webrtcAbis.split(",")
        }
    }

    externalNativeBuild {
        cmake {
            path = webrtcMin.resolve("CMakeLists.txt")
        }
    }

    sourceSets {
        getByName("main") {
            java.directories += listOf(
                "webrtc/sdk/android/api",
                "webrtc/sdk/android/src/java",
                "webrtc/rtc_base/java/src",
                "third_party/jni_zero/java/src",
                // jni_zero's generated *Jni classes, GEN_JNI/J.N and the
                // enums gn generates from C++ headers.
                "webrtc/sdk/android/generated_java",
                "third_party/jni_zero/generated_java",
            ).map { webrtcMin.resolve(it).path }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

tasks.withType<JavaCompile>().configureEach {
    exclude(
        // The software video codecs aren't in the native library.
        "org/webrtc/Dav1dDecoder.java",
        "org/webrtc/LibaomAv1Encoder.java",
        "org/webrtc/LibvpxVp8Decoder.java",
        "org/webrtc/LibvpxVp8Encoder.java",
        "org/webrtc/LibvpxVp9Decoder.java",
        "org/webrtc/LibvpxVp9Encoder.java",
        // Test-only.
        "org/jni_zero/JniResetterRule.java",
    )
}

dependencies {
    implementation("androidx.annotation:annotation:1.9.1")

    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("junit:junit:4.13.2")
}
