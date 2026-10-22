# LanShare for Android

Native Android client for the LanShare local network file transfer app. It displays a four-digit code, discovers other codes over Android NSD (`_lanshare._tcp`), requests approval before receiving, and streams files directly over TCP to `Download/LanShare`. File data does not pass through the website, internet servers, or cloud storage. During transfers it shows speed and estimated time remaining. A connected-device foreground service and CPU/Wi-Fi locks keep an active transfer running when the display turns off; Android shows an ongoing notification for the transfer.

## Build

Open this `Android` directory in Android Studio, or run:

```sh
./gradlew assembleDebug
```

The debug APK is written to `app/build/outputs/apk/debug/app-debug.apk`. The project uses Android Gradle Plugin 8.13.1, Kotlin 2.0.0, compile SDK 35, and minimum SDK 29.

The current execution environment blocks Gradle's local socket startup. The debug APK in this folder was therefore compiled with the Android Studio Kotlin compiler and packaged with the installed Android SDK tools; in a normal Android Studio environment, use the Gradle command above.

The APK is signed with this Mac's standard Android Studio debug key, so a later local Gradle debug build uses the same signing identity. It is a development build, not a Google Play release or a Play Protect-verified publisher build.

## Compatibility and limits

The wire format follows the shared development protocol in `../docs/PROTOCOL.md`, so macOS, Android, iOS, and Windows clients can discover each other and exchange single files. Folder transfer, manual IP entry, and transport encryption are not implemented. This draft is unencrypted and is for trusted-network development use only. Device discovery and incoming-transfer approval require the app to be open; once a transfer is accepted or started, the foreground service keeps that transfer active with the screen off.
