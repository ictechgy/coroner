# HANDOFF — 다음 세션 인수인계

- **작성일**: 2026-09-06 (3차 갱신) · **기준**: main
- **상태**: v0.1.0 + Unreleased(실데이터 검증 1~3차·신뢰 패치·P2 패치·.coronerignore·CI 게이트·
  suspect_commit v1·v2·ASC dSYM). 미공개(리모트 없음). 테스트 56개 그린, `make demo` 검증됨.

## 현재까지 완료된 것 (믿어도 되는 상태)

v0.1.0 원본(`44e53aa`~`e32142b`) 위에 이어서:

- **실데이터 검증 1~3차**: 공개 실측 6종 — iOS 16 pretty-print `.ips`, Xcode Translated Export
  (flutter), .NET MAUI, iOS 14 MetricKit, macOS 12 `.ips`(빈 문자열 버전 변형→nil 병합 수정),
  iOS 15.1 MetricKit(블로그 실측 덤프 전사). 변형 8종 발견·수정·회귀 고정. 출처는
  `Fixtures/real/README.md`. 평가 후 제외: sentry-cocoa 조각·ChimeHQ/Meter real_report(기존
  변형 재현). jetsam(288) 원본은 공개 미확보.
- **신뢰 패치** (`272448a`): mdfind 대시 UUID 버그(실측 확인) 수정+계약 테스트, `--dsym`
  UUID 검증, seen.json 재수집 이중 카운트 방지, Store 무음 실패 경고.
- **P2 패치** (`d934e49`): 후행 전역 플래그 거부, ProcessRunner 60s 타임아웃, dwarfBinary
  결정성, Store 시그니처 인덱스, MetricKit 프레임 UUID→이미지 역구성, `top --kind`.
- **`.coronerignore`** (`d596e24`) · **CI 게이트 + suspect v1** (`1d81b88`) ·
  **suspect v2: 빌드 태그 범위 + MCP `suspects` 7툴** (`8bd4f77`).
- **ASC dSYM `asc-dsym`**: 공식 ASC API(builds→buildBundles→dSYMUrl, fastlane 동일 사슬 —
  소스 조사로 확정). Core는 순수 부품만(ES256 JWT·.p8 ASN.1 파싱·응답 파싱, 단위 테스트),
  네트워크는 CLI 한정. **라이브 API 검증은 실제 ASC 키 확보 시 대기.**
- **앵커 정밀화 결정**: dwarfdump는 atos와 같은 DWARF 라인 테이블 → 추가 베네핏 없음 실측
  확인, 보류. 소스 없는 심볼(OUTLINED_*)은 어느 쪽도 못 살림.

## 다음 세션 할 일 (우선순위)

### P0 — 실데이터 검증 (계속 — 외부 입력 필요)
1. **자기 앱 실측** — `MXMetricManager` 전달자로 하루 수집 + TestFlight `.ips`(Organizer
   Export·`xcrun devicectl`). 공개 코퍼스로 가능한 분은 소진; 이제 실사용자 데이터가 최고 가치.
2. **jetsam(`bug_type` 288) 원본 확보** — 알려진 변형(threads 없는 body)이나 공개 샘플 미확보.
   확보 시 파서 guard(threads/usedImages/exception 필요)가 거부하는지 확인 후 tolerant 확장.
3. 변형 발견 → fixture 잠그고 파서 확장 + `Fixtures/real/README.md` 출처 표 갱신.

### P1 — suspect_commit 고도화 (해자 1의 깊이 파기)
1. **라이브 ASC 검증** — 사용자가 ASC API 키 제공 시 `asc-dsym` 실동작 확인(환경변수 3종,
   README 심볼리케이션 섹션 참조). 실패 양상(dSYMUrl 미포함·비트코드 아님)별 메시지 다듬기.
2. **indexstore-db** — Xcode 미포함(실측). SourceKit-LSP 번들 탐지 시에만 켜는 경로가 유일.
   베네핏 재평가 전까지 atos sourceFile 앵커 유지.
3. 아이디어 후보: dSYM UUID→커밋 빌드 태그 연결(suspect 범위 정확화 심화), digest에
   suspects 섹션 포함.

### P2 — 공개 준비 (사용자 승인 gate)
- 리모트 생성·push → CI 실작동 확인(현 CI yaml은 미실행). Unreleased가 쌓였으니 태그는
  `v0.2.0` 검토. CHANGELOG Unreleased → 버전 섹션화, main.swift version 갱신.
- **푸시/공개는 사용자 결정 사항 — 임의 진행 금지.**

## 함정·결정 기록 (다시 읽기)

- 저장 포맷 JSON(기획서 YAML) — 의존성 0 의도된 편차. 저널 스키마는 호환 인터페이스 —
  필드 추가는 가산적으로만(sourceAnchors·suspects가 그 예).
- `Fixtures/real/`에는 공개 게시물 실측만 — 비공개 유저 텔레메트리 금지(AGENTS 6조).
- 테스트 수 바꾸면 README·AGENTS "56" 표기 3곳 동시 갱신.
- 스텁 러너가 외부 CLI 계약(mdfind 대시·git 인자)을 가릴 수 있음 — 계약 테스트 패턴을
  새 외부 연동마다 추가할 것(testSpotlightQueryUsesDashedUUID·testBuildTagRange… 참조).
- 전역 플래그(`--store` 등)는 명령 앞. `new-since` exit 1은 CI 게이트 정상 동작.
- ASC 네트워크 호출은 CLI(`main.swift` httpGet*)에만 — 코어 무네트워크 불변식(AGENTS 1조) 준수.
- MetricKit 전달은 일간 미만 — "일간 부검실" 기대치 유지.

## 참조

- 기획서/차별화 전략: `기획서.md` · 에이전트 작업 지침: `AGENTS.md` · 사용법: `README.md`
- 포트폴리오 맥락: 형제 프로젝트 `../breadcrumb`(UI↔코드 지도), `../tombstone`(기각 원장) —
  suspect_commit 교차 결과를 tombstone 묘비로 넘기는 상호 판매 구조가 기획서에 명시됨.
