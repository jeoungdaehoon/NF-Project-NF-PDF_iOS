# App Store Connect 등록 초안

## 기본 정보

- 앱 이름: `NF Project Portal`
- 부제: `프로젝트 운영을 한 곳에서`
- 기본 언어: `한국어`
- 번들 ID: `co.kr.NF`
- 버전: `1.0.0 (빌드 2)`
- 카테고리: `생산성`
- 연령 등급: `4+`

## 앱 아이콘 및 지원 기기

- 앱 아이콘 원본: `NF-AppStore-Icon-1024.png`
- Xcode 앱 아이콘 세트: `NF/Assets.xcassets/AppIcon.appiconset`
- 빌드 1의 기기 제품군: `iPhone, iPad`

## 홍보 문구

프로젝트, 보고서, 산출물, 배포 이력을 하나의 포털에서 연결하고 문서까지 모바일에서 바로 확인하세요.

## 설명

NF Project Portal은 프로젝트 운영에 필요한 정보를 한 곳에 모아 관리하는 생산성 앱입니다.

주요 기능

- Google 계정으로 안전한 로그인
- 프로젝트·보고서·산출물·배포 이력 관리
- 계정별 데이터 분리와 동의 기반 읽기 전용 공유
- 첨부 파일과 PDF 문서 모바일 미리보기
- PDF 펜, 지우개, 도형, 이미지 편집 및 저장
- iPhone과 iPad 화면 크기에 맞춘 반응형 화면

NF는 팀의 진행 상황을 선명하게 정리하고, 필요한 문서를 현장에서 바로 확인할 수 있도록 돕습니다.

## 키워드

`프로젝트,업무관리,문서관리,PDF,보고서,산출물,배포,생산성,협업,포털`

## 지원 및 정책 URL

- 지원 URL: `https://hlp-project-portal-745194786909.asia-northeast3.run.app`
- 개인정보처리방침: `https://hlp-project-portal-745194786909.asia-northeast3.run.app/privacy`
- 계정 삭제 요청: `https://hlp-project-portal-745194786909.asia-northeast3.run.app/account-deletion`

## 스크린샷 순서

1. `AppStoreScreenshots/01-login.png` — Google 로그인과 계정 분리
2. `AppStoreScreenshots/02-portal.png` — 프로젝트 운영 포털
3. `AppStoreScreenshots/03-pdf-editor.png` — PDF 보기·편집·저장

세 파일 모두 App Store Connect에서 허용되는 6.7형 iPhone 등록 규격인 `1284 × 2778` PNG입니다.

### iPad 스크린샷

1. `AppStoreScreenshots/iPad/01-login.png`
2. `AppStoreScreenshots/iPad/02-portal.png`
3. `AppStoreScreenshots/iPad/03-pdf-editor.png`

세 파일 모두 iPad 13형 등록 규격인 `2048 × 2732` PNG입니다.

## TestFlight 내부 테스트 안내

1. App Store Connect에서 `NF Project Portal` 앱을 생성합니다.
2. 첫 빌드 `1.0.0 (1)`을 업로드합니다.
3. TestFlight → 내부 테스터에서 테스터 이메일을 추가합니다.
4. 테스터는 초대 메일 또는 TestFlight 앱에서 초대를 수락합니다.
5. 빌드 처리 완료 후 테스트 정보를 입력하고, 사용자가 최종 외부 테스트/배포 버튼을 선택합니다.

### 테스트 안내 문구

Google 계정으로 로그인한 뒤 프로젝트·보고서·산출물 탭을 확인해 주세요. 첨부 PDF를 열어 페이지 이동, 확대·축소, 펜·도형·이미지 편집, 저장까지 테스트해 주세요. 문제가 발생하면 기기 모델, iOS 버전, 재현 순서를 함께 알려 주세요.

### 검토 메모

테스트 계정은 Google Workspace 또는 Gmail 계정을 사용합니다. 앱의 주요 기능은 인증 후 포털 WebView와 PDF 편집 화면에서 동작합니다. 카메라·사진 권한은 파일 첨부를 선택할 때만 요청됩니다.
