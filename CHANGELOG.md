# Changelog

## Unreleased

P0 실데이터 3차 + ASC dSYM:

- **macOS `.ips` 지원 검증** — 실측 macOS 12 크래시(xsscx/srd)에서 `app_version`·
  `build_version`이 **빈 문자열**로 오는 변형 발견. nil로 병합해 저널에 "" 빌드 키가
  생기는 오염 수정
- **iOS 15+ MetricKit 실측 fixture** — 공개 블로그의 iOS 15.1 실측 덤프를 JSON으로 전사해
  코퍼스의 마지막 빈칸(iOS 15+ 형태)을 채움. jetsam(`bug_type` 288) 원본은 공개 미확보 — 후보로 기록
- **ASC dSYM 자동 다운로드 `asc-dsym` 구현** — 공식 ASC API(builds → buildBundles →
  dSYMUrl, fastlane과 동일 사슬)로 dSYM zip 다운로드·해제. Core는 순수 부품만(ES256 JWT
  서명 + .p8 ASN.1 파싱 + 응답 파싱, 전부 단위 테스트), 네트워크는 CLI 한정 — 무네트워크
  불변식 유지. **라이브 API 검증은 실제 키 확보 시 대기**
- **앵커 정밀화 결정(dwarfdump)** — atos와 같은 DWARF 라인 테이블을 읽어 추가 베네핏 없음을
  실측 확인 → 보류. 소스 없는 심볼(OUTLINED_* 등)은 어느 쪽도 못 살림
- XCTest 52 → 56개

suspect_commit v2 — 범위 정확화 + MCP 툴화:

- **빌드 태그 매핑** — 저장소가 빌드를 태깅(`build/241`·`rel-241`·`241` 형태, 점 버전
  `v1.2.0`은 거부)하면 first_seen 빌드의 정확한 커밋 범위(직전 빌드 태그..해당 태그)를
  조회. 태그가 없으면 기존 날짜 창(±14일)으로 폴백
- **MCP 7번째 툴 `suspects`** — 에이전트가 `{id}`로 suspect_commit 추정을 직접 요청.
  기획서 6툴에서의 확장이며 편차 섹션에 기록
- **indexstore-db 연동 결정** — Xcode에 포함되지 않음을 확인(실측)하여 프레임→소스 앵커는
  계속 atos sourceFile 사용. SourceKit-LSP 번들이 탐지되는 머신만 활성화하는 후보로 문서화
- XCTest 50 → 52개 (태그 파싱·범위 인자 스텁 테스트 + 실제 임시 git 저장소 e2e)

P1 기능 (기획서 v0.3에서 시점 앞당김):

- **CI 게이트** — `new-since`가 신규 클러스터를 발견하면 exit 1 (빈이면 0). 릴리스
  파이프라인에 `new-since <last-released-build>`로 심는다. README에 GitHub Actions 예제
- **suspect_commit v1 (해자 기능 조기 구현)** — `coroner suspect <id>`: first_seen
  시점 ±윈도우(기본 14일)의 git 커밋 중 클러스터의 소스 앵커(심볼리케이션 sourceFile
  베이스네임)와 변경 파일이 교차하는 커밋을 추정으로 기록. `sourceAnchors`·`suspects`
  필드 추가(가산적 — 기존 저널 호환). unsymbolicated면 정직하게 빈 답. "추정이지 판결이
  아님"을 출력에 명시
- XCTest 47 → 50개

리뷰 P2 패치 배치:

- **후행 전역 플래그 거부** — `coroner ingest . --store X`가 플래그를 조용히 삼켜 기본
  저널에 쓰던 문제를 exit 2 + 안내로 수정 (`--store`/`--dsym`/`--no-mask`는 명령 앞에)
- **`top --kind`** 지원 (`list`와 정렬)
- **`ProcessRunner` 타임아웃(기본 60초)** — 손상 dSYM으로 atos가 멈춰도 coroner가 멈추지 않음
- **`dwarfBinary` 폴백 결정성** — DWARF 디렉터리 후보를 숨김 파일 제외·정렬로 선택
  (.DS_Store 피크 위험 제거)
- **`Store` 시그니처 인덱스** — ingest 병합이 전수 스캔(O(리포트×클러스터))에서 O(1)로,
  레거시 저널 병합 선택도 결정적으로
- **MetricKit 프레임 `binaryUUID` 역구성** — 이미지 테이블이 없는 실측 페이로드에서
  프레임의 UUID로 테이블을 만들어 dSYM 탐색(Spotlight) 경로 확보
- XCTest 41 → 45개

실데이터 검증 1차 — 공개된 실제 텔레메트리(iOS 16 `.ips` 1건, iOS 14 MetricKit 페이로드 1건)로
발견한 포맷 변형 5종을 파서에 반영하고 `Fixtures/real/` 회귀 테스트로 잠금:

