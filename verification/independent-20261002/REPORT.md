# 독립 Function 실행 사이클 검증 — 2026-10-02

결론: 검사한 요구사항에서 재현 가능한 생산 코드 결함을 발견하지 않았다. 실제 PostgreSQL 및 임시 Akashic DB를 이용한 최종 실행은 **20/20 통과**했다. 목적형 mutation 6개는 모두 컴파일에 성공한 뒤 동작 테스트에서 탐지했다. 이는 시험한 경합·장애에 대한 결과이며 모든 interleaving 또는 임의 외부 효과 exactly-once의 증명은 아니다. 전체 보안 검증은 이 작업의 범위가 아니다.

## 독립 기준과 자원

구현 대화와 작성자의 성공 결론을 기준으로 쓰지 않았다. 상위 경로의 AGENTS.md는 발견되지 않았다. README에서 전용 자원만 확인하고 코드와 schema로 상태 계약을 분석했다. 원본 Git은 main의 unborn HEAD이며 index가 비어 있었다. 따라서 worktree 생성은 불가능해 원본 해시를 먼저 보존하고 별도 임시 복사본에서 실행했다. 기존 14개 테스트도 독립적으로 읽고 실행했으며 별도 테스트 6개를 추가했다. 생산 코드, Akashic/Axiom 코드, 기존 DB 서비스/상위/형제 파일은 변경하지 않았다. README 지정 테스트 PG에서 schema setup 및 테스트별 행/임시 trigger를 사용하고 자체 자원만 삭제했다. Git commit, 전역 설치, 원격, push, 배포, 형제 빌드는 수행하지 않았다.

- PG: `postgres://postgres@127.0.0.1:55440/atheum_cycle_test`
- binary: `/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic`
- SHA-256: `eeacb10fefdbf76bd086c7288aa9eab0a202aca57e5f1d27d1a754b93f446230`
- seed: `20261002`; command: `mix test --include integration --seed 20261002`
- 각 실행의 Akashic DB는 테스트가 새 임시 디렉터리에 만든 snapshot DB다. Axiom DB는 사용하지 않았다.
- Mix의 sandbox TCP 잠금은 처음 EPERM으로 실행되지 않았다. 허용된 escalation으로 재실행했으며 최종 exit=0이다. 첫 sandbox 거절 로그는 baseline.raw 갱신 과정에서 별도 raw로 보존되지 않았다. 이 누락은 증거 제한이다.

## 독립 상태 모델

접수는 key와 입력/target/deadline/safe_retry fingerprint가 같으면 같은 invocation/execution/request를 반환하고 충돌 입력은 거절해야 한다. invocation은 논리 접수, execution은 그 실행 생애, attempt는 실제 시도다. claim이 accepted를 running으로 이동하고 generation과 attempt를 바꾸며 durable call_intent를 남긴다. 외부 효과와 PG 완료 기록은 별도 커밋이다. 관찰 없는 running/unresolved는 unknown이며 재전달은 같은 request ID/payload와 보존 receipt 계약을 사용한다. 성공 관찰은 succeeded, 확실한 version/입력 거절만 failed/absent, timeout 및 transport/storage 불확실성은 unresolved/unknown이다. cancel_requested와 stop_confirmed는 다른 사실이다. accepted 취소는 시작 claim과 PG에서 원자적으로 경합하며 이미 시작된 실행의 취소는 효과 부재를 증명하지 않는다. 오래된 attempt의 결과는 현재 상태를 바꿀 수 없고 별도 evidence로 남아야 한다.

독립 recovery truth table은 상태 6개 × cancel/safe_retry/만료/target 변경/request_conflict 각 2개 = 192 조합을 검사한다. 허용 조건은 running/unresolved, 미취소, 미만료, 동일 target, 명시적 safe retry, request conflict 부재의 교집합이다. 실행 테스트는 결과 필드만이 아니라 실제 그래프의 `P -> B` 차단 변화, receipt replay, version, fresh VM 읽기/복구, PG journal을 함께 검사한다.

## 실행된 요구·장애

