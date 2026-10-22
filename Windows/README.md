# LanShare for Windows

Windows desktop client implemented with WPF and .NET 8. It advertises and browses `_lanshare._tcp` using IPv4 mDNS, asks before receiving, streams one file at a time, and saves accepted files under `%USERPROFILE%\Downloads\LanShare`. **웹 브라우저 연결** starts an HTTP bridge on port 52521. Devices on the same Wi-Fi can upload a file to Downloads/LanShare or download the file selected in the app.

## Build on Windows

Install the .NET 8 SDK or Visual Studio 2022 with the .NET desktop development workload, then run from the repository root:

```powershell
dotnet build .\Windows\LanShare.Windows\LanShare.Windows.csproj -c Release
dotnet publish .\Windows\LanShare.Windows\LanShare.Windows.csproj -c Release -r win-x64 --self-contained true
```

The publish output contains a self-contained Windows x64 app. A Windows build host is required; this project has not been compiled on the current Mac because the .NET SDK is not installed here.

## Network and compatibility

- Keep the Mac, Windows PC, phone, and tablet on a network that permits multicast DNS and peer-to-peer TCP traffic.
- If Windows Firewall prompts, allow LanShare on **Private networks**. Public-network access is not required.
- The app sends/receives the same single-file v1 framing as the other clients. Received files are stored in the LanShare subfolder of Downloads.
- This development protocol has no transport encryption or device authentication. Use only on trusted private networks; it is not ready for public release.
