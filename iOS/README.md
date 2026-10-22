# LanShare for iOS and iPadOS

SwiftUI app using Network.framework Bonjour discovery and the shared TCP v1 protocol. It can send a selected file to another LanShare device, asks before receiving, and saves received files to `Files → On My iPhone/iPad → LanShare`. The **4자리 코드 / QR로 전송** action opens the same PeerJS/WebRTC transfer page used by the website inside the app. Files received through that page are saved under `Documents/LanShare`.

## Build

Open `LanShareIOS.xcodeproj` in Xcode, select the `LanShareIOS` scheme, and run on an iOS 16 or newer device. The project can also be compiled for the simulator:

```sh
xcodebuild -project iOS/LanShareIOS.xcodeproj \
  -scheme LanShareIOS -sdk iphonesimulator -configuration Debug \
  -derivedDataPath /tmp/lanshare-ios-build CODE_SIGNING_ALLOWED=NO build
```

Installing on a physical iPhone/iPad and distributing through TestFlight or the App Store require Apple signing credentials and provisioning. No signing identity or distribution profile is stored in this project.

## Permissions and limits

- On first use, allow **Local Network** access so Bonjour discovery and direct TCP connections can work.
- The code/QR transfer page uses the website's PeerJS/WebRTC signaling service and requires internet access to open the page and establish a connection.
- Keep LanShare open in the foreground during a transfer. iOS can suspend network activity when the app moves to the background; this app does not promise background transfers.
- Incoming files are written under the app's `Documents/LanShare` folder, exposed in the Files app.
- The current shared v1 protocol does not encrypt or authenticate transfers. Use only on a trusted private network during development.
