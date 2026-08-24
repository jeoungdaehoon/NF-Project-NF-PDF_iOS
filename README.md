# NF PDF iOS

NF iOS 포털과 기존 FileManager/PDF 기능을 하나의 SwiftUI 앱으로 통합한 프로젝트입니다.

## 포함 기능

- NF Google/Apple 로그인과 포털 WebView
- SwiftUI PDF 문서 라이브러리
  - 새 PDF, 사진 PDF 변환, 링크 다운로드, Files 가져오기
  - 폴더, 검색, 즐겨찾기, 이름 변경, 이동, 7일 휴지통
- PDFKit 기반 보기 및 편집
  - 펜·형광펜·지우개, 도형, 텍스트, 이미지, 페이지 관리
  - 페이지 편집 데이터 분리 저장, 편집 기록, 자동 저장, 공유, 최대 1000% 확대
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

## PDF 페이지 편집 저장 방식

- 원본 PDF는 페이지 배경과 일반 PDF 데이터만 보관합니다.
- 펜·압력 필기·이미지·도형·텍스트는 문서 ID별 버전형 `Codable` binary property list인 `.nfedit`에 페이지 좌표와 객체 순서 그대로 원자 저장합니다. 기존 JSON `.nfedit`도 읽은 뒤 다음 저장에서 자동 전환합니다.
- `PortalPDFInkOverlayView`는 `.nfedit` 모델을 `CAShapeLayer`, `CALayer`, `CATextLayer`로 직접 그리며, 화면 표시를 위해 PDF Annotation으로 변환하지 않습니다.
- PDF 페이지와 편집 레이어는 FileManager의 `DocumentView`/`DrawingView`처럼 같은 확대 계층에서 함께 변환됩니다. 확대 중 객체 레이어를 재생성하지 않으며, 완료된 펜 획은 작은 획 영역별 비트맵 캐시 레이어 하나만 안정 ID로 증분 추가하고 이미지는 디코딩 결과를 재사용합니다. 확대가 끝난 뒤에만 획 캐시 해상도를 갱신합니다.
- 실시간 일반 펜은 누적 경로를 바로 표시하고 종료 시 한 번만 스무딩합니다. 압력 펜의 화면 표시 계산량은 최대 240개 샘플로 제한하되 저장 데이터는 전체 입력 좌표를 유지합니다.
- 기존 선택·이동·크기 조절 제스처가 사용하는 Annotation은 표시·인쇄가 꺼진 임시 상호작용 프록시이며 저장 정본이 아닙니다.
- 공유, 서버 저장, iCloud Drive 및 Google Drive 동기화 시에는 원본 PDF와 `.nfedit`를 합성한 일반 PDF를 만들어 다른 PDF 뷰어에서도 동일하게 보이게 합니다.
- 문서 복제 시 `.nfedit`도 새 문서 ID로 복제하고, 영구 삭제·계정 데이터 삭제 시 함께 제거합니다.

Core Data는 검색·관계형 메타데이터에는 적합하지만 페이지별 벡터 경로와 이미지 바이너리를 문서 단위로 이동·복제·버전 관리하는 이번 저장 구조에는 이점이 작습니다. 따라서 FileManager 원본의 문서 단위 파일 모델을 유지하면서 Swift의 `Codable`과 원자 쓰기를 사용하는 방식을 선택했습니다.

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
페이지 편집 데이터 분리·복원 테스트는 `NFTests/PortalPDFPageEditPersistenceTests.swift`에 있으며 실제 iPad에서도 실행할 수 있습니다.
