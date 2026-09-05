# HANDOFF — 다음 세션 인수인계

- **작성일**: 2026-09-05 (2차 갱신) · **기준**: main (커밋은 아래 각 항목 참조)
- **상태**: v0.1.0 + Unreleased(실데이터 검증 2차·신뢰 패치·P2 패치·.coronerignore·CI 게이트·suspect_commit v1·v2).
  미공개(리모트 없음). 테스트 52개 그린, `make demo` 검증됨.

## 현재까지 완료된 것 (믿어도 되는 상태)

v0.1.0 원본(`44e53aa`~`e32142b`) 위에 이어서:

- **실데이터 검증 1·2차** (`4154ac9`, `36b6a3a`): 공개 실측 4종(iOS 16 pretty-print `.ips`,
  Xcode Translated Export, .NET MAUI, iOS 14 MetricKit)으로 변형 6종 발견·수정·회귀 고정.
  `Fixtures/real/README.md`에 출처 표. sentry-cocoa 조각은 평가 후 제외.
- **신뢰 패치** (`272448a`): mdfind 대시 UUID 버그(실측 확인) 수정+계약 테스트, `--dsym`
  UUID 검증(오심볼 방지), seen.json 재수집 이중 카운트 방지, Store 무음 실패 stderr 경고.
- **P2 패치** (`d934e49`): 후행 전역 플래그 거부, ProcessRunner 60s 타임아웃, dwarfBinary
  결정성, Store 시그니처 인덱스(O(1) 병합), MetricKit 프레임 UUID→이미지 역구성, `top --kind`.
- **`.coronerignore`** (`d596e24`): gitignore 하위집합, 정규식 변환 글롭, 루트별 적용.
- **CI 게이트 + suspect_commit v1** (마지막 커밋): `new-since` exit 1 게이트(+README Actions
  예제), `coroner suspect <id>` — first_seen ±14일 git log × sourceAnchors(atos sourceFile)
  교차, 실제 git 저장소로 e2e 검증. 저널 스키마 가산 필드(sourceAnchors·suspects) — 구 저널 호환.

## 다음 세션 할 일 (우선순위)

### P0 — 실데이터 검증 3차 (외부 입력 필요 — 사용자 몫)
1. **iOS 15+ MetricKit 실측 페이로드** — 현재 코퍼스가 iOS 14 샘플뿐. 자기 앱에
   `MXMetricManager` 전달자 넣고 하루 수집이 가장 확실. 공개 샘플 발견 시 `Fixtures/real/` 추가.
2. 자기 TestFlight 앱 `.ips`(Xcode Organizer Export·`xcrun devicectl`)로 상동.
3. 변형 발견 → fixture 잠그고 tolerant 파서 확장. 새 fixture는 `Fixtures/real/README.md` 출처 표 갱신.

### P1 — suspect_commit 고도화 (해자 1의 깊이 파기)
**v2 완료(2026-09-05)**: ① 빌드 태그 매핑(`build/241`류 태그 → 직전 빌드 태그..first_seen 태그의
정확한 커밋 범위, 점 버전 태그 거부, 태그 없으면 날짜 창 폴백) ② MCP 7번째 툴 `suspects` 추가
(README 편차 섹션 기록) ③ indexstore-db는 Xcode 미포함 확인(실측) — atos sourceFile 앵커 유지,
SourceKit-LSP 번들 탐지 시에만 켜는 후보로 문서화. 실제 임시 git 저장소 e2e 테스트 포함(52 tests).
남은 것:
1. **앵커 정밀화 후보** — dSYM DWARF에서 타입 단위 앵커(dwarfdump) 또는 SourceKit-LSP 번들
   탐지 시 indexstore-db. 착수 전 베네핏 평가부터(현 atos 앵커로 실측 코퍼스에서 충분히 교차됨).
2. **ASC dSYM 자동 다운로드** — 미구현 상태 유지. 이유: ① 코어 무네트워크 불변식(AGENTS 1조)과
   충돌 — CLI 서브커맨드에서 curl 호출 + ES256 JWT는 CryptoKit로 무의존 서명 가능하나
   ② 실제 ASC 키 없이는 검증 불가. 착수 조건: 사용자가 ASC API 키(CORONER_ASC_KEY_ID/
   ISSUER/KEY_PATH 환경변수 설계안) 제공 시.

### P2 — 공개 준비 (사용자 승인 gate)
- 리모트 생성·push → CI 실작동 확인(현 CI yaml은 미실행). 태그 `v0.1.0`…단 Unreleased가
  쌓였으니 버전 올려 `v0.2.0` 검토. CHANGELOG Unreleased → 버전 섹션화, main.swift version 갱신.
- README Quickstart 트랜스크립트는 2026-09-05 실출력으로 갱신 완료(재수집 노트·게이트 exit
  코드·suspect 정직 빈답 포함) — 릴리스 시점에 다시 실출력 갱신.
- **푸시/공개는 사용자 결정 사항 — 임의 진행 금지.**

## 함정·결정 기록 (다시 읽기)

- 저장 포맷 JSON(기획서 YAML) — 의존성 0 의도된 편차. 저널 스키마(`reports/*.json`)는 호환
  인터페이스 — 필드 추가는 가산적으로만(sourceAnchors·suspects가 그 예).
- `Fixtures/real/`에는 공개 게시물 첨부 실측만 — 비공개 유저 텔레메트리 금지(AGENTS 6조).
- 테스트 수 바꾸면 README·AGENTS "50" 표기 3곳 동시 갱신.
- 스텁 러너가 외부 CLI 계약(mdfind 대시 등)을 가릴 수 있음 — 계약 테스트 패턴
  (testSpotlightQueryUsesDashedUUID)을 새 외부 CLI 연동 때마다 추가할 것.
- 전역 플래그(`--store` 등)는 명령 앞. CI 게이트로 `new-since` exit 1이 정상 동작 —
  스크립트 체인에서 주의(make demo는 이미 `; echo exit=$?` 처리).
- MetricKit 전달은 일간 미만 — "일간 부검실" 기대치 유지.

## 참조

- 기획서/차별화 전략: `기획서.md` · 에이전트 작업 지침: `AGENTS.md` · 사용법: `README.md`
- 포트폴리오 맥락: 형제 프로젝트 `../breadcrumb`(UI↔코드 지도), `../tombstone`(기각 원장) —
  suspect_commit 교차 결과를 tombstone 묘비로 넘기는 상호 판매 구조가 기획서에 명시됨.
- suspect_commit v2(2026-09-05): 빌드 태그 범위 매핑 + MCP `suspects` 툴 + 실제 git e2e.
  indexstore-db는 Xcode 미포함(실측)으로 atos 앵커 유지 — 근거는 CHANGELOG Unreleased.