| 요구 | 실제 검증 |
|---|---|
| 접수 멱등성과 ID 구분 | 4-way 동시 동일 접수, 충돌 입력, 단일 accepted 사건; invocation/execution 구분, 복구 중 execution 유지·attempt 변경 |
| 실제 객체 효과/정답 | S 활성→비활성 이후 P의 B 차단, 성공 receipt 및 replay, 별도 실제 no-op |
| 안정된 request | 효과 후 worker kill, PG journal trigger 실패, 응답 truncation 뒤 같은 request·동일 receipt/version 회수 |
| 재시작 | fresh BEAM VM의 persisted read 및 실제 recover 실행 |
| 취소 | 실행 전 취소와 no attempt, 효과 후 취소와 성공 공존, 독립 cancel/start 경합 12회 |
| unknown 보존 | 실제 효과 성공 뒤 응답 유실/timeout, transport 실패, PG 완료 기록 실패 |
| 취소·만료 후 replay 차단 | unknown 상태에서 취소/만료 후 spy executable 미실행, stop_confirmed=false 유지 |
| stale worker | 기존 성공 관찰 경합 + 독립 오래된 transport 실패 관찰이 새 성공을 덮어쓰지 못함; stale 사건에 이전 attempt 보존 |

## 목적형 mutation 민감도

모든 mutation은 각자 새 임시 복사본의 lib에만 적용했다. 원본 lib는 해시 불변이다. schema 자체를 mutation하지 않았으며 공유 PG schema를 오염시키지 않았다. 최신 원시 로그/정확한 대체문자열/명령/복사본 경로는 mutations.json과 각 *.raw에 있다. 테스트가 점진적으로 추가되어 mutation별 18~20개 테스트가 실행됐다.

| mutation | 관측 |
|---|---|
| generation/attempt finish fence 제거 | 18/20, 독립 오래된 실패 및 기존 stale 성공 테스트 실패 |
| safe_retry opt-in 조건 제거 | 16/19, 독립 truth table 및 기존 gate 테스트 실패 |
| timeout/transport를 failed/absent로 변경 | 13/18, 독립 loss/block 및 기존 unknown 테스트 실패 |
| 취소를 항상 stop_confirmed=true로 변경 | 16/18, 독립 unknown 취소 및 기존 효과 후 취소 실패 |
| 매 접수마다 acceptance key 변경 | 18/19, 동시 동일 접수 테스트 실패 |
| claim마다 Akashic request ID 재발급 | 14/19, 독립 응답 유실 복구 및 기존 death/journal/timeout/replay 테스트 실패 |

최초 opt-in mutation은 `false` cond 때문에 warnings-as-errors로 컴파일이 거절됐다. 탐지력으로 세지 않고 해당 조건을 삭제한 mutation으로 재실행해 동작 실패를 확인했다. 최신 retry raw는 재실행 결과다.

## Git hook 및 ignore

`core.hooksPath=.githooks`, 원본 index 비어 있음. 원본 hook을 새 임시 Git fixture에서 실행해 정상 check 성공, 실패 check의 nonzero 전달, staged 파일의 unstaged 수정 거절을 확인했다. fixture는 commit하지 않았다. 실제 check-ignore는 .env/.env.local, pem/key/secret, data/db/artifacts/_build를 제외했고 verification raw는 제외하지 않았다. 현재 verification은 credential 없는 지정 URL/합성 fixture/테스트 출력만 담는다. ignore는 명시적 force-add나 이미 tracked인 비밀을 막는 장치가 아니다.

hook은 staged 경로(ACMR)의 working tree 차이를 막고 working tree에서 check를 실행한다. 전체 index의 완전한 재구성 검사는 아니다. staged deletion(필터 D 제외), untracked/unstaged 비대상 의존성까지 검증하는지, 현재 비어 있는 실제 index의 commit payload는 검증하지 않았다. 일반 staged 수정 거절 테스트가 이 범위까지 보장한다고 해석하면 안 된다.

## 증거와 미검증

original-hashes.json은 검사 전 원본 manifest, unchanged.json은 종료 시 원본 파일과 binary 불변 확인이다. baseline/final-baseline json/raw는 명령·seed·결과, independent_test.exs는 추가 독립 테스트, mutate.py는 격리 mutation 재현기다. 반복 실행은 원본 파일을 복사한 workspace.txt 경로에 independent_test.exs를 test로 넣고 위 환경변수/명령을 사용한다. mutate.py는 이를 각자 새 복사본으로 복사한다.

미검증: PG 서버 재시작/호스트 전원 차단, 실제 OS kill 뒤 모든 child 종료 여부, RocksDB receipt 삭제/복원 및 동일 경로 DB 교체, 모든 scheduler interleaving, records storage, 병렬 별도 작업이 binary를 도중 교체했다가 복원한 경우. 시작·종료 binary hash는 같았고 형제 빌드 결과에 의존하지 않았다. cancel의 마지막 확인과 CLI spawn 사이의 요청은 이미 시작 claim을 얻은 실행의 취소이며 정지 확인을 보장하지 않는다. 서로 다른 DB의 원자성, receipt 계약 밖 exactly-once, 임의 외부 효과 복구 가능성은 주장하지 않는다. 보안 검증은 후속 별도 작업이다.
