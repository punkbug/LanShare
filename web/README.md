# LanShare 웹페이지 (홍보 및 배포 랜딩 페이지)

LanShare(랜셰어) 서비스의 홍보, 제품 소개 및 각 플랫폼별 빌드/다운로드 배포를 위한 공식 반응형 랜딩 페이지입니다.

## 🌟 주요 특징

1. **제품 가치 전달**:
   - Zero-Cloud P2P 전송, 계정 없는 무로그인 경험, 초고속 LAN 대역폭 직결, mDNS 자동 검색 소개
   - 기존 클라우드 스토리지(Google Drive, Dropbox) 및 메신저(카카오톡) 대비 비교표 제공
2. **인터랙티브 라이브 시뮬레이터**:
   - 실제 파일을 드래그 앤 드롭하여 로컬 네트워크 전송(수신 승인 -> 초고속 스트리밍 -> 완료 사운드)을 웹 상에서 직접 체험
3. **플랫폼별 배포 및 다운로드 허브**:
   - **macOS**: `dist/LanShare.app` 압축본(`downloads/LanShare-macOS.zip`) 원클릭 다운로드 및 `swift run` 안내
   - **Android**: Jetpack Compose 앱 Gradle 빌드 및 설치 안내
   - **Windows**: .NET 8 WPF 앱 빌드 및 방화벽 설정 안내
   - **iOS / iPadOS**: SwiftUI 앱 Xcode 프로젝트 실행 가이드
4. **모던 UX / UI**:
   - 다크 모드 / 라이트 모드 전환 (시스템 설정 자동 감지 및 로컬스토리지 보존)
   - 접속 기기(OS) 자동 감지 및 맞춤형 다운로드 버튼 라벨링
   - 글래스모피즘(Glassmorphism)과 반응형 모바일 레이아웃 지원

## 🚀 로컬에서 웹페이지 열기

### 방법 1. 웹 브라우저로 직접 열기
Finder에서 `web/index.html` 파일을 더블 클릭하여 기본 브라우저(Safari, Chrome 등)로 바로 엽니다.

```bash
open web/index.html
```

### 방법 2. 로컬 웹 서버 실행 (권장)
Python 내장 서버를 사용하여 로컬 호스트로 서빙할 수 있습니다.

```bash
python3 -m http.server 8080 --directory web
```
브라우저에서 [http://localhost:8080](http://localhost:8080) 접속

## 📦 웹 호스팅 배포 안내

- **GitHub Pages**:
  - 저장소 설정(`Settings` > `Pages`)에서 소스를 `main` 브랜치의 `/web` 또는 GitHub Actions로 지정하여 바로 배포할 수 있습니다.
- **Vercel / Netlify / Cloudflare Pages**:
  - Root directory 또는 Publish directory를 `web`으로 설정하면 정적 사이트로 즉시 전 세계 CDN에 배포됩니다.
