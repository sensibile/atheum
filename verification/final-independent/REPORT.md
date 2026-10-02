# 최종 독립 검증 — 2026-10-02

판정: **요구 전체 통과 아님. 재현 결함 1건.** 기존 review는 통과했지만 새 독립 회귀 검사는 실제 효과를 확정 부재로 오인하는 응답 분류를 재현했다. 생산 코드 수정 없이 검증 파일과 이 보고서만 추가했다. 구현 대화·작성자의 성공 결론·기존 검증 보고서를 판정 근거로 사용하지 않았다.

## 재현 결함 F1: 모순된 CLI envelope가 confirmed_absent로 확정됨

위치: `lib/atheum/wire.ex`의 `response/3` 오류 clause와 `lib/atheum/core.ex`의 `completion/1` 확정 거부 clause.

새 임시 Akashic DB에서 Supplier S를 active=true, version=1로 생성한다. 정상 실제 apply를 실행한 wrapper가 실제 성공 JSON의 result를 유지하면서 `ok=false`, `error={code:invalid_input, detail:...}`를 덧붙이고 exit=2로 반환한다. 성공 result에는 changed=true/version=2가 있다. 이는 성공과 오류가 동시에 존재하는 모순된 응답이다.

현재 Wire는 error.code/detail과 nonzero exit만 보고 오류를 수용한다. Core는 invalid_input을 효과 부재로 확정한다. 실제 persisted version=2인데 PG는 `status=failed`, `effect_certainty=confirmed_absent`, `result=null`을 저장한다. 이어 recover는 `{:error, :not_recoverable}`로 거부된다. 따라서 효과 관찰 불확실성과 복구 가능성도 잃는다. 올바른 기대는 잘못된 envelope를 transport_failure로 거절하고 unresolved/unknown으로 남기는 것이다.

증거: [정확한 CLI JSON·PG 결과·실제 version·recover 원시 결과](defect-wire.raw), [재현 검사](final_test.exs), exit=2. 첫 독립 실행 및 재확인 실행에서도 같은 실패를 재현했다. 이는 실제 Akashic가 정상적으로 이런 응답을 내보낸다는 주장이 아니라, 요청된 잘못된 응답 경계의 목적형 fault injection이다. 생산 소스는 고치지 않았다.

## 독립 경계표

| 경계/장애 | 실험·관찰 | 판정·증거 |
|---|---|---|
| 접수 멱등성 | 8개 concurrent submit, 동일 key/input/options/target | invocation/execution/apply/request ID 하나, accepted event 하나. safe_retry 변경은 acceptance_conflict. final-independent.raw |
| 안정된 효과 request | worker 종료 및 live-worker recovery | request.apply 동일, execution 유지, 새 attempt, version 추가 상승 없음. final-independent.raw |
| 성공 후 worker 강제 종료 | after_effect handshake 후 monitor worker kill | running/unknown 잔존, 동일 receipt 재전달로 복구. final-independent.raw |
| 효과 후 PG 기록 실패 | fixture invocation에만 event INSERT trigger exception | 원자적 완료 기록 rollback, running/unknown, 이후 trigger 제거와 receipt 복구. no-op과 changed 효과 구분. final-independent.raw |
| 응답 유실/관찰 timeout | 실제 apply 성공 뒤 wrapper가 stdin EOF 대기 | unresolved/unknown, stop_confirmed=false, 실제 version=2. 취소 후 recovery 거부, unknown 유지. final-independent.raw |
| 취소 전 시작 차단 | cancel 완료 뒤 run | stopped/not_started, 실제 version=1, 시작 거부. final-independent.raw |
| 취소와 시작 경합 | barrier 해제 후 concurrent run/cancel 12회 | 모두 cancel이 claim보다 먼저 완료된 일정: transition_conflict 또는 not_accepted, stopped/not_started, version 유지. cancel-races.raw |
| 취소 후 완료 효과 | 실제 review의 after_effect 취소 | succeeded와 cancel_requested 유지, stop_confirmed=false. review-permitted.raw |
| 만료 후 recovery | fixture 자신의 deadline을 0으로 설정 | deadline_expired, unknown 유지, 실제 version=1. final-independent.raw |
| stale 결과 | 성공한 worker를 정지점에서 보류, recover 완료 뒤 이전 worker 해제 | stale_attempt, 최신 row 불변, stale_attempt_observed 증거 유지. final-independent.raw |
| URL 변조 | dbname, 중복 dbname, encoded key/path/user, host/service/query/fragment/password, path traversal, conninfo, port 누락 14개 | 모든 요청 invalid_configuration, marker adapter 호출 없음. 실제 타 DB 접속 없음. final-independent.raw |
| PG 대상 | 명시적 localhost 55440의 atheum_cycle_test만 접속 | current_database 및 server 17.10 확인. pg-identity.raw |
| PG 시간/출력 | pg_sleep(1), pg_timeout_ms=50, 실제 1.1MB SELECT, 출력 adapter | 시간 <1초, journal_failure 또는 journal_timeout; 실제 및 fake PG output_limit. final-independent.raw |
| CLI 출력/JSON/시간 | 2MB stdout, 잘못된 성공 타입·버전·difference/work, 실제 효과 후 timeout | output_limit, 잘못된 성공 unknown. 깊이·timeout 범위는 실제 review boundary tests에도 포함. final-independent.raw/review-permitted.raw |
| 모순된 성공/오류 | 실제 성공 result + ok=false/error invalid_input/nonzero exit | **FAIL F1**, confirmed_absent 오판. defect-wire.raw |

## 검사와 hook 실행

