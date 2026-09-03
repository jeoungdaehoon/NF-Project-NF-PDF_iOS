# NF macOS 배포

NF는 iPhone/iPad 타깃과 분리된 네이티브 AppKit/WebKit 기반 `NF-macOS` 타깃을 제공합니다. Mac Catalyst 빌드를 사용하지 않습니다.

## 로컬 설치용 DMG 생성

```bash
./Scripts/build-macos-dmg.sh
```

결과 파일은 `dist/NF-<version>-<build>-native-macOS.dmg`에 생성됩니다. 기본 빌드는 이 Mac에서 기능을 확인하기 위한 ad-hoc 서명을 사용합니다.

로컬 ad-hoc 서명에는 Apple Developer 프로비저닝이 필요한 제한 권한을 넣지 않습니다. 따라서 Google 로그인과 포털 기능은 테스트할 수 있지만, Apple 로그인 실사용 검증은 아래 Developer ID/프로비저닝 구성으로 만든 배포본에서 진행해야 합니다.

## 외부 배포용 서명 및 공증

다른 Mac에 경고 없이 배포하려면 Apple Developer 계정의 `Developer ID Application` 인증서와 `notarytool` 키체인 프로필이 필요합니다.

```bash
NF_MAC_SIGN_IDENTITY="Developer ID Application: COMPANY (TEAMID)" \
NF_MAC_NOTARY_PROFILE="NF-notary" \
./Scripts/build-macos-dmg.sh
```

스크립트는 macOS SDK와 `NF-macOS` 스킴으로 Release 앱을 빌드하고, Hardened Runtime 서명, DMG 생성, Apple 공증 및 staple 검증을 순서대로 수행합니다.

## 참고

- `NF` iOS 타깃과 `NF-macOS` 타깃은 소스·번들·설정을 분리하므로 macOS 화면 변경이 iPhone/iPad UI에 영향을 주지 않습니다.
- 화면 배율은 `설정 > 화면` 또는 `⌘+`, `⌘-`, `⌘0`에서 조정하며 앱을 종료해도 유지됩니다.
- Sign in with Apple을 외부 배포본에서도 사용하려면 macOS App ID와 배포 프로비저닝 구성이 Apple Developer 계정에 준비되어 있어야 합니다.
