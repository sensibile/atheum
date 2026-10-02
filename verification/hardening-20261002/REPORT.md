# Atheum 안전 경계·정적 분석 보완

2026-10-02. 기존 독립 정답/보안 검증의 관찰을 바탕으로 승인된 첫 Function 범위만 보완했다. 이 문서는 수정자의 자체 회귀 기록이며 새 독립 최종 검증은 대기 중이다.

## 재현 전후

기존 [보안 보고서](../security-20261002/REPORT.md), probe 및 raw 증거는 수정하지 않았다. 과거 probe는 당시 결함을 기대하는 assertion이므로 현재 회귀 gate가 아니다.

| 관찰 | 수정 전 근거 | 수정 후 근거 |
| --- | --- | --- |
| DB URL dbname override | 전용 테스트 DB만 이용한 decoy?dbname=atheum_cycle_test가 실제 cycle DB로 연결됨 | query/fragment/password/escaped components를 연결 전 거절. fixture의 실행 marker가 없고 실제 전용 DB 테스트에서도 invalid_configuration. 정상 연결의 current_database는 atheum_cycle_test |
| PG 무기한 대기 | 10ms 설정에도 fake psql 250ms 대기 및 실제 pg_sleep(0.25) 성공 | 관찰 timeout, connect/statement/lock timeout 도입. 무응답 fixture는 journal_timeout, 실제 전용 PG 지연은 journal_timeout 또는 statement 취소 journal_failure. timeout은 commit/효과 부재 증거가 아님 |
| 무제한 응답 | 4MiB CLI 응답 수용 | 공통 Port 관찰의 누적 byte cap 1MiB. 4MiB fixture는 output_limit. 지속 출력 중에도 monotonic deadline을 먼저 확인. CLI JSON depth 32 초과도 거절 |
| malformed 성공 확정 | 빈 apply result가 succeeded/absent, changed 문자열이 present | 요청별 schema/type/u64/expected version 관계 검증. 빈 값·문자열·배열·무관한 version은 transport_failure 및 unresolved/unknown. 실제 Akashic 커밋 뒤 malformed 응답도 unknown을 남기고 동일 receipt로 복구 |
| staged 의미와 working tree 차이 | 일부 staged 경로만 검사하며 working tree에서 gate 실행 | tracked 부분 staging/unstaged 수정 거절. 실제 index를 임시 export해서 gate 실행. 삭제·untracked 파일 제외 및 원본/fixture index SHA 불변 검증 |

## 수정 파일과 범위

- `lib/atheum/postgres.ex`: 엄격한 연결 요소 검증 및 별도 argv, inherited target/service 옵션 제거, 실제 DB guard, bounded psql, history limit/cursor.
- `lib/atheum/process_io.ex`(신규): PG/CLI 공통 Port의 시간·출력 제한. timeout 1..60,000ms, 누적 stdout/stderr 1,048,576 bytes. Port.close를 child 종료 증거로 주장하지 않는다.
- `lib/atheum/wire.ex`(신규), `akashic.ex`, `core.ex`: JSON depth, Function 성공 결과의 boolean/u64/version·difference/work 검증, Core의 잘못된 성공 입력도 unknown. expected_version u64 상한.
- `lib/atheum.ex`: history paging 전달과 중첩 판단 분리. Function의 접수·취소·복구·stale fence 의미 유지.
- `mix.exs`, `mix.lock`: 공식 Hex의 Credo 1.7.19/Dialyxir 1.4.8을 dev/test/runtime:false로 추가. transitive packages도 hexpm. 글로벌 archive 설치 없음.
- `scripts/check`: precommit/review에 Credo strict/Dialyzer 연결, 프로젝트 HEX_HOME. `.githooks/pre-commit`, `scripts/check-hook`: staged export와 격리 fixture 검증.
- `test/boundary_test.exs`(신규), `test/core_test.exs`, `test/cycle_integration_test.exs`: 새 보수적 응답 계약 및 실제 PG/Akashic 회귀. 기존 no-op 테스트는 올바른 전체 wire schema를 공급하도록 바꿨으며 목적/관찰은 유지했다.
- README/VERIFICATION 최신 링크와 이 디렉터리의 재현 스크립트·로그·해시.

