# Atheum–Akashic 첫 개발 사이클 계획

상태: 구현 전 계획의 기록 · 2026-10-02. 이후 작은 사이클 구현을 승인받아 Elixir/PostgreSQL을 가역적으로 선택했다. 현재 구현과 실제 응답 정규화, 검증 결과는 [README](README.md)와 [검증 기록](VERIFICATION.md)을 따른다. 이 계획의 기술 후보는 사용자 확정 아키텍처를 뜻하지 않는다.

## 1. 목표와 범위

등록 Action `supplier.set_active.v1`이 Function 하나를 실행해 Akashic Supplier의 active 값을 변경하고, Atheum에서 접수·결과·실행 이력을 영속 저장한 뒤 조회하는 작은 사이클을 만든다. 객체 일반화나 Akashic 미세 최적화보다 실제 사용 가능한 이 기능을 먼저 완성한다. Workflow/Agent/Archon, HTTP 서비스, 정책 엔진, 배포는 제외한다.

[초기 설계](INITIAL_DESIGN.md)의 불변식을 따른다. Axiom은 PAP/PRP, Arbiter는 외부 gateway·정책 전달·인가 context와 만료·회수 판단의 소유자다. 이번 단계에는 이 연동을 구현하지 않는다. 로컬 실험용 context와 미래 인가 검증 계약 자리를 구분하며 로컬 접수를 production 인가 구현으로 주장하지 않는다.

## 2. 읽어서 확인한 현재 계약

근거: [Akashic README](../akashic/README.md), [공개 request](../akashic/elixir/lib/akashic.ex), [Client](../akashic/elixir/lib/akashic/shell/client.ex), [CLI](../akashic/crates/akashic-engine/src/main.rs), [공개 wire 타입](../akashic/crates/akashic-engine/src/lib.rs). 이번 작업은 읽기 검토이며 실제 I/O 성공을 확인한 작업은 아니다.

- CLI는 `BINARY --db PATH --json JSON` 또는 `--records-db` 경로다. 성공 stdout은 `{"ok":true,"result":...}`와 exit 0, 오류는 `{"ok":false,"error":...}`와 exit 2다.
- Elixir Client는 요청마다 System.cmd로 동기 프로세스를 시작한다. binary/db 경로가 필요하며 storage는 snapshot/records를 지원한다. timeout/cancellation은 미구성이다. Akashic.request의 Job 결과와 Client의 {:ok,result}/{:error,error}는 서로 다른 경계이므로 호출 경로를 하나 선정하고 반환을 명시적으로 정규화해야 한다.
- Apply payload는 request_id, expected_version, operations다. 이번 Function의 operations는 `[{"op":"set_active","id":"S1","active":false}]`처럼 한 변경이다.
- 같은 request_id와 완전히 같은 요청은 최초 ApplyResult(version, changed, difference, work)를 반환한다. 실제 CLI 응답은 result.apply에 이를 담고 write_work/open_work 측정치를 따로 포함하므로 adapter가 정규화한다. 이 판정은 현재 버전 검사보다 먼저다. 다른 payload는 request_conflict, 새 요청의 stale 버전은 version_conflict다. no-op도 receipt를 저장하지만 version은 증가하지 않는다.
- request ID는 최대 128 UTF-8 bytes다. receipt는 현재 유한 실험에서 누적하며 장기 보존/GC 계약은 없다. 멱등성은 같은 Akashic DB 및 같은 요청에 한정한다.
- 공개 Command는 apply/impact/validate다. request ID만으로 receipt를 조회하는 API, 임의 객체 조회 API, 현재 버전 자동 조회 API는 없다. impact는 지정된 현재 버전의 차단 결과를 반환하며 과거 receipt 조회를 대체하지 않는다.
- README는 Akashic 내부 변경과 receipt가 같은 sync WAL 원자 batch에 저장됨을 설명한다. 이 내구성을 Atheum DB까지 확장하지 않는다. 동시 writer는 DB lock으로 거절된다.

