# coroner

> Sentry는 크래시를 대시보드에 가둔다. coroner는 부검 보고서를 에이전트 터미널로 가져온다 —
> "2.1.0의 신규 크래시 1건. `SessionStore.dequeue(sessionStore.swift:88)`의 인덱스 오버런. 2.0.9에서는 0건이었고, 이 빌드에 들어간 커밋은 이것."

**coroner**는 iOS 프로덕션 텔레메트리(`.ips` 크래시, MetricKit `MXDiagnosticPayload` — crash/hang/CPU exception/disk-write)를
로컬에서 수집 → dSYM 심볼리케이션 → 결정적 클러스터링 → 버전 저널(first_seen/last_seen)로 정리하고,
코딩 에이전트가 MCP로 질의하게 만드는 완전 로컬 도구다.

- **완전 로컬**: 텔레메트리는 내 기기의 부검실(`.coroner/`)에만 존재. 원격 전송 0
- **결정적**: 파싱·심볼리케이션·클러스터링·저널에 LLM 불요. 같은 입력 → 같은 보고서
- **에이전트 네이티브**: MCP stdio 서버 6툴 — "2.1.0이 141 대비 새로 생긴 크래시 알려줘"가 한 번의 툴 콜

[English](#english) · 기획서: `기획서.md` (설계 배경과 차별화 전략)

---

## 왜 필요한가

1. `.ips`/MetricKit은 Xcode Organizer에 갇혀 있고, 질의할 수 없는 덩어리다
2. 심볼리케이션은 부품(MXSymbolicate, MacSymbolicator, `xcrun crashlog`)을 사람이 수동으로 잇는 수공업
3. "이 크래시 알려진 건가? 이번 버전에 새로 생긴 건가?"의 답이 어디에도 기록되지 않는다
4. 수정은 코딩 에이전트가 하는데, 에이전트는 Crashlytics/Sentry 웹 UI를 볼 수 없다 — **증거를 못 보는 주체에게 수정을 시키는 중**

coroner는 이 파이프라인의 소비 측(개발 기기)을 채운다. Sentry/Crashlytics는 *수집* SaaS고, coroner는 그 반대편이다 — 경쟁이 아니라 다음 칸.

## 설치

```bash
git clone <this-repo> && cd coroner
make release            # swift build -c release
make install            # → /usr/local/bin/coroner (선택)
```

macOS 13+, Xcode 툴체인(Swift 5.9+). 외부 의존성 0.

## Quickstart (실제 출력)

```console
$ coroner ingest Examples/demo/*
ingested 6 file(s) → 8 report(s) [4 crash, 2 hang, 1 cpu-exception, 1 disk-write]
journal: 5 new, 3 updated cluster(s) → 5 total
note: 8 report(s) stayed unsymbolicated (dSYM not found — pass --dsym or install via Spotlight)

$ coroner new-since 141
NEW since build 141: 4 cluster(s)
c-20260904-967cb4b5  [crash]  2026-09-04→2026-09-05  3x  DemoApp+0x1010 → DemoApp+0x2020 → libsystem_c.dylib+0x1000
c-20260905-511a61d2  [hang]   2026-09-05→2026-09-05  2x  DemoApp+0x800 → DemoApp+0x1010
c-20260905-f9a50921  [cpu-exception]  2026-09-05→2026-09-05  1x  DemoApp+0x2000
c-20260905-0164a025  [disk-write]  2026-09-05→2026-09-05  1x  DemoApp+0x3000

$ coroner is-known "DemoApp+0x1010"
KNOWN — 2 matching cluster(s):
c-20260904-967cb4b5  [crash]  2026-09-04→2026-09-05  3x  DemoApp+0x1010 → DemoApp+0x2020 → libsystem_c.dylib+0x1000
c-20260905-511a61d2  [hang]   2026-09-05→2026-09-05  2x  DemoApp+0x800 → DemoApp+0x1010

$ coroner mark c-20260904-967cb4b5 --status known
c-20260904-967cb4b5 → status: known

$ coroner digest --period week
digest written: /private/tmp/coroner-demo2/.coroner/digest/digest-20260905-0517.md (5 cluster(s) in period week)

$ coroner show c-20260904-967cb4b5
id: c-20260904-967cb4b5
kind: crash
status: known  symbolicated: no
signature: DemoApp+0x1010 → DemoApp+0x2020 → libsystem_c.dylib+0x1000
exception: EXC_CRASH SIGABRT
builds: first_seen 142, last_seen 143
occurrences:
  - 142: 2
  - 143: 1
devices: iPhone14,2(1), iPhone15,3(2)
os: iOS 19.1(3)
top frames:
  0. DemoApp+0x1010
  …
```

### 심볼리케이션

dSYM을 찾는 순서: `--dsym <path>` (반복 가능) 및 `CORONER_DSYM_PATHS` 환경변수 → Spotlight(`mdfind com_apple_xcode_dsym_uuids == <UUID>`) → UUID 불일치·미발견이면 **프레임은 symbolicated: false로 유지** (오류가 아닌 정상 상태).

```bash
coroner --dsym ~/dSYMs/ ingest ~/Downloads/crashes/     # 2026-09-04 빌드의 dSYM 묶음
```

- `.ips` 크래시: `addr = image.base + imageOffset`, `atos -o <dSYM> -l <base>`
- MetricKit: `addr = textSegmentVMAddr(기본 0) + offsetIntoBinaryTextSegment`

## MCP 서버 (에이전트 연결)

```bash
coroner --store ~/journals/myapp mcp     # stdio JSON-RPC 2.0
```

Claude Code (`claude_desktop_config.json` / `.mcp.json`):

```json
{
  "mcpServers": {
    "coroner": {
      "command": "/usr/local/bin/coroner",
      "args": ["--store", "/Users/me/journals/myapp", "mcp"]
    }
  }
}
```

직접 손으로 확인:

```console
$ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | coroner mcp
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2024-11-05","serverInfo":{"name":"coroner","version":"0.1.0"}}}
```

| tool | 설명 |
|---|---|
| `new_since` | `{build}` — 지정 빌드 이후 처음 발견된 클러스터. **릴리스 다음 날 첫 질문** |
| `top_crashes` | `{n?, kind?}` — 발생 수 상위 클러스터 |
| `crash_detail` | `{id}` — 클러스터 부검 보고서 전문 (모든 kind) |
| `is_known` | `{signature}` — 시그니처/프레임 부분 일치. "UNKNOWN → 새 실패로 취급" |
| `hang_report` | `{period?}` — 메인스레드 hang 기간별 집계 |
| `digest` | `{period?}` — 결정적 Markdown 일지 |

## 저널 저장소

`--store`(기본 `.coroner/`) 아래:

```
.coroner/
├── reports/c-20260904-967cb4b5.json   # 클러스터 1개 = 보고서 1개 (YAML 스키마의 JSON 직렬화)
└── digest/digest-20260904-2338.md
```

```json
{
  "id": "c-20260904-967cb4b5",
  "kind": "crash",
  "signature": "DemoApp+0x1010 → DemoApp+0x2020 → libsystem_c.dylib+0x1000",
  "firstSeenBuild": "142", "lastSeenBuild": "143",
  "occurrences": {"142": 2, "143": 1},
  "devices": {"iPhone15,3": 2, "iPhone14,2": 1},
  "osVersions": {"iOS 19.1": 3},
  "status": "open", "symbolicated": false
}
```

- 시그니처 = 정규화 상위 3프레임(심볼 있으면 심볼, 없으면 `binary+offset`) — 결정적
- id = `c-<첫발견일>-<SHA256(시그니처) 앞 8hex>`
- 프라이버시: 출력 경로의 홈 디렉터리 접두사 기본 마스킹 (`--no-mask`로 해제)

## CLI 레퍼런스

```
coroner [--store <dir>] [--dsym <path>...]
  ingest <file|dir>...                       # .ips·MetricKit JSON(단일/JSON Lines) 자동 판별, 재귀 수집
                                             # (.coroner/.git/.build는 자동 제외)
  list [--kind crash|hang|cpu|disk] [--limit n]
  show <cluster-id>
  new-since <build>
  top [n]
  is-known "<signature substring>"
  hang-report [--period today|week|all]
  digest [--period today|week|all]           # 기간 내 last_seen 클러스터만
  mark <cluster-id> --status open|known|fixed-in   # 트리아지 판정 기록 (저널 루프 닫기)
  mcp                                        # MCP stdio 서버
```

## 기획서 대비 정직한 편차

- **저장 포맷**: 기획서는 YAML — 외부 의존성 0 원칙을 위해 **JSON 직렬화**로 구현 (스키마 동일, 문서화)
- **MCP 6툴**: 기획서 v0.2 범위 그대로 구현. digest는 LLM 없는 결정적 Markdown만 (기획서 원칙: "결정적 부분에 LLM 불요")
- **`mark` 명령은 추가**: 기획서 CLI 목록에 없지만, `status` 필드(open/known/fixed-in)를 바꾸는 수단이 없으면 트리아지 판정이 저널에 축적되지 않아 루프가 닫히지 않음 — v0.1에서 보강
- **클러스터링**: 정규화 시그니처 정확 매칭. 유사도 폴백(ReBucket식)은 v1.x — GPTrace(LLM 임베딩)도 그때 인용
- **`.coronerignore` 미구현**: 기획서 v0.2 옵션(수집 제외 패턴). 현재는 내장 제외(`.coroner`/`.git`/`.build`/숨김 디렉터리)만 — v0.3 계획
- **v0.3 미포함**: App Store Connect API dSYM 자동 다운로드, git diff와의 suspect_commit 교차, CI 게이트
- **테스트의 심볼리케이션**: atos·dSYM 의존을 프로토콜 뒤로 격리 — 실 dSYM 없이도 41개 테스트 전부 로컬 실행
- **실데이터 코퍼스**: `Tests/coronerTests/Fixtures/real/` — 공개된 실제 텔레메트리(iOS 16 `.ips`, iOS 14 MetricKit 페이로드)로 포맷 변형을 잠근 회귀 테스트

## 로드맵

```
v0.3  suspect_commit — first_seen 빌드 전후 git diff 교차 + indexstore-db 프레임→소스 앵커
      App Store Connect dSYM 자동 다운로드, CI 게이트(빌드마다 new_since 차단), .coronerignore
v1.x  스택 유사도 클러스터링 옵션(ReBucket식 / GPTrace식 임베딩), macOS 앱 지원,
      SaaS 역링크 내보내기(= Sentry 이슈 URL 부착), Android tombstone(네이티브 크래시 덤프) 지원
```

## 개발

```bash
make test        # swift test — 41 tests, 전부 로컬(실 dSYM·네트워크 불요), 수 초
make release
```

아키텍처: `TelemetryParser`(.ips 2-part/단일 JSON, MetricKit 단일/JSON Lines, tolerant decoding) → `Symbolicator`(dSYM 로케이터 체인 + atos 배치 호출) → `Store`(저널 병합·질의) → CLI/MCP. 코어는 `CoronerCore` 라이브러리로 분리 — MCP 서버를 다른 호스트에 심는 것도 가능.

## English

**coroner** is a fully local, deterministic post-mortem triage tool for iOS telemetry. It ingests `.ips` crash reports and MetricKit diagnostic payloads (crash / hang / CPU exception / disk-write), symbolicates them against local dSYMs (search paths + Spotlight, graceful unsymbolicated state), clusters them by normalized top-frame signatures, maintains a version journal (first/last seen build, per-build occurrences), and exposes six MCP tools so coding agents can ask "what's new since build 141?" without ever touching a SaaS dashboard. Zero third-party dependencies; Swift 5.9+, macOS 13+. See the Korean sections for the full story — the CLI is self-documenting via `coroner --help`.

## License

MIT — see [LICENSE](LICENSE).
