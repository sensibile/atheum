# Atheum 첫 Function 실행 사이클

로컬 서비스 경계 `Atheum.submit/run/get/history/cancel/recover`로 `supplier.set_active.v1` 하나를 실행한다. PostgreSQL에 접수·실행·시도·이력·결과를 저장하고 기존 Akashic CLI로 실제 Supplier를 변경한다. 서버나 UI는 없다. Axiom/Arbiter/Archon/Workflow/Agent는 구현하지 않았다.

제품 실행 경로의 완료 판정은 [Function 실행 완료 계약](FUNCTION_CYCLE.md)을 따른다.
`./scripts/verify-function-cycle`은 필수 조건별 증거를 남기고 누락·실패를 완료로 표시하지 않는다.

## 초기 선택과 책임

Elixir는 순수 입력/복구 판단과 프로세스 I/O를 나누고 작업 경계를 표현하기에 적합해 선택했다. PostgreSQL은 접수 unique 제약과 상태·journal의 원자적 변경을 위해 선택했다. 둘은 이번 사이클의 가역적인 구현 선택이며 사용자 확정 아키텍처가 아니다. 런타임 외부 패키지는 추가하지 않았다. dev/test 전용으로 공식 Hex의 Credo 1.7.19와 Dialyxir 1.4.8을 mix.lock에 고정했다. deps와 Hex/PLT 캐시는 프로젝트 내부에 두며 전역 설치는 없다. 설정 참고: [Credo 공식 문서](https://hexdocs.pm/credo/overview.html), [Dialyxir 공식 문서](https://hexdocs.pm/dialyxir/readme.html). 현재 PostgreSQL shell은 기존 psql을 프로세스로 호출하므로 연결 비용이 있고 장기 driver 선택은 미정이다. Elixir 1.20.4/OTP 29, PostgreSQL 17.10으로 검증했다.

FC: `Atheum.Core`의 입력·복구·관찰 결과 판단. IS: PostgreSQL 트랜잭션과 Akashic Port/시각/ID 생성. 저장 schema는 `priv/schema.sql`이다. 접수와 journal 기록, 상태 변경과 해당 사건 기록은 각각 한 PostgreSQL statement의 원자적 CTE다. generation/attempt 조건으로 오래된 worker 상태 쓰기를 차단하며 늦은 관찰은 별도 사건으로 보존한다.

Akashic의 생산 코드나 DB를 변경하지 않는다. `result.apply`를 도메인 결과로 정규화하고 I/O 측정치와 구분한다. 같은 논리호출은 invocation/execution/request_id/payload를 유지하며 새 수행 시도에만 attempt가 바뀐다. request_id 멱등성은 **동일 Akashic DB와 보존된 receipt**에 한정하며 임의 외부효과 exactly-once를 보장하지 않는다. PostgreSQL과 RocksDB의 커밋을 하나로 묶지 않는다.

## 실행 환경과 재현

기존 Elixir/mix, psql, Python 3, Akashic 실행 파일이 필요하다. 검사 entrypoint는 설치나 형제 프로젝트 빌드를 수행하지 않는다. 현재 전용 테스트 컨테이너는 `atheum-cycle-test-pg-20261002`, localhost 55440, DB는 `atheum_cycle_test`다. Axiom DB는 사용하지 않는다. psql adapter는 explicit port를 가진 localhost의 `atheum_` DB 이름만 허용한다. URL query/fragment/password 및 escaped DB 이름은 연결 전에 거절하며, 검증한 host/port/user/DB를 별도 psql 인자로 전달한다. PGHOSTADDR/service를 제거하고 세션의 current_database도 SQL 실행 전에 확인한다. 이 제한은 인가 시스템을 대신하지 않는다.

```sh
./scripts/check format
./scripts/check precommit
ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
./scripts/check review
python3 scripts/check-hook
```

`precommit`: 포맷 확인, Elixir 강제 컴파일/경고 오류 처리, Credo strict, Dialyzer, 빠른 FC·관찰 경계 테스트. Dialyzer 경고 ignore 파일이나 Credo check 비활성화는 추가하지 않았다. `review`: precommit + 실제 PostgreSQL/CLI/RocksDB 테스트. `test-integration`은 실제 I/O만 요청하는 entrypoint지만 FC 테스트도 함께 실행한다. 필수 I/O 설정 누락은 BLOCKED(4)이며 통과로 표시하지 않는다. 로그/종료코드/명령은 ignored artifacts에 보존한다.

통합 테스트는 각자 새 Akashic 임시 DB와 고유 PostgreSQL 행을 만들고 본인 자원만 정리한다. PostgreSQL schema를 처음 구성하며 실제 종료와 쓰기 실패를 검증한다. 기존 PostgreSQL 서비스나 Axiom DB에는 연결하지 않는다. Akashic 프로세스는 요청별 재기동되며 기존 binary를 사용한다.

로컬 테스트 DB가 없을 때의 수동 준비 후보(현재 환경에는 이미 있음):

```sh
docker run --name atheum-cycle-test-pg-20261002 --label acropolis.task=atheum-cycle \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=atheum_cycle_test \
  -p 127.0.0.1:55440:5432 -d postgres:17-alpine
```

이 trust 설정은 localhost 전용 임시 검증 자원이다. 공개 서버를 구성하지 않는다. schema 설치는 `Atheum.Postgres.setup(config)`로 해당 전용 DB에 수행한다. 검증용 SQL에는 credential을 넣지 않는다.

## 공개 호출 예

Supplier S1이 존재하는 **별도의 실험 Akashic DB**와 그 DB에서 직접 얻은 expected version을 사용한다. 아래 설정은 테스트 fixture DB 경로를 의미하지 않는다.

```elixir
config = %{
  psql: System.find_executable("psql"),
  pg_url: "postgres://postgres@127.0.0.1:55440/atheum_cycle_test",
  binary: "/absolute/akashic/target/debug/akashic",
  akashic_db: "/absolute/dedicated/akashic-db",
  akashic_identity: "unique-identity-of-this-db-lifetime",
  storage: :snapshot,
  timeout_ms: 10_000
}
{:ok, _} = Atheum.Postgres.setup(config)
options = [deadline_ms: System.system_time(:millisecond) + 60_000, safe_retry: true]
{:ok, accepted} = Atheum.submit("local-key-1", %{
  "supplier_id" => "S1", "active" => false, "expected_version" => 1
}, config, options)
{:ok, completed} = Atheum.run(accepted["invocation_id"], config)
{:ok, events} = Atheum.history(accepted["invocation_id"], config)
```

Action 정의는 이 Function으로 고정하며 DSL이나 동적 등록은 없다. safe_retry의 기본값은 false이며 같은 DB의 receipt 보존 계약이 성립하는 로컬 실험에서만 true로 지정한다.

## 결과·취소·복구의 의미

`get`은 실행 상태, 현재 attempt, cancel_requested/stop_confirmed, effect_certainty, result/error, 원래 request를 반환한다. `history(id, config, opts)`는 접수·호출 의도·관찰 이력을 sequence 순으로 최대 100건 반환한다. `after_sequence`와 `limit`(1..100)으로 다음 페이지를 조회한다. 외부 API 필드의 후속 정리는 초기 설계 후보를 따른다. request의 context는 로컬 실험용이며 production 인가가 아니다.

- 성공한 실제 변경은 succeeded/confirmed_present. no-op 성공은 succeeded/confirmed_absent이며 result.changed=false로 구분한다. receipt 기록은 존재할 수 있다.
- 실행 전 취소는 시작 claim과 원자적으로 경합하며 stopped/not_started/stop_confirmed=true. 실행 중에는 요청만 기록하고 정지를 확인하지 않는다.
- 이미 성공한 효과는 취소로 되돌리지 않는다. 성공 관찰과 취소가 경합하면 succeeded와 cancel_requested를 함께 유지한다.
- PG/CLI 관찰 시간은 각각 1..60,000ms이며, PG는 `pg_timeout_ms`(없으면 timeout_ms, 둘 다 없으면 5,000ms)를 사용한다. connect/statement/lock timeout과 별도의 Port 관찰 한도를 적용한다. 각 프로세스의 누적 출력은 1MiB, CLI JSON 깊이는 32로 제한한다. 전체 API 호출의 단일 end-to-end deadline 보장을 뜻하지 않는다.
- 성공은 exit=0 및 정확한 `ok/result` 두 필드, 실패는 exit=2 및 정확한 `ok/error` 두 필드만 허용한다. error에는 문자열 code/detail이 필수이며 result/error가 함께 있거나 null로 추가된 경우도 거절한다. 중복 JSON key, 여러 JSON 값, 잘못된 타입·필수 필드 누락·unknown 필드·exit 불일치는 transport_failure/unknown으로 처리한다.
- 불완전·타입/버전 불일치 성공 응답도 transport_failure로 거절한다. Function 결과의 changed boolean, u64 version과 expected_version 관계, difference/work 구조를 검증한다.
- timeout/출력 한도 초과/불완전 stdout/저장 실패는 미발생 증거가 아니다. timeout은 unresolved/unknown이고 Port.close도 child 종료 증거가 아니다.
- 효과 성공 후 결과 기록 전 worker가 죽거나 PostgreSQL 쓰기가 실패하면 running/unknown과 호출 의도가 남는다. `recover`는 명시적 safe_retry, 유효 deadline, 취소 부재, 동일 target일 때만 정확히 같은 Apply를 전달한다. 이는 조회가 아니라 효과 수행 가능성이 있는 재전달이다.
- 취소나 만료 후에는 결과 회수 목적의 apply도 금지한다. 순수 receipt 조회 API가 없으므로 unknown을 남길 수 있다.
- akashic_identity는 운영자가 DB 생애를 식별하는 값이다. 경로/identity/storage 변경은 차단하지만 같은 경로에서 receipt를 삭제하거나 복원하는 것을 자동 탐지하지 못한다. 이런 변경 뒤 safe retry의 안전성을 보장하지 않는다. receipt 보존·DB 생애 관리·전용 receipt 조회는 후속 결정이다.

## 로컬 Git과 검사 hook

Atheum만 로컬 Git을 초기화하고 project-local core.hooksPath=.githooks를 설정했다. identity/remote/전역 설정/commit/push는 하지 않았다. hook은 tracked 파일의 부분 staging/unstaged 수정을 명확히 거절하고, 실제 index를 임시 디렉터리에 export해 그 staged 프로젝트에서 precommit을 실행한다. staged deletion과 untracked working-tree 파일도 구분한다. symlink/submodule/conflict index는 이 초기 hook에서 거절한다. 공식 deps·로컬 cache·artifacts만 공유하며 소스는 index에서 읽는다. fixture 검증은 통과·실패·부분 staging 거절·삭제 파일 제외·원본 및 fixture index 해시 불변을 확인하며 commit하지 않는다. artifacts/DB/cache/.env/키/빌드 파일은 ignore한다.

현재 응답 계약 수정 결과는 [envelope 수정 기록](verification/envelope-fix-20261002/REPORT.md)을 따른다. 이전 보완 결과는 [보완 검증 기록](verification/hardening-20261002/REPORT.md)에 보존했다. 초기 검증 증거와 독립 검증의 기준은 [VERIFICATION.md](VERIFICATION.md), 초기 계획은 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)를 참조한다.

