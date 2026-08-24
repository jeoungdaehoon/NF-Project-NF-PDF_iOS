# NF PDF iOS

NF iOS 포털과 기존 FileManager/PDF 기능을 하나의 SwiftUI 앱으로 통합한 프로젝트입니다.

## 포함 기능

- NF Google/Apple 로그인과 포털 WebView
- SwiftUI PDF 문서 라이브러리
  - 새 PDF, 사진 PDF 변환, 링크 다운로드, Files 가져오기
  - 폴더, 검색, 즐겨찾기, 이름 변경, 이동, 7일 휴지통
- PDFKit 기반 보기 및 편집
  - 펜·형광펜·지우개, 도형, 텍스트, 이미지, 페이지 관리
  - 편집 기록, 자동 저장, 공유, 최대 1000% 확대
- iCloud Drive
  - `iCloud.co.kr.NF`의 `NF PDF` Documents 폴더
  - 업로드, 갱신, 내려받기, 삭제, 다른 기기 문서 가져오기
- Google Drive
  - 별도 네이티브 Google 로그인 없이 NF WebView 로그인 세션 사용
  - NF 서버의 기존 `drive.file` 권한과 Notefree 폴더에 업로드/갱신
  - Google Drive 파일 제공자를 통한 PDF 가져오기
- Files 앱의 PDF 편집기 등록 및 Open in Place

## FileManager → SwiftUI 이관

기존 UIKit/XIB 화면은 병합 프로젝트에 포함하지 않고 다음 SwiftUI 화면과 서비스로 대체했습니다.

| 기존 영역 | 병합 구현 |
| --- | --- |
| Folder/History/Recycle ViewController | `PortalPDFDocumentsView` |
| Document ViewController와 도구 XIB | `PortalPDFPreviewView`, `PortalPDFKitView`, SwiftUI Toolbar |
| 로컬/iCloud FileManager Model | `PortalPDFLocalStorageRepository`, `PortalPDFICloudRepository` |
| Google 계정 저장 | `PortalPDFGoogleDriveService` + NF 로그인 세션 |
| Storyboard TabBar | NF 포털의 PDF 문서 진입 + SwiftUI `NavigationStack` |

PDFKit, PencilKit, PhotosUI처럼 시스템 UIKit 컨트롤이 필요한 부분만 `UIViewRepresentable` 경계에 유지하고 앱 화면과 상태 흐름은 SwiftUI로 구성합니다.

## 서명 설정

1. Xcode에서 `NF.xcodeproj`를 엽니다.
2. NF 타깃의 Signing Team과 번들 ID `co.kr.NF`를 확인합니다.
3. Apple Developer에서 `iCloud.co.kr.NF` 컨테이너를 생성하거나 기존 컨테이너를 연결합니다.
4. iCloud Documents, Sign in with Apple, Fonts capability가 포함된 프로비저닝 프로파일을 사용합니다.

Google Drive 토큰은 앱에 저장하지 않습니다. NF 서버에 로그인된 계정의 세션 쿠키만 요청에 사용하고, 기기에는 Portal 파일 ID와 Drive 파일 ID의 연결 정보만 보관합니다.

## 검증

```sh
xcodebuild -project NF.xcodeproj -scheme NF \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

클라우드 서비스 테스트는 `NFTests/PortalPDFCloudServicesTests.swift`에 있습니다.