## 3. 첫 입력과 연결 흐름

입력 후보: acceptance_key, supplier_id, active, expected_akashic_version, 고정 Action 버전, 실행 deadline, 실험 context. 첫 사이클에서는 expected version을 호출자가 명시한다. 충돌 시 버전을 자동 갱신하지 않는다.

1. Atheum DB 트랜잭션에서 접수 키/fingerprint, invocation, execution, accepted 사건을 저장한 뒤 식별자를 반환한다.
2. 실행권 확보와 함께 attempt, Akashic 대상 DB의 안정된 식별, request_id, 정확한 Apply payload 및 digest, 호출 의도를 저장한다. request_id는 논리적 효과별로 생성하며 같은 invocation의 재시도에도 유지한다. attempt ID를 request ID로 쓰지 않는다.
3. 해당 payload를 Akashic CLI에 전달한다. argv에 credential이나 비밀 입력을 넣지 않는다.
4. 성공 응답이면 결과와 receipt 재전달 근거를 Atheum DB에 저장하고 succeeded로 전이한다. changed=false는 성공한 no-op이며 실제 객체 변경 발생과 구분한다.
5. 조회는 Atheum DB의 상태·결과·attempt 이력·효과 증거·취소 요청·정지 확인·복구 필요 여부를 반환한다. Atheum 성공 응답은 이 기록이 커밋된 뒤에만 내보낸다.

최초 실험 fixture는 독립 Akashic DB에 Supplier S1(active=true), Part B, Product P 및 S1→B supplies/B→P requires를 공개 apply로 준비한다. 실행 입력은 S1=false이며 결과는 P가 B 때문에 차단되는 알려진 사례다. fixture의 버전은 fixture ApplyResult에서 받는다. 기존 DB는 사용하지 않는다.

## 4. 영속 경계와 장애 처리

Atheum journal 저장소와 Akashic RocksDB는 별개의 커밋 경계다. 분산 트랜잭션이나 외부효과 exactly-once를 약속하지 않는다.

| 관찰/중단 지점 | 저장할 의미와 후속 판단 |
| --- | --- |
| 접수 커밋 전 실패 | 접수 성공을 응답하지 않음. 같은 키로 다시 접수 가능 |
| 호출 의도 저장 전 실패 | 외부 호출 금지. 미시작 증거를 보존 |
| 의도 저장 후 프로세스 시작 여부 불명 | unresolved/effect unknown. 의도 기록만으로 미발생 추정 금지 |
| Akashic 성공 후 Atheum 결과 저장 전 중단 | unresolved. 아래 조건이 충족되면 동일 request_id/payload를 재전달하여 최초 결과 회수 또는 미실행 요청을 안전하게 수행하고 결과 저장 |
| version_conflict | 해당 요청이 거절되었다는 근거를 기록. 자동 rebase/새 request ID 금지. 기존 불명확 attempt가 있는 경우 잔여 실행 가능성을 별도로 유지 |
| request_conflict | 계약 위반으로 실패 및 운영 확인 필요. payload/ID를 바꿔 우회하지 않음 |
| transport_failure/timeout | 외부효과 미발생으로 해석하지 않음. 수행 종료 불명이면 unresolved, 종료 확인됐지만 효과 불명이면 failed+unknown |
| DB lock/저장 오류 | receipt 부재 또는 효과 미발생으로 단정하지 않음. 오류 분류의 실제 계약을 검증한 뒤 복구 판단 |

**재전달은 순수 조회가 아니다.** receipt가 없으면 새 효과를 수행한다. 기본 금지이며 이 Function의 명시적 opt-in, 같은 DB의 receipt 보존, 정확한 동일 payload, 유효한 deadline/context, 취소·만료·회수 부재, 멱등성 계약의 실제 I/O 검증이 충족될 때만 허용한다. expected_version도 최초 값을 그대로 유지한다. DB 교체·receipt 유실·보존 보장 부재이면 unknown을 유지한다. 현재 replay는 최초 호출의 적용 여부를 따로 알려주지 않으므로 회수와 신규 적용을 구분했다고 주장하지 않는다.

