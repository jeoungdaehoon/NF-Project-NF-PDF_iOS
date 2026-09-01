# NF macOS 배포

NF는 기존 iOS 소스를 공유하는 Mac Catalyst 데스크톱 앱을 제공합니다.

## 로컬 설치용 DMG 생성

```bash
./Scripts/build-macos-dmg.sh
```

결과 파일은 `dist/NF-<version>-<build>-macOS.dmg`에 생성됩니다. 기본 빌드는 이 Mac에서 기능을 확인하기 위한 ad-hoc 서명을 사용합니다.

## 외부 배포용 서명 및 공증

다른 Mac에 경고 없이 배포하려면 Apple Developer 계정의 `Developer ID Application` 인증서와 `notarytool` 키체인 프로필이 필요합니다.

```bash
NF_MAC_SIGN_IDENTITY="Developer ID Application: COMPANY (TEAMID)" \
NF_MAC_NOTARY_PROFILE="NF-notary" \
./Scripts/build-macos-dmg.sh
```

스크립트는 Apple Silicon과 Intel을 지원하는 Universal Release Catalyst 앱을 빌드하고, Hardened Runtime 서명, DMG 생성, Apple 공증 및 staple 검증을 순서대로 수행합니다.

## 참고

- iOS 앱과 Mac Catalyst 앱은 같은 SwiftUI 상태와 PDF 편집 데이터를 사용합니다.
- Mac 메뉴에서 `⌘O`로 PDF를 가져오고 `⇧⌘L`로 NF PDF 문서 화면을 열 수 있습니다.
- iCloud 및 Sign in with Apple을 외부 배포본에서도 사용하려면 Catalyst App ID와 해당 배포 프로비저닝 구성이 Apple Developer 계정에 준비되어 있어야 합니다.
