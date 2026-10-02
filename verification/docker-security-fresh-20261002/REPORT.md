# 단일 Docker worker 독립 보안 검증 — 2026-10-02

## 결과와 검증 성격

승인된 **신뢰된 고정 이미지, 동일 host / 전용 PostgreSQL DB의 capacity 1, 일회성 worker, host manager, 실제 PostgreSQL journal / Akashic adapter** 경계에서 보고할 보안 취약점을 확인하지 못했다. 이는 전체 보안 보증이나 Standard scan 완료 선언이 아니다. 현재 소스에서 출발한 수동 source-backed 검증과 제한된 재현이며, 구현 대화와 이전 verification 보고서를 읽지 않았다.

Codex Security `security-scan` skill 및 scan-prologue/core-scan/config-preflight를 확인했다. 현재 tool surface에 Standard scan 시작·draft·완료용 Codex Security 도구가 없다. `config_preflight.py --profile security_scan --runtime-check delegation_available=false`의 결과는 `ready`이며 독립 baseline worker 미사용/worker capacity 불확실 경고를 포함한다(`preflight.raw`). 이번 검증에는 별도 subagent와 Standard report generator를 사용하지 않았다. 별도 검증 보고서만 작성했다. preflight는 fallback 확인 기록이며, Standard orchestration이 실행되었다는 증거가 아니다.

대상과 조상 경로에서 적용 가능한 AGENTS.md / SECURITY.md를 찾지 못했다. 대상 밖 sibling 프로젝트 지침은 적용하지 않았다. 소스·의존성·Git index / commit / remote / push는 변경하지 않았다. 신규 파일은 이 verification 디렉터리에만 추가했고, 테스트 DB·Akashic DB는 임시 전용 자원이었다. 기존 `_build` / deps를 갱신하지 않고 현재 `.ex` 파일을 `elixir -r`로 직접 로드했다. raw 로그의 undefined-module 경고는 순차 source load 시 발생했으며 이후 해당 모듈을 로드해 실행했다; production compile 검증 결과로 해석하면 안 된다.

## 식별값과 증거

- 실제 Docker image ID: `sha256:3896cfcb76bb1b3ded7ee9cf87689fe1c6a19462a73ddfe8ec9df2e70ed9011b`.
- manifest/source label SHA256: `6c45b1d061705ab775854bae792f8f6afef32952e554576b2b2e970f19e70eeb`.
- Dockerfile base digest: `sha256:3898ffe18d695e770239e4b342dc6b83136f52da0a37df2298083c03068cfd4e`.
- `hashes.json`: 현재 lib 전체, schema, worker 파일, build script, mix.lock 및 실제 Docker/Akashic/psql/Elixir launcher 파일 SHA256. Elixir launcher hash는 전체 Erlang runtime hash를 대신하지 않는다.
- `hash-recheck.raw`: 검증 종료 후 소스/바이너리 hash mismatch `[]`.
- `source.raw`: 검토한 핵심 소스의 line-numbered 원문. `image-inspect.raw`, `container-inspect.raw`: 실제 daemon 응답 원문.
- `docker-argv.raw`: Python wrapper가 기록한 실제 Docker 인자 배열. shell 문자열로 실행하지 않았다. 두 재현에서 실제 고정 worker create 총 8회.
- `run.raw`: 23개 PASS / EXIT 0. `run-extended.raw`: 추가 8개 PASS / EXIT 0.
- `history.raw`, `instances-first.raw`, `invocations.raw`, `instances.raw`, `events.raw`, `slots.raw`, `stale-pg.raw`: 이번 임시 DB의 실제 실행/관찰 원문.
- `fixture-argv.raw`, `unknown-create-argv.raw`: 실제 daemon에 전달하지 않은 조작 CLI 응답 시험 기록.

재현 명령(동일 project test PG 서비스와 image/binary가 있을 때):

```sh
python3 verification/docker-security-fresh-20261002/run.py
FRESH_EXTENDED=1 python3 verification/docker-security-fresh-20261002/run.py
```

실행마다 새 `atheum_security_fresh_<timestamp>` DB와 임시 Akashic 디렉터리를 만들고 제거한다. PG 연결 대상은 기존 프로젝트 테스트 서비스 `127.0.0.1:55440`; 기존 테스트 DB의 행을 변경하지 않았다. 두 run log에 실제 DB명과 임시 경로가 있다. 결과 파일은 재실행 시 일부 덮어쓰므로 증거 보존이 필요하면 이 디렉터리를 먼저 복사한다.