Credo의 중첩/복잡도 지적은 작은 함수 분리로 해결했다. check 비활성화, 경고 ignore 파일, gate 실패 무시를 추가하지 않았다. 최초 source는 unborn HEAD였으므로 이전 보안 보고서의 hash를 전 기준으로 삼고 [source-hashes.json](source-hashes.json)에 수정 후 source를 기록했다. 실제 index는 여전히 비어 있으며 commit/remote/push는 없다.

## 최종 검사 결과

- [최종 review report](../../artifacts/20261002T011942077986Z-review/report.json): 포맷/경고 오류 컴파일/Credo strict/Dialyzer/빠른 테스트/실제 I/O 모두 exit 0.
- Credo strict: issues 0. Dialyzer: errors 0, skipped 0, unnecessary skips 0. PLT와 Hex cache는 `.cache` 안에 있다.
- 빠른 테스트 10 PASS, 실제 I/O 포함 전체 23 PASS. 실제 전용 PG와 임시 RocksDB, 기존 Akashic CLI 사용.
- 기존 독립 테스트 6개를 변경 없이 새 테스트와 재실행: [independent-regression.log](independent-regression.log)의 29 PASS. 수정자가 재실행했으므로 새 독립 검증 성공으로 부르지 않는다. 이전 28 PASS 로그도 별도로 보존했다.
- 실제 staged 프로젝트 fixture: [full-staged-hook.json](full-staged-hook.json)의 exit=0, actual_index_unchanged=true, fixture_index_unchanged=true. [로그](full-staged-hook.log)에서 strict/Dialyzer/빠른 10개 검사 통과.
- 격리 작은 hook fixture: 성공/실패 전달, 부분 staging 거절, 삭제/untracked 파일 제외, index 불변 통과.
- Akashic binary SHA-256은 전후 `eeacb10fefdbf76bd086c7288aa9eab0a202aca57e5f1d27d1a754b93f446230`으로 동일.

## 재현 명령

Atheum 디렉터리에서 기존 전용 서비스와 binary만 사용한다. 검사 entrypoint는 설치하거나 형제 프로젝트를 빌드하지 않는다. 의존성을 처음 받을 때만 공식 Hex를 쓰는 `HEX_HOME="$PWD/.cache/hex" mix deps.get`을 별도 실행한다.

```sh
./scripts/check precommit
ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
./scripts/check review
python3 scripts/check-hook
python3 verification/hardening-20261002/full_staged_fixture.py

ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
elixir -pa _build/test/lib/atheum/ebin \
  -r test/test_helper.exs -r test/core_test.exs -r test/boundary_test.exs \
  -r test/cycle_integration_test.exs \
  -r verification/independent-20261002/independent_test.exs \
  -e 'Application.ensure_all_started(:crypto); ExUnit.configure(exclude: [], seed: 20261002)'
```

## 보존한 경계와 한계

Axiom/Akashic 소스·설정, 다른 기존 DB, 전역 설치·Git 설정·네트워크/인가 설정·배포는 변경하지 않았다. PG 테스트는 localhost:55440의 Atheum 전용 DB, Akashic은 테스트별 임시 DB만 사용한다. 신규 계정/grant/인증 기능은 없다.

PG/CLI 제한은 프로세스 관찰별 한도이며 다중 PG 호출을 포함하는 API 전체의 단일 end-to-end 시간 보장은 아니다. 프로세스 timeout/출력 cap/Port.close는 child 완전 종료나 DB rollback을 증명하지 않는다. PG write의 응답이 유실되면 이미 커밋됐을 가능성이 있어 기존 기록과 근거를 다시 조회해야 한다. UI나 자동 외부효과 원복을 추가하지 않았다.

Schema 검증은 신뢰된 executable의 프로토콜 오류 방어이며 receipt의 암호학적 증명이 아니다. 전체 journal quota/동시 실행 quota와 OS child tree 종료, 전원 손실, receipt 삭제/DB 교체 탐지, production 권한은 범위 밖이다. 취소·만료 뒤 순수 receipt 조회가 없어 unknown이 남는 제한과 외부효과 exactly-once 비보장은 그대로 유지한다.

현재 코드를 멈추고 새 독립 최종 검증을 기다린다.
