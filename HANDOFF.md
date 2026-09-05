# HANDOFF — 다음 세션 인수인계

- **작성일**: 2026-09-05 · **기준 커밋**: `e32142b` (main)
- **상태**: v0.1.0 구현·리뷰·문서 완료. 미공개(리모트 없음). 테스트 34개 그린, release 빌드 검증됨.

## 현재까지 완료된 것 (믿어도 되는 상태)

- `.ips` 2-part/단일 JSON + MetricKit 단일/JSON Lines 파서 (tolerant, BOM 처리)
- dSYM 심볼리케이션: `--dsym` 검색경로 → Spotlight(UUID 캐시) → `atos` 배치. 미발견 시 unsymbolicated 정상 상태
- 정규화 top-3 프레임 시그니처 클러스터링 + 버전 저널(first/last seen, 빌드별 occurrences, 역순 ingest 백필)
- CLI 9개: ingest/list/show/new-since/top/is-known/hang-report/digest/mark
- MCP stdio 서버 6툴(new_since·top_crashes·crash_detail·is_known·hang_report·digest), `isError` 플래그
- 배포 키트: README(실트랜스크립트)·기획서·AGENTS.md·CHANGELOG·MIT·CI yaml·Makefile·Examples/demo
- 2라운드 코드 리뷰 완료 — 커밋 `44e53aa`(초기) → `2b7e73e`(1차 7건) → `a1437b6`(2차 3건) → `e32142b`(문서)

빠른 상태 재확인: `swift test` (수 초) → `make demo` (end-to-end).

## 다음 세션 할 일 (우선순위)

### P0 — 실데이터 검증 (신뢰도의 마지막 빈칸)
**1차 완료(2026-09-05, 커밋 `4154ac9`)**: 공개 실데이터 2종으로 검증 — iOS 16 `.ips`
(MacSymbolicator 테스트 코퍼스) + iOS 14 MetricKit 페이로드(Sherlouk gist).
변이 5종 발견·수정·`Fixtures/real/` 회귀 테스트로 잠금 (실제 `.ips` 전체 파싱 실패 버그 포함).
**리뷰 패치 배치 완료(2026-09-05)**: mdfind 대시 UUID 버그(실측 확인 — Spotlight 폴백이
전멸했었음)+계약 테스트, `--dsym` UUID 검증(다른 빌드 dSYM 오심볼 방지), 재수집 이중 카운트
방지(`seen.json` 지프린 장부), Store 무음 실패 stderr 경고. 테스트 39개.
남은 것:
1. 추가 확보: Xcode Organizer Export, `xcrun devicectl` 기기 수집, 자기 TestFlight 앱,
   공개 이슈에 붙은 `.ips` 본문(flutter#148927, maui#29641, isar#824 등 전문 첨부 확인됨).
2. 실제 MetricKit 다양성: iOS 15+ 최신 포맷, hangDuration·cpuException 실측 변형.
3. 구식 텍스트 `.crash` 포맷은 현행 미지원 — 지원 여부는 별도 결정 사항.
4. 파서가 놓치는 변형 발견 → fixture로 잠그고 tolerant 파서 확장. **이것이 v0.3보다 먼저다.**
5. 리뷰에서 미처 안 고친 P2: 전역 플래그 후행 무시(`ingest . --store X`가 조용히 기본
   저널로 감 — 실제로 걸림), `dwarfBinary` 폴백 비결정성(.DS_Store 위험), `Store.ingest`
   O(리포트×클러스터) 시그니처 스캔 인덱싱, atos 타임아웃, MetricKit 프레임 `binaryUUID`
   폐기(이미지 테이블 역구성으로 심볼리케이션 커버리지 향상).

### P1 — v0.3 기능 (기획서 로드맵 순서)
1. **`.coronerignore`** — 수집 제외 패턴. `FileDiscovery`에 글롭 매칭만 추가하면 되는 소작. 기획서 v0.2 옵션 미이행분.
2. **suspect_commit** — 이 프로젝트의 차별화 기능. `first_seen_build` 전후 커밋 범위의
   `git diff --name-only`를 뽑아 클러스터 top 프레임의 소스 파일과 교차 → `suspect_commit` 필드 채움.
   프레임→소스 앵커는 indexstore-db 연동(또는 dSYM 심볼명의 타입 접두어 휴리스틱)으로 시작.
   제작자의 정적분석 역량이 직접 들어가는 지점 — 기획서 §로드맵 참고.
3. **CI 게이트** — `coroner new-since <last-released-build>`가 빈 값을 반환하지 않으면 fail 1로.
   GitHub Actions 예제 README에 추가.
4. **ASC dSYM 자동 다운로드** — App Store Connect API 키 필요. 키 관리 설계부터(환경변수/키체인).

### P2 — 공개 준비 (사용자 승인 gate)
- 저장소명 `coroner` 가용성 확인(GitHub/Homebrew) — AGENTS.md 릴리스 체크리스트 참조.
- 리모트 생성·push → CI 실작동 확인(현 CI yaml은 한 번도 실행된 적 없음).
- 태그 `v0.1.0`. README 배지(테스트/라이선스) 추가.
- **푸시/공개는 사용자 결정 사항 — 임의 진행 금지.**

## 함정·결정 기록 (다시 읽기)

- 저장 포맷은 JSON(기획서는 YAML) — 의존성 0 원칙의 의도된 편차. 새 편차는 README "정직한 편차"에 기록.
- 저널 파일 스키마(`reports/*.json`)는 호환성 인터페이스 — id/시그니처 체계 변경 시 마이그레이션 없이는 금지.
- `AGENTS.md`의 불변식 7조 + 릴리스 체크리스트 준수. 테스트 수를 바꾸면 README·AGENTS.md의
  "34" 표기 3곳(main/AGENTS/개발 섹션)을 함께 갱신.
- README 트랜스크립트는 반드시 실제 실행 출력으로 갱신(손으로 다듬지 않음 — 1차 퇴고에서 적발된 문제).
- MetricKit 전달은 일간 미만·TestFlight는 지연됨 — 실시간 도구가 아니라 "일간 부검실"이 기대치.

## 참조

- 기획서/차별화 전략: `기획서.md` · 에이전트 작업 지침: `AGENTS.md` · 사용법: `README.md`
- 포트폴리오 맥락: 형제 프로젝트 `../breadcrumb`(UI↔코드 지도), `../tombstone`(기각 원장) —
  suspect_commit 교차 결과를 tombstone 묘비로 넘기는 상호 판매 구조가 기획서에 명시되어 있음.