## 실제 설정과 코드 경계 대조

| 경계 | 소스 / 실제 증거 | 판정 |
| --- | --- | --- |
| image/spec | `worker/spec.ex:12`가 고정 spec / content ID 형식 / build source digest 확인, `worker/docker.ex:6`가 daemon image ID와 source/spec labels 확인 | 실제 이미지와 일치. 서명 검증은 없으며 승인된 trust anchor는 로컬 manifest와 고정 content ID이다. |
| argv / 옵션 주입 | `worker/docker.ex:22`, `process_io.ex:12`; instance name은 `worker/state.ex:37`의 random hex, image는 검증된 manifest | 실제 create는 고정 flags와 content ID. supplier ID의 `--privileged;$(touch ...);../../secret` 텍스트는 JSON data로 처리되어 shell 실행 / create 옵션이 되지 않았다. 저수준 Docker.create의 임의 map은 외부 사용자 API가 아니다. |
| user / capability / 권한 | actual inspect `User=65534:65534`, `Privileged=false`, `CapDrop=[ALL]`, `CapAdd=null`, `SecurityOpt=[no-new-privileges]` | 문서와 일치. 장치 목록 `[]`, DeviceRequests null. privileged 실행 없음. |
| filesystem / mount | readonly rootfs; `/tmp=rw,noexec,nosuid,size=16m`, Binds null, 실제 Mounts는 /tmp tmpfs만 | host root/home/credentials/socket mount 없음. build context allowlist `.dockerignore`도 확인. |
| network / resource | NetworkMode none, PortBindings `{}`, Memory/MemorySwap 134217728, NanoCpus 500000000, PidsLimit 64, restart no, init enabled | 실제 격리 설정과 문서 일치. IPC private; host namespace 요청 없음. |
| host secrets | Docker argv에 `-e`, env-file, mount 없음; 실제 Config.Env는 이미지 기본값 | host env에 넣은 sentinel은 container env에 없음. 실제 credential을 container에 넣거나 읽는 시험은 하지 않았다. host-side Docker/psql/Akashic 프로세스는 trusted host 환경을 상속한다. |
| 소유권 / 삭제 | `worker/docker.ex:60`의 image / owner / spec / instance generation / persisted ID 대조 후 `rm --force <inspected ID>` | foreign owner, wrong ID, wrong generation, wrong image fixture에서 모두 error; `rm` 호출 0회. 타 container를 실제 생성·변경·삭제하지 않았다. |
| capacity | `worker/state.ex:11`의 singleton local slot PK; Manager global owner | active run에서 두 번째 Manager 호출 capacity_busy. manager process 사망 후에도 slot 유지. capacity는 동일 전용 DB + host 계약이며 여러 DB/host를 포괄하지 않는다. |
| 조작 결과 | `manager.ex:59–66`의 exact ready/effect equality, `:89–95`의 exact result + attach exit + inspect exit 확인; Protocol / Wire | duplicate JSON key, 임의 operation, stale observation attempt fixture 거부. 단순 Docker exit 0만으로 성공하지 않는다. |
| stale 완료 | `atheum.ex:143`의 generation / attempt 조건 + stale event | 실제 worker 결과 직후 이번 DB의 generation을 fixture로 변경했을 때 `{:error,:stale_attempt}`, 최신 row result nil 유지, stale_attempt_observed 존재. |
| orphan / 중복 효과 | `manager.ex:139–153,175–190`; 동일 Apply receipt를 사용하는 recover | 효과 직후 manager 프로세스 kill → busy → reconcile unresolved/unknown generation 1 → recover generation 2; 실제 Akashic version 2 유지, 재전달 receipt 결과 동일. |

## 제한된 재현에서 확인한 상태 경계