## 5. 취소·timeout의 현실적 한계

- 실행 전 취소: Atheum DB에서 시작 claim과 취소를 원자적으로 경합시켜 시작이 차단됐음을 확인한 경우만 stopped/not_started.
- 실행 중 취소: 요청을 영속 기록하지만 현재 Akashic 계약에는 원격 취소가 없다. 요청을 정지 확인으로 반환하지 않는다. 정상 성공이 뒤늦게 오면 succeeded와 cancel_requested를 함께 남긴다. 이미 완료된 객체 변경을 되돌리지 않는다.
- timeout: 관찰 deadline 초과를 먼저 기록한다. 프로세스 종료 확인과 효과 발생 확인을 분리한다. 로컬 subprocess를 종료해도 커밋된 효과는 취소되지 않는다. 현재 System.cmd Client에 timeout 기능이 있다고 가정하지 않는다.
- 취소·deadline 만료·외부 인가 회수 후에는 기존 apply의 재전달을 결과 조회 목적으로도 하지 않는다. receipt가 없으면 취소 뒤 새로운 효과를 만들 수 있기 때문이다. 이미 진행 중인 호출의 자연스러운 결과 수신은 허용하지만 새 호출은 금지한다.
- 이 경우 receipt 전용 조회가 없어 unknown 자동 해소가 막힐 수 있다. 상태·근거·복구 필요를 그대로 노출하며 임의 성공/미발생으로 확정하지 않는다. 순수 receipt 조회 추가는 별도 Akashic 후속 계약으로 제안할 수 있으나 이번 변경 범위에는 포함하지 않는다.

## 6. Elixir/PostgreSQL 후보 평가

| 후보 | 적합한 점 | 확인할 비용/한계 |
| --- | --- | --- |
| Elixir | Akashic wire 경험과 실행 제어/감독 구조를 활용할 수 있음. FC/IS 분리가 자연스러움 | Akashic 프로젝트 의존 여부는 미정. 현재 동기 Client만으로 deadline 제어가 불충분하므로 Atheum subprocess adapter의 프로세스 소유권·종료 관찰을 검증해야 함 |
| PostgreSQL | 접수 unique 제약, journal+상태 트랜잭션, 조건부 claim/update, 재기동 후 이력 조회 후보 | 서비스·driver·migration·테스트 컨테이너 비용. Akashic와 원자 커밋 불가. 설치 상태와 연결 가능 여부는 미확인 |

권고는 Elixir + PostgreSQL로 위 요구를 작은 범위에서 검증하는 것이다. 사용자 확정으로 취급하지 않는다. 직접 CLI adapter는 형제 프로젝트 의존을 줄일 수 있고, 기존 Elixir 공개 경계 재사용은 wire 처리를 줄일 수 있으나 timeout 제어 계약을 별도로 확인해야 한다. 전송/배포 방식도 확정하지 않는다.

## 7. 최소 변경 파일 범위와 개발 순서

계획 작성 당시 변경은 이 문서뿐이었다. 이후 승인된 구현은 아래 경계를 따라 Atheum 안에 추가되었다. 후속 구현이 승인되면 파일은 모두 atheum 아래에 둔다. 후보 범위:

- mix.exs/lock, 최소 lib/atheum 공개 접수·조회·취소 경계
- core의 상태 전이 및 복구 판단, 단일 supplier Function 정의
- shell의 PostgreSQL journal adapter와 Akashic subprocess adapter
- journal/접수 제약의 최소 migration, 독립 실제 I/O 및 공개 경계 테스트
- 실행·검사 entrypoint와 README. 정확한 파일명·dependency·schema는 기술 선택 후 결정

개발 순서: (1) 입력·식별·상태/API 계약 확정 (2) 영속 접수·조회 (3) Function의 실제 Akashic 호출 및 결과 기록 (4) 경계 중단·재전달 복구 (5) 취소·timeout 의미 검증. 각 단계에서 바깥 경계 동작을 확인하고 다음 단계로 진행한다. Akashic/Axiom 및 상위 경로 변경과 최적화는 포함하지 않는다.

