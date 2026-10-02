# 단일 Docker worker 구현 및 실제 검증

2026-10-02. 승인된 bounded 구현을 현재 checkout에서 이어갔다. 첫 커밋이 없는 unborn main(HEAD 없음)이므로 worktree를 만들 기준 commit이 없으며 사용자 지시에 따라 기존 untracked 구현과 evidence를 보존했다. commit/staging/remote/push와 형제 소스 수정은 없다.

## 구현 결과

기존 부분 구현인 `lib/atheum/worker/{spec,state,manager,docker,session,protocol}.ex`, `worker/{Dockerfile,main.exs}`, `scripts/build-worker`, worker schema와 Atheum Docker runner 연결을 유지하고 실제 빌드·실행했다. 고정 프로젝트 image ID는 `sha256:3896cfcb76bb1b3ded7ee9cf87689fe1c6a19462a73ddfe8ec9df2e70ed9011b`, base digest와 source digest는 `worker/image.json`에 있다. Docker worker는 입력 검증/effect 요청/result envelope를 처리하며 host가 기존 Akashic adapter로 실제 effect와 PostgreSQL journal을 수행한다.

단일 lifecycle owner, durable capacity=1, WorkerSpec/instance/container ID/instance generation/job attempt 식별, readiness, durable observation/result, exit 확인과 강제 제거/부재 확인을 실제 실행했다. reconcile은 job 재시도를 수행하지 않는다. 명시적 recover만 기존 request/receipt를 유지하고 별도 attempt/instance를 만든다. Docker restart=no. 최소 권한과 통신 제한은 README의 로컬 단일 Docker 워커 절에 명시했다.

이번 실행에서 변경·생성한 파일:

- `lib/atheum.ex`: Manager alias(Credo 수정).
- `lib/atheum/worker/session.ex`: close의 implicit rescue(Credo 수정), attach Port unlink로 worker kill/stdin `epipe`가 manager까지 종료시키던 경합 수정.
- `test/cycle_integration_test.exs`: current_database 검증을 지정된 임시 DB 이름으로 비교.
- `test/worker_integration_test.exs`: 실제 Docker 테스트 6개.
- `test/worker_protocol_test.exs`: 순수 protocol/attempt/envelope 경계 검증.
- `worker/image.json`: 실제 고정 image ID/source/base manifest.
- `README.md`: 실행·제한·소유권·복구·불확실성 계약.
- 이 폴더의 report/raw/exit 파일. 기존 verification 기록은 보존.

## 재현

기존 host 도구와 기존 Akashic binary만 이용한다. Docker daemon 접근 및 Mix의 local TCP lock이 sandbox 기본 권한에서 차단되어 승인된 실행 권한으로 수행했다. 자동 승인 거절은 없었다. 기존 DB에는 쓰지 않고 test PG 서비스에 새 `atheum_worker_verify_20261002` DB를 생성했다. 테스트는 각자 새로운 임시 Akashic DB를 만들고 자신이 만든 row/container/DB directory만 정리한다.

```sh
psql -h 127.0.0.1 -p 55440 -U postgres -d postgres \
  -c 'CREATE DATABASE atheum_worker_verify_20261002'
./scripts/build-worker
./scripts/check precommit
ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_worker_verify_20261002 \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
./scripts/check review
python3 scripts/check-hook
```

새 테스트 DB는 재현/독립 검증용으로 남겼으며 DB 전체 삭제는 하지 않았다. 이미 존재하면 CREATE DATABASE를 재실행하지 말고 별도 새 `atheum_` 이름을 사용한다. worker/image.json은 로컬 빌드 manifest이므로 다른 host에서는 build-worker로 해당 host의 고정 이미지를 다시 만들어야 한다.

## 증거

최종 precommit exit 0(15 tests), review exit 0(35 tests, Docker 6 tests 포함), Credo strict 지적 없음, Dialyzer errors/skipped 0, hook exit 0. 실패 seed 회귀도 exit 0이다. 최종 review report는 `artifacts/20261002T022946737549Z-review/report.json`, 최종 standalone precommit report는 `artifacts/20261002T022922153826Z-precommit/report.json`이다.

- `precommit.raw` / `precommit.exit`: format, warning-as-error compile, Credo strict, Dialyzer, FC 및 boundary tests.
- `review.raw` / `review.exit`: 최종 전체 검사와 실제 PG/CLI/RocksDB/Docker I/O. `WORKER_DURABLE`은 저장된 lifecycle row와 result envelope, `WORKER_CONSTRAINTS`는 실제 Docker inspect 제한 값이다.
- `hook.raw` / `hook.exit`: 기존 staged export 검사; 임시 fixture index 불변, commit 없음.
- `image-inspect.raw`: 실제 고정 이미지 메타데이터.
- `remaining-workers.raw`: 프로젝트 worker label의 남은 컨테이너 목록.
- `remaining-rows.raw`: 최종 전용 임시 DB의 slots/instances/invocations/events 수(모두 0). 남은 worker 컨테이너도 0이다.
- `docker-tests.raw`: 초기 Docker 5개 테스트 통과 기록(최종은 6개).
- `precommit-initial.raw`: 기본 sandbox에서 Mix TCP lock이 차단된 초기 시도. 최종 검사 결과와 구분한다.
- `review-epipe.raw` / `review-epipe.exit`: 반복 검증에서 발견한 실제 attach stdin `epipe` 결함(34/35, exit 2).
- `epipe-regression.raw` / `epipe-regression.exit`: 수정 후 동일 실패 seed 266229의 실제 Docker 6개 테스트 통과(exit 0).
- `failed-attempt-residue.raw` / `residue-cleanup.raw`: epipe 실패 iteration에서 orphan 회수 후 남은 자신의 invocation 한 건을 먼저 보존하고 해당 ID만 정리한 기록. 최종 성공 iteration의 모든 row는 테스트 teardown에서 정리됐다.

실제 검증 항목: durable 정상 성공/전체 lifecycle, readiness deadline 실패, effect 전 worker kill, effect 후 worker kill/응답 유실, manager process kill 뒤 capacity 예약 유지와 중복 방지, 별도 manager BEAM VM의 OS 강제 종료 뒤 새 owner 회수, 생존 VM 회수 거절, 취소 전송 경합, 효과 후 취소와 성공 보존, receipt 재전달 시 version 2 유지. 기존 실제 timeout/저장 실패/모순 envelope/stale attempt 테스트도 review에 포함된다.

## 남는 제한과 미검증

독립 검증은 이번 작업 범위 밖이며 다음 새 작업에서 수행한다. daemon 응답이 유실된 create가 늦게 완료되는 상황, Docker daemon 자체 재시작, host reboot/PID 재사용, 디스크 고갈은 실제 fault injection하지 않았다. create 결과를 확정할 수 없으면 capacity를 보수적으로 유지한다. 동일 host/동일 전용 PG DB가 capacity 경계이며 multi-host/다중 DB를 아우르는 스케줄러는 없다. 순수 Akashic receipt 조회가 없어 취소/만료 뒤 apply 재전달은 금지되고 unknown이 남을 수 있다. receipt 보존과 DB 생애 계약에 한정한 재시도이며 임의 외부효과 exactly-once 보장은 없다.