1. 정상 실행은 `created → ready → executing → effect_observed → result_received → exited → removed` 관찰 후 durable succeeded/version 2를 반환하고 slot을 제거했다.
2. 효과 후 manager **BEAM 프로세스**를 kill하면 예약이 남았다. reconciliation이 기존 worker를 회수했지만 효과를 재시도하거나 succeeded로 만들지 않았다. 별도 명시적 recover가 원래 request/receipt를 그대로 사용했다.
3. 효과 후 worker를 kill하여 result를 잃으면 unresolved/unknown이었다. 안전 재전달은 같은 receipt 결과를 받아 중복 도메인 변경을 만들지 않았다.
4. ready 후 취소하면 효과 전송을 차단하고 unknown을 남겼으며 recover는 cancel_requested로 거부했다.
5. 오래된 attempt의 완료는 실제 PG 최신 generation에 쓰지 못했고, 늦은 관찰을 별도 event로 보존했다.
6. create 실패 / 부재 응답을 주장하는 fake CLI로 **실제 container를 만들지 않고** create-intent 경계를 시험했다. container_id nil이면 run/reconcile 모두 capacity를 유지했다. 이후 fixture의 owned removal 응답을 제공해 fixture 예약만 정리했다. 이는 daemon timeout 자체를 재현한 것은 아니다.

## 남은 한계와 미검증

- 같은 호스트의 **별도 manager VM 전체 종료 / OS crash**, PID reuse, daemon 재시작 및 실제 create 응답 timeout 이후 늦게 생성되는 container는 이번에 재현하지 않았다. 코드의 `owner_down?`는 같은 VM에서 global owner를 확보한 경우와 다른 VM의 `ps` 부재를 구분하며, 애매한 생존 상태는 거부한다.
- Session을 통한 end-to-end 악성 worker ready/effect/result 스트림 전체, output flood, malformed inspect 자료형으로 인한 예외를 모두 실행하지 않았다. exact map equality와 Wire parser를 검토하고 관련 순수 fixture를 시험했다. trusted daemon/CLI 자체의 악의적 거짓말은 이 검증의 신뢰 가정 밖이다. Label 확인은 daemon 관리자에 대한 방어가 아니다.
- container를 inspect하는 시점과 remove/start 시점 사이의 외부 Docker 관리자 조작 race는 재현하지 않았다. remove는 확인된 ID를 사용하지만 start attach는 generated name을 사용한다. 외부 host Docker 관리자에게 새로운 권한을 얻는 공격은 성립하지 않는 승인 범위다.
- host Akashic 경로는 `Path.expand` 기반 identity다(`atheum.ex` target). realpath / symlink inode 고정이나 receipt DB 교체 탐지가 없다. supplier 입력은 그 경로에 쓰이지 않고 운영자의 trusted config에서만 경로를 받는다. host 파일을 바꿀 수 있는 주체나 symlink retargeting을 허용하는 운영은 추가 검증이 필요하다. 그런 권한을 가정한 공격을 이 범위의 취약점으로 보고하지 않았다.
- owner / job generation 확인과 host Akashic apply는 서로 다른 PG/process 단계다. 완료의 stale write fencing은 확인했지만 취소/새 generation과 effect 시작 사이의 모든 race를 원자적으로 차단한다고 주장하지 않는다. 늦은 host 효과는 unknown과 보존된 동일 receipt 경계로 다뤄야 한다.
- 중복 방지는 동일 Akashic DB의 receipt 보존에 한정된다. DB 교체·receipt 삭제·restore 후 안전성, 임의 외부 효과의 exactly-once, PostgreSQL과 RocksDB의 원자적 커밋은 검증하지 않았다.
- kernel escape, seccomp의 실제 syscall 거부, 모든 image layer의 기밀정보 분석, base-image 공급망 검증, CPU/memory/PID limit 부하 강제 재현, 공개 서비스 auth는 수행하지 않았다. 공개 서비스와 사용자 임의 image/command는 요청대로 제외했다.
- 동작하는 배포는 이 로컬 Manager config와 실제 Docker container다. 저장소에서 production orchestrator/service 설정은 확인되지 않아 다른 배포 환경으로 확대 해석하지 않는다.

## 잔여 자원

`remaining.raw` 및 `remaining-extended.raw`: 이번 임시 디렉터리 exists False, 이번 DB 조회 결과 없음, project worker label의 잔여 container 목록 비어 있음. `slots.raw`도 `[]`. 기존 PG 테스트 service와 고정 worker image는 유지했다. network/권한/host 설정/다른 사용자 container는 변경하지 않았다. `hash-recheck.raw`의 source/binary hash mismatch 없음.