[실행 명령·exit 목록](commands.json), [review의 모든 단계·exit](review-steps.json), [review raw](review-permitted.raw).

- 실제 `mix format --check-formatted`, 강제 compile/warnings-as-errors, `mix credo --strict`, `mix dialyzer`, 빠른 tests, integration tests 모두 실행했다. review exit=0; 빠른 10 passed/13 excluded, 통합 23 passed.
- Credo는 10 files/69 checks, issues 없음. Dialyzer는 0 errors/0 skipped/0 unnecessary skips이고 ignore_warnings 없음. source 검색에서 blanket suppression/check disable을 찾지 않았다. 기존 PLT를 사용했으며 완전 새 PLT rebuild를 실시하지 않았다.
- 새 독립 실행은 11/12 passed, 실패 하나는 F1이다. 3개의 sensitivity baseline도 이 실행에 포함되어 통과했다. 이후 추가한 race test 단독 실행은 1 passed, 내부 경합 12회. F1 단독 재확인은 0/1 passed. 최종 소스 그대로 재현 가능한 파일을 남겼다.
- [격리 hook/mutation runner](isolated.py)는 기존 source/deps/cache를 사용한 임시 복사본에서 실행했다. 정상 full staged는 실제 scripts/check precommit 전체를 통과했다. broken staged/clean working은 format 단계에서 거부, broken staged/fixed working은 unstaged guard로 거부했다. 모든 hook 실행의 fixture index SHA-256 전후가 일치한다. [결과](isolated-results.json), hook-*.raw.
- 실제 source repo의 index는 시작/종료 모두 absent. Git HEAD도 아직 없다. 실제 index에 git add/stash/reset/commit을 수행하지 않았다. fixture Git에는 commit이나 remote가 없다. fixture hook 경로는 `git -c`로 해당 호출에만 지정했다.
- 저장소의 `python3 scripts/check-hook`도 통과했다. bundled-hook.raw.

## mutation 민감도

임시 소스 복사본에서만 세 mutation을 적용했다. 각 실행은 compile 후 3개 검사 중 정확히 1개 assertion 실패로 exit=2를 냈다. 컴파일 실패를 mutation 검출로 세지 않았다.

| mutation | 대응 실패 | 증거 |
|---|---|---|
| unknown 결과를 failed/confirmed_absent로 치환 | timeout unknown 보존 | mutation-unknown.raw / unknown.patch.json |
| apply success validation 우회 | 빈 apply 성공 거절 | mutation-success.raw / success.patch.json |
| URI query nil 조건 제거 | dbname override 실행 전 거부 | mutation-url.raw / url.patch.json |

첫 runner 시도는 ExUnit의 `match (=) failed` 문구를 `Assertion`으로만 찾는 검사 도구 assertion 때문에 중단됐다. raw는 보존했고 runner 문구 조건을 수정해 세 mutation을 완료했다. 또 F1 wire 캡처를 추가하는 첫 Python 준비 명령에서 SyntaxError가 발생하여 파일을 바꾸지 못했다. 수정 후 defect-wire.raw에서 실제 JSON 캡처를 완료했다. 최초 sandbox 실행의 Mix TCP filesystem lock은 EPERM으로 막혔고 review.raw/independent.raw에 남겼다. 허용된 실행으로 다시 실행한 결과만 제품 판정에 사용했다.

## 보존·환경·미검증

[source/binary 시작 hash](source-before.json), [시작/종료 일치와 실제 index 상태](preservation.json), [바이너리 경로·버전·hash](environment.raw). Elixir/Mix 1.20.4, OTP 29, psql client 18.6, 실제 PG server 17.10. Akashic는 README 지정 기존 binary의 hash를 기록했다. Akashic 생산 소스나 기존 DB를 읽거나 변경하지 않았고 새 임시 DB만 만들었다. 자신의 PG fixture row와 trigger만 제거했다. 기존 증거 파일을 수정하는 명령을 실행하지 않았다. 원본 production/lib/test/scripts/schema/README/mix 및 Akashic binary 해시 변경은 0개다.

적용 가능한 ancestor 및 repo 내부 AGENTS.md를 탐색했고 발견하지 못했다. README와 실제 소스를 읽었다. 저장소가 HEAD 없는 상태이므로 committed-base worktree를 만들 수 없고, 사용자 지정 검증 경로와 허용된 격리 복사본에서만 작업했다. 전역 설치, 다른 프로젝트 빌드·소스 변경, 기존 DB 사용, Git commit/remote/push, 배포, 지속적 권한 설정 변경을 하지 않았다. 임시 wrapper 실행 파일 권한만 fixture 생성 과정에서 설정했다.

검증하지 않은 범위: 모든 스케줄링 interleaving, OS/VM 강제 중단과 실제 네트워크 단절, PG crash/디스크 full, records storage의 새 독립 probe, receipt 삭제·동일 경로 DB 교체, 악성 psql 또는 Akashic binary의 신뢰성, 새 PLT 전체 재작성, 타 OS/버전. 경합 12회는 모두 cancel-before-claim 일정이므로 run이 먼저 진행되는 모든 미세 경합까지 주장하지 않는다. CLI timeout 및 Port.close는 효과 부재나 child 종료의 증거로 해석하지 않았다. URI 제한은 현재 README의 localhost/explicit-port/atheum_ 이름 정책이며 정확한 단일 DB 이름의 인가 allowlist는 아니다. 실제 접속은 지정 DB 하나로만 제한했다.

이 결과는 일반적인 취약점 부재나 임의 외부 효과 exactly-once를 보증하지 않는다. 최종 승인 장애는 F1이며, 이번 요청의 소스 보존 조건에 따라 수정하지 않았다.