## 로컬 단일 Docker 워커

`Atheum.Worker.Manager.run/recover/reconcile`이 Docker lifecycle의 단일 owner다. 기존 `Atheum.run/recover`는 host 실행 경계로 남아 있다. Docker 실행은 `config`에 `docker: System.find_executable("docker")`를 추가하고 Manager를 통해 호출한다. Manager의 capacity=1 예약은 같은 전용 PostgreSQL DB에 저장하며 같은 host의 BEAM 프로세스/VM 경합을 막는다. 한 host에 여러 Atheum DB를 구성하는 운영은 이 capacity 계약 밖이다.

`./scripts/build-worker`는 공식 Elixir base digest와 프로젝트 Dockerfile로 이미지를 빌드하고 `worker/image.json`에 image content ID와 source SHA256을 저장한다. Manager는 tag 대신 이 ID를 사용하고 source hash/image label을 검사한다. 임의 image/command 등록은 없다. worker는 고정 Supplier Function 입력을 검증하고 host에 effect 요청을 보낸 뒤 유효 observation으로 result envelope를 만든다. 실제 Akashic CLI/RocksDB I/O와 PostgreSQL 쓰기는 host의 기존 adapter가 수행한다.

컨테이너는 일회성이고 restart=no다. host mount, Docker socket mount, 공개 port가 없다. network=none, read-only rootfs, UID/GID 65534, cap-drop=ALL, no-new-privileges, CPU 0.5, memory/swap 128MiB, pids 64이며 `/tmp`에만 16MiB noexec/nosuid tmpfs를 허용한다. 통신은 Docker attach stdin/stdout의 제한된 JSON line뿐이다. Docker CLI의 host daemon 접근은 manager에 필요하며 컨테이너에는 제공하지 않는다.

