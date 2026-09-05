# Fixtures/real — 실측 텔레메트리 코퍼스

공개적으로 게시된 실제 크래시 텔레메트리로, 파서가 실세계 포맷 변형에서 회귀하지 않게
잠그는 회귀 테스트 입력. **비공개/사내 유저 텔레메트리는 절대 이 디렉터리에 넣지 않는다** —
공개 게시물에 첨부된 것만.

| 파일 | 출처 | 잠긴 변형 |
|---|---|---|
| `ios16-pretty-printed.ips` | [MacSymbolicator](https://github.com/inket/MacSymbolicator) 테스트 코퍼스 (iOS 16, iPhone OS 16.0) | pretty-print 본문 JSON 내부의 빈 줄 — `\n\n` 분할 오인식 |
| `metrickit-ios14-real.json` | [Sherlouk gist](https://gist.github.com/Sherlouk/58f4cecef3e839f64a2c1e66530eb961) (iOS 14 MXDiagnosticPayload) | `callStackRootFrames`, `deviceType`, 복수형 disk 키, payload 최상위 타임스탬프, 숫자 `exceptionType` |
| `xcode-translated-flutter-241.ips` | [flutter/flutter#148927](https://github.com/flutter/flutter/issues/148927) 첨부 (iOS 앱 "Runner", 2024-05) | Xcode "Translated Report" 내보내기 — 사람이 읽는 리포트 뒤에 원본 JSON 첨부 |
| `dotnet-maui-241.ips` | [dotnet/maui#29641](https://github.com/dotnet/maui/issues/29641) 첨부 (iOS 15.8.4) | 타 툴체인(.NET MAUI) 앱의 동일 포맷 — 도구 가정 방어 |
| `macos-monterey-309.ips` | [xsscx/srd](https://github.com/xsscx/srd) 연구 코퍼스 (macOS 12.3.1) | macOS `.ips` 교차 검증 + `app_version`/`build_version`이 **빈 문자열**로 오는 실측 변형(nil로 병합) |
| `metrickit-ios15-real.json` | [Jorgon 블로그](https://393698063.github.io/) 게시 실측 덤프(iOS 15.1)에서 JSON으로 충실히 전사 | iOS 15+ MetricKit 형태 — 수치형 `exceptionType`/`signal`, `deviceType`, 프레임 `binaryUUID` |

샘플 추가 시 출처를 이 표에 기록할 것. 평가 후 제외된 후보: sentry-cocoa `MetricKitCallstacks`(단독 페이로드 아님),
단독 페이로드가 아니라 `callStackTree` 조각이라 제외했다 (`tree-garbage.json`은 고의로
잘린 JSON — 우리 파서가 거부하는 게 정상).
