# 독립 Docker worker 기능·복구·민감도 검증 — 2026-10-02

관찰된 범위에서 재현 결함은 발견하지 않았다. 실제 Docker/전용 PostgreSQL/임시 Akashic으로 최종 12개 테스트가 통과했고, 3개 목적형 mutation은 모두 의도한 assertion에서 실패했다. 이는 전체 안전 보증이나 보안 검토가 아니다.

## 독립 기준

README, 구현 코드, schema와 test fixture를 읽되 기존 verification 보고서나 구현의 성공 결론은 판정 근거로 사용하지 않았다. 적용 가능한 ancestor AGENTS.md는 발견되지 않았다. 독립 테스트의 setup만 기존 fixture 구조를 사용하며 기대 상태는 아래 모델로 정의했다.

| 사건 | 독립 기대 상태/불변식 |
|---|---|
| reserve 경합 | 같은 DB/host에서 성공 1개, 나머지 capacity_busy |
| ready 미확인 또는 worker 소실 | 성공으로 판정하지 않음; unresolved/unknown |
| 외부 효과 완료 뒤 응답 유실 | result=null, unknown; container 회수가 효과 부재를 뜻하지 않음 |
| manager 소실 | 예약 유지, 새 생성 차단; reconcile은 회수만 수행 |
| create intent만 있고 ID/존재 미확인 | 예약 유지; 늦게 생성된 동일 소유 container를 확인하면 회수 가능 |
| 명시적 safe recovery | 동일 invocation/execution/request ID/payload/target; 새 attempt/job generation/instance/container ID |
| receipt 재전달 | 최초 결과 version=2 그대로, 중복 version 상승 없음 |
| 취소와 효과 경합 | 효과 성공이면 succeeded+cancel_requested; 응답 유실이면 unknown+취소, reapply 금지 |
| 오래된 worker 결과 | 새 attempt/generation의 durable state 불변; stale 관찰 사건만 추가 |

## 실행과 증거

seed=20261002. 생산 checkout은 전부 untracked였으므로 Git worktree/index 변경 없이 `/tmp/atheum-docker-independent-20261002`에 소스 복사 후 기존 elixirc로 별도 BEAM을 생성했다. 테스트가 사용하는 외부 manager VM도 이 복사본의 ebin을 읽었다. npm/Hex/전역 설치, 이미지 재빌드, commit/remote/push는 수행하지 않았다.

기존 프로젝트 테스트 PG container `atheum-cycle-test-pg-20261002` 안에 새 DB `atheum_docker_independent_20261002`만 생성했다. 연결 주소는 `postgres://postgres@127.0.0.1:55440/atheum_docker_independent_20261002`. 기존 DB에는 쓰지 않았다. Akashic은 기존 binary를 읽고 각 test의 새 임시 RocksDB만 사용했다. Docker daemon 사용을 위해 승인된 sandbox escalation으로 실행했다. worker는 구현의 제한된 create 인자를 그대로 사용하며 mount/public port/network 설정을 추가하지 않았다.

- [final-real.raw](final-real.raw): 기존 실제 통합 테스트 6개 + 새 독립 테스트 6개, **12 passed**, exit=0, 29.719초. readiness timeout, worker kill, manager BEAM 프로세스 kill, 별도 manager VM kill, cancel 전/후 경합, 효과 응답 소실/receipt 복구를 포함한다.
- 새 독립 테스트: actual attach stdin 소실/receipt 복구, 늦은 worker 결과 fence, 16개 동시 reserve(1 성공/15 busy), 생성 전 예약 회수, ID 없는 unknown create의 부재 및 늦은 생성, 실제 create 성공 후 ID 응답 지연 중 manager VM SIGKILL, 취소된 unknown의 복구 차단.
- [epipe.raw](epipe.raw): 단독 재실행 **1 passed**, 실제 worker kill 뒤 `worker_lost / worker stdin unavailable`, unresolved/unknown/result=null/stop_confirmed=false를 기록. manager는 crash 없이 복구했다. syscall 수준 errno=EPIPE는 추적하지 않았으며, closed attach stdin 관찰 및 기존 unlink 경로를 실행한 증거다.
- [real-docker.raw](real-docker.raw): 추가 actual-create-gap 이전 실행 **11 passed**, 40.6초. 최종 실행과 구분해서 보존.
- [executions.json](executions.json), [epipe-execution.json](epipe-execution.json), [run.json](run.json): 명령, cwd, exit, wall time, seed 및 시작 시각.

실제 create-gap 시험은 test 전용 Docker executable wrapper가 `docker create`를 실제 수행하고 container ID를 marker에 보존한 다음 stdout 전달을 45초 지연한다. durable instance가 create_intent/container_id=null인 것을 확인하고 manager VM만 SIGKILL했다. 다른 manager 생성은 capacity_busy였으며, 정상 Docker로 reconcile하여 labels/image/generation을 검증하고 container를 회수했다. job generation은 1에 머물고 unresolved/unknown이었다. synthetic create-intent 시험과 구별된다.

