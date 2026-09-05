# Changelog

## Unreleased

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
