# Changelog

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