- `.ips` 본문 분할 버그 수정 — Apple이 pretty-print한 본문 JSON 안의 빈 줄(빈 딕셔너리)이
  메타데이터/본문 separator 오인식을 일으켜 실제 `.ips`가 통째로 파싱 실패하던 것을 첫 줄 기준
  분할로 수정
- Apple 고유 타임스탬프 포맷 지원 — `"2022-09-18 15:28:37.00 +0900"` 형태(`.ips` 메타데이터·
  MetricKit 공통)를 ISO8601 외 포맷으로 추가
- MetricKit 실측 키 반영 — 프레임 리스트 `callStackRootFrames`(문서의 `frames`와 병행 지원),
  디바이스 `deviceType`(`deviceModel`과 병행), disk-write 키 복수형 `diskWriteExceptionDiagnostics`,
  payload 최상위 `timeStampBegin/End`를 개별 진단의 폴백 타임스탬프로 사용
- MetricKit `exceptionType`이 숫자로 오는 실측 변형 허용
- XCTest 34 → 36개

전체 코드 리뷰 기반 신뢰도 패치:

- **dSYM Spotlight 조회 버그 수정** — 대시가 제거된 UUID로는 mdfind가 절대命中하지
  않음(실측 확인). 조회 직전 8-4-4-4-12 대시 복원 + 쿼리 형식을 검증하는 계약 테스트 추가
- **`--dsym` 경로 UUID 검증** — 같은 이름의 다른 빌드 dSYM이 있으면 atos가 잘못된 심볼을
  조용히 만들어내던 문제를 dwarfdump UUID 대조로 차단(검증 실패 시 계속 탐색), 조회 캐시 추가
- **재수집 이중 카운트 방지** — 파일 내용 SHA256 지문 장부(`seen.json`)로 동일 파일 재ingest를
  스킵. occurrences·new-since 수치가 재실행으로 부풀지 않음
- **Store 무음 실패 제거** — 클러스터 저장 실패·읽을 수 없는 저널 파일을 stderr 경고로 보고
  (기존엔 `try?`로 디스크 문제가 조용히 사라짐)
- XCTest 36 → 39개

실데이터 검증 2차:

- **Xcode "Translated Report" 내보내기 지원** — Organizer가 사람이 읽는 리포트 앞부분에
  원본 메타데이터+본문 JSON을 덧붙인 형태(flutter/flutter#148927 첨부 파일로 발견).
  메타데이터/본문 분할을 "첫 줄"이 아니라 "JSON 객체로 파싱되는 첫 줄" 스캔으로 일반화
- 실측 fixture 2종 추가 — .NET MAUI 앱 크래시(dotnet/maui#29641, iOS 15.8)로 타
  툴체인 방어. `Fixtures/real/README.md`에 출처 표 신설, AGENTS.md fixture 규칙 갱신
  (공개 게시물 첨부 실측 데이터만 허용)
- XCTest 39 → 41개

## 0.1.0 — 2026-09-05

첫 릴리스. 기획서(기획서.md) v0.1+v0.2 스코프.

- `.ips` 크래시 리포트 파서 — 2-part(메타데이터+본문)·단일 JSON, tolerant decoding
- MetricKit 진단 파서 — crash/hang/CPU exception/disk-write, 단일 JSON·JSON Lines, subFrames 깊이우선 평탄화
- dSYM 심볼리케이션 — `--dsym` 검색경로 + Spotlight(UUID), atos 배치 호출, 미발견 시 unsymbolicated 정상 상태
- 결정적 클러스터링 — 정규화 상위 3프레임 시그니처, SHA256 기반 안정 id
- 버전 저널 — first/last seen 빌드, 빌드별 발생 수, `new-since` 숫자 비교(lexicographic 폴백)
- CLI 9개 — ingest/list/show/new-since/top/is-known/hang-report/digest/mark(트리아지 status 기록)
- MCP stdio 서버 — initialize/tools/list/tools/call, 6툴(new_since·top_crashes·crash_detail·is_known·hang_report·digest), SDK 무의존 JSON-RPC 2.0, 툴 실패 시 `isError` 플래그
- 프라이버시 — 홈 디렉터리 경로 기본 마스킹
- 견고성 — 역순 ingest 시 first_seen 백필, digest/hang-report 기간 필터 일관화, 자식 프로세스 stderr 교착 방지(null device), dSYM Spotlight 조회 UUID 캐시, ingest 대상에서 자체 저널·VCS·빌드 디렉터리 자동 제외
- XCTest 32개 — 실 dSYM·네트워크 없이 전부 실행