## 8. 실제 I/O와 독립 수용 기준

아래는 필요한 미래 검증이며 이번에는 실행하지 않았다. PostgreSQL 선택 시 격리된 실제 서비스, Akashic은 테스트별 임시 실제 RocksDB와 실제 CLI를 사용한다. mock 성공으로 I/O 완료를 대체하지 않는다. 장애 지점은 명시적 barrier로 제어하고 임의 sleep으로 맞추지 않는다.

| 목적 | 독립 근거와 최소 수용 기준 |
| --- | --- |
| 정상 사이클 | 위 fixture의 공개 impact(full/incremental) 결과가 P→B 차단이라는 수동 정답과 일치. Atheum 결과의 version/changed/difference가 실제 ApplyResult와 일치 |
| 접수 멱등성 | 동시 접수·응답 유실 뒤 동일 invocation/execution 하나. payload 변경은 충돌. 실제 SQL 독립 조회로 확인 |
| 영속성 | Atheum 재시작 후 상태/결과/사건 순서 보존. Akashic 프로세스 재시작 후 동일 payload replay가 최초 결과 반환 |
| 중복 효과 | 다른 새 요청으로 Akashic 현재 버전을 진전시킨 뒤 원래 요청 replay도 최초 version을 반환. 실제 impact를 진전된 버전으로 읽어 replay가 버전을 더 늘리지 않았음을 확인. 단순 객체 최종값만으로 중복 방지를 판정하지 않음 |
| 핵심 중단 | 실제 Akashic 성공 응답 후 Atheum 결과 커밋 전 worker 종료. 재시작·동일 요청 복구 후 최초 결과와 이력 회수. 재호출은 실제 있을 수 있지만 효과를 중복 적용하지 않음 |
| 원자성 | 접수와 상태 기록의 PostgreSQL 트랜잭션 실패 시 고아 접수/근거 없는 상태 없음. Akashic 효과가 이미 커밋된 뒤 PostgreSQL 쓰기 실패는 unresolved로 남고 효과 원복을 주장하지 않음 |
| 취소 | 시작 전 취소는 호출 없음. 실행 중 취소는 정지 미확인. 효과 성공 후 취소는 효과 보존. 취소 후 복구 apply 재전달 없음 |
| timeout/unknown | 응답 유실/늦은 결과/실제 subprocess 종료를 구분. timeout 직후 미발생 확정 없음. 늦은 결과는 원래 attempt로 기록하고 최신 상태를 덮어쓰지 않음 |
| 오류/복구 금지 | version/request 충돌, lock, transport 실패를 실제 의존성으로 재현. deadline 만료·취소·DB 교체·receipt 보장 부재에서 새 apply 없음 |
| API 정직성 | failed+unknown, unresolved, cancel_requested+stop_confirmed=false를 각각 노출. 복구 불가 조건을 이유와 함께 반환 |

## 9. 구현 전에 남은 중요한 결정

1. Elixir/PostgreSQL 채택 여부와 런타임/driver 버전, 실제 테스트 자원 가용성.
2. 기존 Elixir 공개 클라이언트 재사용 또는 Atheum 직접 CLI adapter, 프로세스 제어 방식과 timeout 후 관찰 수명.
3. 최초 snapshot/records 선택, DB의 안정된 식별과 교체 탐지, receipt 보존 전제. 장기 GC는 이번 범위 밖.
4. expected version 입력·충돌 응답 규칙, Action 등록 방식, fingerprint와 결과/증거 보존 기간.
5. 취소·만료 후 순수 receipt 조회가 없어 남는 unresolved를 초기 수용 범위로 인정할지, 별도 Akashic 계약 확장이 먼저 필요한지.
6. 로컬 실험 context와 미래 Arbiter 검증 계약의 경계. Axiom/Arbiter 연동 자체는 후속 단계.
