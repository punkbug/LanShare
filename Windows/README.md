# LanShare for Windows

Windows desktop client implemented with WPF and .NET 8. It displays a four-digit local connection code and advertises it over IPv4 mDNS (`_lanshare._tcp`). Entering another device's code selects that discovered peer; the apps then transfer files directly over TCP and save received files under `%USERPROFILE%\Downloads\LanShare`. The website and internet servers do not carry app-to-app file data.

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
