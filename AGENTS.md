# AGENTS.md — coroner

이 저장소에서 작업하는 AI 코딩 에이전트용 지침. 사람 기여자는 [README.md](README.md)와
[기획서.md](기획서.md)를 먼저 읽을 것. 충돌하면 기획서 > README > 이 파일 순.

## 이 저장소는 (30초 요약)

iOS 프로덕션 텔레메트리(`.ips` + MetricKit)를 로컬에서 수집·심볼리케이션·클러스터링해
에이전트가 MCP로 질의하는 부검 도구. **의존성 0, LLM 불요, 완전 로컬**이 제품 정체성이자
설계 제약이다.

## 명령 (반드시 저장소 루트에서)

```bash
swift build            # 증분 빌드, 수 초
swift test             # 50개 XCTest — 실 dSYM·네트워크 없이 전부 로컬. 커밋 전 필수
swift build -c release
make demo              # /tmp에서 end-to-end 데모 (ingest → new-since → top)
```

주의: 셸 작업 디렉터리가 다른 저장소로 남아 있으면 `swift test`가 엉뚱한 패키지를
돌린다. 항상 `cd /path/to/coroner &&`를 붙이는 습관.

## 구조 지도

```
Sources/CoronerCore/          라이브러리 타깃 — 모든 로직은 여기에
  Models.swift                도메인 타입(DiagnosticKind·RawFrame·ClusterReport) + BuildNumber 비교
  Parsers.swift               TelemetryParser: .ips 2-part(메타데이터+본문 병합)/단일 JSON,
                              MetricKit 단일/JSON Lines, BOM 제거, tolerant decoding
  Symbolicator.swift          DSymLocating 프로토콜(SearchPath→Spotlight 체인, UUID 캐시),
                              AddressMath(순수 함수 — 주소 산술은 여기서만), atos 출력 파싱
  Store.swift                 클러스터 저널: 병합·first_seen 백필·setStatus·within(period) 질의,
                              시그니처 인덱스, seen.json 지문 장부
  Discovery.swift             파일 탐색 — 숨김·.coroner/.git/.build/DerivedData 제외,
                              .coronerignore(gitignore 하위집합, CoronerIgnore)
  Suspector.swift             suspect_commit 추정 — first_seen 윈도우 git log × 소스 앵커 교차
  Digest.swift                결정적 Markdown 일지 생성
  MCPEngine.swift             손작성 stdio JSON-RPC 2.0 엔진 + CoronerMCP 6툴 팩토리
  Renderer.swift              CLI/MCP 공유 텍스트 렌더링 + 경로 마스킹
Sources/coroner/main.swift    CLI 엔트리(top-level 코드). 파싱·출력만 — 로직 추가 금지, 코어로
Tests/coronerTests/           XCTest + Fixtures/(synthetic + real/ — 실측 코퍼스, 출처는 Fixtures/real/README.md)
Examples/demo/                README 트랜스크립트의 입력 파일
```

## 불변식 (깨뜨리면 제품 정체성이 무너진다)

1. **코어에 LLM·네트워크 호출 금지.** 같은 입력 → 같은 바이트 출력이 계약이다.
   digest·시그니처·id가 결정적인 이유가 이것.
2. **외부 의존성 추가 금지.** `Package.swift`의 dependencies는 빈 배열이어야 한다.
   YAML 쓰기조차 직접 구현 대신 JSON으로 우회한 이유.
3. **파서는 tolerant.** 알 수 없는 키·필드·포맷 변형에서 절대 크래시/throw 금지.
   새 포맷 변형을 발견하면 fixture로 잠그고 파서를 넓혀라.
4. **클러스터 id·시그니처 체계는 호환성 인터페이스다.** 기존 저널(`reports/*.json`)이
   로드되지 않게 하는 변경은 마이그레이션 코드 없이는 금지.
5. **MCP 응답은 한 줄 JSON.** 개행 포함 텍스트는 반드시 `content[].text` 내부로.
6. **프라이버시 기본값.** 출력 경로의 홈 접두사 마스킹 유지. 텔레메트리 원본을
   절대 커밋하지 않는다(비공개 유저 데이터 금지). fixture는 원칙적으로 synthetic;
   예외적으로 `Fixtures/real/`에는 **공개 게시물에 첨부된** 실측 텔레메트리만
   허용하며 출처를 `Fixtures/real/README.md` 표에 기록한다.
7. **`.coroner/`는 런타임 데이터.** gitignore되어 있으니 예제 저널을 커밋하지 말 것.

## 테스트 관습

- 자식 프로세스(atos·mdfind)는 `ProcessRunning` 프로토콜 뒤에서 스텁 — 실 dSYM이
  필요한 테스트는 없어야 한다.
- 저장소 테스트는 `tempStore()` 헬퍼로 임시 디렉터리를 쓴다. 절대 상대경로
  `.coroner`에 쓰지 않는다.
- 날짜 의존 테스트 금지 — `hangReport`/`within`처럼 `now:` 주입 가능한 API로
  견정성을 확보한다(시간대·시각 무관 통과).
- 새 동작 = 실패하는 테스트 먼저, 그다음 구현.

## 자주 하는 실수

- 기획서(YAML)와 실제 포맷(JSON)의 차이 — 의도된 편차다. README "기획서 대비
  정직한 편차" 섹션을 먼저 읽고 새 편차는 거기에 기록할 것.
- `main.swift`에 로직을 붙이는 것 — CLI는 얇게. 질의 로직은 `Store`, 렌더링은
  `Renderer`, 새 인터페이스는 `CoronerMCP` 패턴 따르기.
- 버전 문자열은 `Sources/coroner/main.swift`의 `let version` 단일 소스 —
  다른 곳에 하드코딩 금지.

## 릴리스 체크리스트

1. `swift test` 그린 (로컬)
2. `CHANGELOG.md`에 항목 추가
3. `main.swift`의 `version` 갱신 — MCP `serverInfo`로 흘러간다
4. README의 테스트 수·트랜스크립트가 실제 실행 결과와 일치하는지 확인
   (트랜스크립트는 반드시 실제 출력으로 갱신 — 손으로 다듬지 않는다)
5. 태그: `git tag v0.x.y`
