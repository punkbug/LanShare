# LanShare

같은 로컬 네트워크에 연결된 기기끼리 파일을 직접 주고받는 앱입니다. 현재 macOS와 Android 간 전송이 동작하며, iOS와 Windows 클라이언트도 같은 개발용 v1 프로토콜을 사용합니다.

## 시작하기

- [웹페이지 (홍보 및 배포)](web/README.md): 제품 소개, 실시간 시뮬레이터, 플랫폼별 다운로드 웹페이지 (`open web/index.html`)
- [제품 및 기술 가이드](docs/PROJECT_GUIDE.md): 제품 목표, MVP 범위, 아키텍처, 보안, 배포 원칙
- [Codex 작업 프롬프트](docs/CODEX_PROMPT.md): Codex에 전달할 구현 지침
- [전송 프로토콜 초안](docs/PROTOCOL.md): 현재 플랫폼 간 개발용 wire protocol과 한계
- [Android 앱](Android/README.md): Android 프로젝트와 빌드 안내
- [iOS 앱](iOS/README.md): iPhone/iPad 프로젝트와 빌드 안내
- [Windows 앱](Windows/README.md): Windows 데스크톱 프로젝트와 빌드 안내

## macOS 앱 실행

macOS 13 이상과 Xcode가 설치된 Mac에서 저장소 루트에서 다음을 실행합니다.

```sh
swift run
```

앱 번들을 만들려면 다음을 실행합니다.

```sh
bash scripts/build-app.sh
open dist/LanShare.app
```

최초 실행 시 로컬 네트워크 접근을 허용해야 합니다. 두 앱을 같은 로컬 네트워크에서 실행한 뒤, 수신 기기에 표시된 4자리 코드를 송신 기기에 입력하세요. 앱은 Bonjour로 코드를 찾고 파일을 LAN에서 직접 전송합니다.

> 현재 전송 프로토콜은 개발용 초안이며 암호화되어 있지 않습니다. 신뢰하는 개인 네트워크에서만 사용하고, 민감한 파일 전송이나 외부 배포에는 사용하지 마세요. 자세한 내용은 [프로토콜 초안](docs/PROTOCOL.md)을 참고하세요.

## 지원 앱

| 플랫폼 | 프로젝트 | 구현 상태 |
| --- | --- | --- |
| macOS | 저장소 루트 Swift Package | 기존 앱 |
| Android | `Android/` | 기존 앱 |
| iOS/iPadOS | `iOS/LanShareIOS.xcodeproj` | 개발용 앱, 전송 중 앱을 열어 둬야 함 |
| Windows | `Windows/LanShare.Windows/` | .NET 8 WPF 앱, Windows에서 빌드 필요 |

각 앱은 실행할 때 4자리 LAN 연결 코드를 표시합니다. 상대 기기에서 코드를 입력하면 Bonjour/mDNS로 발견된 해당 기기에 기존 TCP 프로토콜로 직접 연결합니다. 앱 간 파일 데이터는 웹페이지, 인터넷 서버 또는 클라우드를 거치지 않습니다.

## 제품 원칙

- 같은 네트워크에서 송신 기기와 수신 기기 사이에 파일을 직접 전송합니다.
- 계정이나 클라우드 업로드를 필수로 요구하지 않습니다.
- 수신 승인, 진행률, 취소, 오류 복구를 명확하게 제공합니다.
- 플랫폼 간 파일 전송은 같은 버전의 전송 규약을 사용합니다.