WorkerSpec, instance name/generation, container ID, invocation/execution, job attempt/generation을 저장한다. create intent를 먼저 저장하고 created→ready→executing→effect_observed→result_received→exited→removed 관찰을 기록한다. 정확한 protocol/result envelope와 정상 종료를 확인하고 durable Function 결과까지 저장한 경우에만 succeeded를 반환한다. Docker exit 0만으로 성공하지 않는다. 강제 제거 후 부재 확인이 있어야 capacity를 해제한다. worker stop 증거는 host Akashic 효과 부재 증거가 아니다.

manager가 죽으면 예약이 남아 새 컨테이너 생성을 막는다. `Manager.reconcile(config)`는 이전 host VM이 살아 있으면 거절하고, 저장된 name/image/owner/generation/container ID로 컨테이너를 확인·회수한다. job은 unresolved/unknown으로 남기며 재시도하지 않는다. 이후 별도 `Manager.recover(id, config)`만 기존 safe_retry/deadline/취소/target 계약에 따라 같은 request receipt를 재전달하고 새 JobAttempt와 worker instance를 만든다. create 응답 유실 뒤 container ID가 없고 컨테이너도 확인할 수 없으면 예약을 유지한다. PID 재사용처럼 이전 VM 생존을 확정할 수 없는 경우도 보수적으로 복구를 거절한다.

실제 Docker 테스트는 `review`의 integration에 포함된다. Docker daemon과 빌드된 고정 이미지가 필요하다. 전용 임시 DB로 실행한 결과와 재현 명령은 [Docker 워커 검증 기록](verification/docker-worker-20261002/REPORT.md)에 있다.
