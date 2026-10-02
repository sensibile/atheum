# CLI envelope 배타성 결함 수정

2026-10-02. F1을 수정하고 최종 소스의 자체 회귀를 완료했다. 별도 독립 확인은 다음 단계이며 코드를 멈춘다.

## 실패 전후와 원시 증거

기존 최종 독립 보고서·테스트·증거는 수정하지 않았다. 원본 테스트 `final_test.exs:129`를 같은 seed/명령으로 실행했다.

- 수정 전 [before.raw](before.raw), [before.exit](before.exit): exit 2, 0/1 passed. 실제 Akashic version=2이지만 PG는 failed/confirmed_absent, recover는 not_recoverable.
- 최종 소스 [after.raw](after.raw), [after.exit](after.exit): exit 0, 1 passed. 동일 모순 envelope는 transport_failure, PG는 unresolved/unknown/stop_confirmed=false. 원본 테스트의 실제 recovery는 성공하여 기존 request ID/payload의 version=2 receipt를 반환한다.
- 첫 수정 직후 결과는 after-first.raw/exit로 별도 보존했다. 최종 결과는 중복 key 검사까지 포함한 최종 Wire 소스에서 다시 실행한 것이다.

## 최소 수정

생산 수정은 `lib/atheum/wire.ex` 한 파일이다. Core의 상태/효과 판단, 실행 접수, request ID, retry opt-in, target·취소·deadline 검사, journal 및 stale fence는 변경하지 않았다.

1. 응답의 최상위 필드를 먼저 검증한다. 성공은 정확한 `ok/result` + boolean true + exit 0, 실패는 정확한 `ok/error` + boolean false + CLI 계약 exit 2다. result/error 동시 존재, 반대 필드가 null인 경우, unknown/누락 필드, 잘못된 타입 또는 exit 불일치는 모두 transport_failure다.
2. 성공 결과는 command별 필수 필드와 타입을 검증한다. Apply는 apply 필수, 선택 I/O metadata(open_work/write_work)는 map만 허용한다. 실제 도메인 결과는 정확한 changed/difference/version/work 구조를 요구한다. Impact/Validate도 필수 필드 집합을 확인한다.
3. Error는 정확한 code/detail 두 문자열을 요구하며 code는 비어 있을 수 없다. 오류의 추가 성공 정보나 불완전 구조를 확정 거부의 근거로 쓰지 않는다.
4. JSON decoder callback으로 중복 key를 거절한다. 복수 JSON 값·trailing data도 거절한다. 기존 depth/byte/time cap은 유지한다. 컴파일러가 decoder 옵션의 keyword 타입을 요구한 중간 경고는 코드를 수정해 해결했으며 gate를 억제하지 않았다.

변경 파일: Wire, 신규 `test/envelope_test.exs`, 기존 `test/cycle_integration_test.exs`에 새 테스트 추가, README의 현재 계약/증거 링크, 이 증거 디렉터리. 기존 테스트는 삭제하거나 기대를 약화하지 않았다.

## 대칭 회귀와 실제 효과

새 빠른 회귀는 양방향 result/error 혼합, null 반대 필드, ok/exit 불일치, 누락·extra 필드, 오류 code/detail 타입, nested 결과 모순, Impact/Validate의 공통 배타성, duplicate key와 trailing JSON을 검사한다. 정상 성공과 정상 거부를 함께 확인한다.

실제 Akashic 커밋 뒤 wrapper가 6개 변형을 만든다: false+success result, true+error, false+null result, true+null error, missing ok, incomplete rejection. 모두 실제 graph 차단과 version 상승을 확인한 뒤 PG의 unknown과 동일 receipt 복구를 검증한다. 실행마다 같은 invocation/execution/request/payload 유지와 새 attempt를 확인하고, 재전달 뒤 version의 추가 상승이 없음을 실제 impact 조회로 확인한다. reset은 fixture 준비용 별도 Apply다.

[review.raw](review.raw)의 `ENVELOPE_VARIANT` 행에 정확한 응답·분류·회수 version·same_request=true를 남겼다. [all-regression.raw](all-regression.raw)에도 최종 source 재실행 결과가 있다.

## 최종 검사

- [precommit.raw](precommit.raw): format, 강제 compile/warnings-as-errors, Credo strict, Dialyzer, 빠른 14개 PASS. [단계별 report](../../artifacts/20261002T014647576657Z-precommit/report.json).
- [review.raw](review.raw): 동일 gate + 실제 I/O 포함 28개 PASS. [단계별 report](../../artifacts/20261002T014321647839Z-review/report.json).
- Credo strict issues 0. Dialyzer errors 0, skipped 0, unnecessary skips 0. suppression/ignore 추가 없음.
- 원본 final-independent 10개 + sensitivity 3개 + 이전 독립 6개 + 현재 28개를 함께 실행: [all-regression.raw](all-regression.raw)의 47 PASS, exit 0. 수정자가 기존 독립 사례를 재실행한 것으로 새 독립 검증 성공을 주장하지 않는다.
- [hook.raw](hook.raw): 기존 격리 hook의 staged export/부분 staging 거절/index 불변 PASS. Hook 코드나 실제 index는 수정하지 않았다.
- [preservation.json](preservation.json): 기존 final-independent 증거 전체 및 Core 불변. [source-hashes.json](source-hashes.json)에 최종 source를 고정했다.
- Akashic binary SHA-256은 전후 `eeacb10fefdbf76bd086c7288aa9eab0a202aca57e5f1d27d1a754b93f446230`으로 동일하다.

## 재현

Atheum 디렉터리에서 기존 전용 PG와 binary만 사용한다.

```sh
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
HEX_HOME="$PWD/.cache/hex" \
mix test verification/final-independent/final_test.exs:129 \
  --include integration --seed 20261002 --trace

./scripts/check precommit
ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
./scripts/check review

ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
HEX_HOME="$PWD/.cache/hex" \
mix test test verification/final-independent/final_test.exs \
  verification/final-independent/sensitivity_test.exs \
  verification/independent-20261002/independent_test.exs \
  --include integration --seed 20261002 --trace
python3 scripts/check-hook
```

## 유지한 한계

검증은 전용 `atheum_cycle_test`와 테스트별 임시 Akashic DB에서 수행했다. 기존 업무 DB, 다른 프로젝트, 인가/gateway/권한/네트워크 설정, 전역 설치, Git commit/remote/push, 배포는 변경하지 않았다.

이 수정은 모순·불완전 프로토콜을 보수적으로 처리하며, 신뢰된 executable의 완전히 일관된 거짓 응답까지 증명하는 인증 기능은 아니다. cancel/deadline 뒤 재전달 금지, receipt 보존·동일 DB 생애 전제, 순수 receipt 조회 부재, Port.close≠정지 확인, 임의 외부효과 exactly-once 비보장은 그대로다. CLI가 새로운 필드/exit 계약으로 바뀌면 명시적 adapter 계약 갱신 전까지 unknown으로 남는다.