실제 resource 단일 sample은 56.43MiB/128MiB, CPU 0.16%, PIDs 11, network I/O 0B였다(final-real.raw). 단독 재실행의 sample도 epipe.raw에 있다. inspect 기반 제한 확인은 CPU 0.5, memory/swap 128MiB, pids 64, restart=no, network=none, read-only, UID/GID 65534, caps ALL drop/no-new-privileges, /tmp tmpfs만, port 없음이다. sample은 peak나 장기 부하 한도가 아니다.

## 목적형 mutation

모두 `/tmp/atheum-mutation-*` 복사본에만 적용하고 재컴파일했다. 고정 이미지에 들어가는 소스는 변이하지 않아 이미지 identity 검증을 우회하지 않았다. test 실패 exit=2이며 compile 실패가 아닌 의미 assertion 실패다.

| 변이 | 기대 탐지 및 실제 결과 | 시간 |
|---|---|---|
| `Atheum.finish` generation/attempt fence → true | 오래된 succeeded 응답이 돌아와 stale_attempt 기대 실패 | 16.966초 |
| completion → stopped/confirmed_absent | lost-effect 상태의 unresolved 기대 실패 | 3.411초 |
| ID 없는 create에서도 absence로 회수 허용 | reconcile 거절 기대가 실제 성공으로 바뀌어 실패 | 0.932초 |

[stale_fence.raw](stale_fence.raw), [false_absence.raw](false_absence.raw), [release_unknown_create.raw](release_unknown_create.raw)에 assertion 원문이 있다. 각 `.patch.json`은 변이 전/후 SHA256과 정확한 문자열 치환을 기록한다. 민감도 3/3이며 모든 가능한 결함을 검출한다는 뜻은 아니다.

## hash와 정리

[environment.json](environment.json)에 고정 이미지 전체 inspect, Docker/Elixir/psql 버전과 Docker/psql binary SHA256이 있다. 사용 image ID는 `sha256:3896cfcb76bb1b3ded7ee9cf87689fe1c6a19462a73ddfe8ec9df2e70ed9011b`, image source digest는 `6c45b1d061705ab775854bae792f8f6afef32952e554576b2b2e970f19e70eeb`다. [source-before.json](source-before.json)에 source/test/schema/build script/image manifest 및 기존 Akashic binary SHA256을 남겼다. [preservation.json](preservation.json): 30개 hash 비교, 변경 0개.

[cleanup.json](cleanup.json): 전용 DB에서 slots/instances/invocations/events 모두 `0|0|0|0`, project worker container 0개, 검증 manager/wrapper process 0개 확인. 해당 DB DROP 성공, 네 개 격리 복사본 삭제/부재 확인. test별 Akashic 임시 디렉터리는 on_exit에서 제거됐다. 기존 PG container/image는 보존했다. 최종 Git index를 쓰는 명령은 수행하지 않았으며, index 전후 hash 비교는 별도로 수행하지 않았다.

## 재현

기존 host 환경, 기록된 image/binary와 프로젝트 소스 hash가 일치해야 한다. 해당 이름의 임시 DB/복사본이 이미 존재하면 삭제 대신 먼저 소유권과 상태를 확인한다.

```sh
docker exec atheum-cycle-test-pg-20261002 psql -U postgres -d postgres -c 'CREATE DATABASE atheum_docker_independent_20261002'
python3 verification/docker-independent-20261002/run.py
```

run.py는 source를 격리 복사하고 컴파일해 baseline 및 세 mutation을 실행한다. 완료 뒤 먼저 전용 DB의 네 table count와 project worker 부재를 확인하고, 이번 DB만 DROP 및 `/tmp/atheum-docker-independent-20261002`, `/tmp/atheum-mutation-{stale_fence,false_absence,release_unknown_create}-20261002`만 정리한다. raw 로그를 덮어쓰므로 재현 전 증거 디렉터리를 별도 보존한다.

## 한계

하나의 host/PG DB, ARM64 Linux Docker image와 해당 Akashic receipt 보존 범위다. daemon 전체 재시작, host power loss, PG 장애, image 손상, PID 재사용, 장시간 부하, 다중 Atheum DB의 host capacity, syscall-level EPIPE, 악성 image/protocol 공격은 검증하지 않았다. 순수 receipt 조회가 없어서 취소/만료 뒤 unknown을 남기는 설계 한계는 유지된다. 취소 경합은 결정적 hook 지점으로 시험했으며 모든 임의 interleaving을 탐색한 것은 아니다. 늦은 결과는 전용 DB에서 제어된 새로운 attempt를 삽입하여 fence를 시험했다. 자동 worker restart는 restart=no로 금지되며 job retry는 명시적 recover 호출에서만 관찰했다. 보안 축은 후속 독립 작업 대상으로 남긴다.
