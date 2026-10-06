plugins {
    id("com.android.application") version "9.2.1" apply false
    // AGP's built-in Kotlin uses this Kotlin version, which the Compose
    // compiler plugin's must match.
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
}
