# Atheum 초기 설계

문서 상태: 초기 설계 제안 · 작성일: 2026-10-01

## 1. 범위와 결정 수준

Acropolis는 전체 시스템의 이름이다. Atheum은 그 안에서 실행을 담당하는 경계다. 상위 `alaya` 경로 이름을 바꾸지 않는다.

이 문서의 **확정 제약**은 요청에서 주어진 책임과 안전 조건이다. **권고**는 후속 검토가 필요한 설계 선택이다. 언어, 저장소 제품, 전송 방식, 프로세스 수, 배포 단위는 **미정**이다. 같은 저장소에 있어도 같은 프로세스나 배포여야 한다는 뜻은 아니다.

초기 구현 범위는 Acolyte가 Function 하나를 접수하고 실행하며, 실행 기록을 남기고 취소와 장애 복구를 처리하는 것이다. Workflow와 Agent의 실행 엔진은 범위 밖이며 향후 어댑터 계약 후보만 정의한다. 구현 코드, 설치, 데이터베이스 구축, 배포는 이 문서의 범위에 포함하지 않는다.

## 2. 책임 경계

| 구성 요소 | 책임 | Atheum과의 관계 |
| --- | --- | --- |
| Acolyte | Function 실행, 실행 이력, 취소 처리, 장애 후 복구 | 초기 실행 주체 |
| Archon | 미래의 실행 제어, 조정, 계획 및 감독 | Acolyte와 책임을 분리한다. 초기 의존성으로 요구하지 않는다 |
| Axiom | PAP/PRP 관리와 조회 | 정책 관리 및 조회의 소유자. Atheum에 정책 관리 기능을 복제하지 않는다 |
| Arbiter | 외부 gateway, 정책 전달, 인가 context 부여 | 외부 요청의 인가 경계. 전달된 context를 실행에 결합한다 |
| Akashic | 객체와 객체 관계 저장 | 관계 정보의 소유자. 실행 journal의 내구성과 원자성을 자동으로 보장한다고 가정하지 않는다 |

PAP/PRP의 상세 의미와 조회 API는 Axiom 계약에서 확인할 미정 사항이다. Arbiter가 부여하는 인가 context의 무결성, 만료, 실행 중 철회 처리도 통합 계약으로 확정해야 한다. 인가의 만료·회수 판단은 외부 Arbiter 경계에 두며, Atheum은 전달된 판단과 제약을 적용하고 기록한다. Atheum이 자체 정책 판단으로 인가를 연장하거나 회수를 무시하지 않는다. 만료·회수가 확인되어도 이미 실행 중인 호출의 정지나 외부효과 미발생을 뜻하지 않는다. Acolyte가 외부 gateway나 정책 관리자가 되는 것은 범위에 포함하지 않는다.

권고: Acolyte의 실행 계약과 Archon의 제어 계약을 논리적으로 분리한다. 미래 Archon은 동일한 접수·취소·조회 계약을 사용하고 journal을 직접 수정하지 않는다. Akashic 관계 기록은 실행 journal과의 동시 트랜잭션을 전제하지 않고, 내구성 있는 전달 및 재조정 계약을 별도로 검토한다.

## 3. 식별과 접수 멱등성

아래는 최소 연결 계약 **제안**이다. Action은 등록된 수행 의도 정의이며 정책 판단이나 범용 DSL을 포함하지 않는다. 초기 Action은 고정 버전의 Function 하나와 입력 계약, 취소·조회 capability, 재시도 및 효과 멱등성 계약을 참조한다. 등록 주체와 저장 위치는 미정이다.

- `action_id` + `action_version`: 등록된 수행 의도 정의의 고정 참조. 접수 뒤 정의가 바뀌어도 기존 호출의 의미는 바뀌지 않는다.
- `invocation_id`: Action 호출을 접수한 논리호출 식별자. 응답 유실에 따른 재접수와 같은 호출의 재시도에도 유지된다.
- `execution_id`: invocation을 수행하는 실행 기록 식별자. 초기에는 invocation당 하나이며 복구·재시도에도 유지된다.
- `attempt_id`: execution의 개별 수행 시도 기록 식별자. 새 재시도에는 새 값이 생긴다. 어댑터 호출 및 관찰은 이 값으로 구분한다.
- 접수 멱등성 키: 요청자/tenant 및 Action으로 범위를 제한하는 접수 키. 호출 식별자와 별개다.
- 외부효과 멱등성 키: 실제 외부 작업의 중복 방지 키. 접수 키나 식별자만으로 외부효과가 멱등적이라고 주장할 수 없다.

호출 접수 인터페이스 후보는 `submit(action_ref, input, acceptance_key, authorization_context, deadline)`이다. 접수 응답은 invocation_id와 execution_id를 반환한다. 조회 및 취소는 invocation_id를 받아 대응하는 실행 기록을 찾는다. 정책 평가 입력 언어나 실행 계획 문법을 추가하지 않는다.

권고: 접수 키와 정규화된 요청 fingerprint를 invocation 및 execution에 원자적으로 연결한다. 같은 키·같은 요청은 기존 invocation/execution을 반환한다. 같은 키·다른 요청은 충돌로 거절한다. fingerprint에는 고정 Action 참조, 입력 및 인가 범위 등 요청 의미를 포함하며 정확한 정규화 규칙은 미정이다. 키 보존 기간과 만료 후 재사용 의미를 명시한다. 접수 응답 유실 뒤 재접수해도 논리호출과 실행을 추가 생성하지 않아야 한다.

하나의 attempt가 여러 외부효과를 낼 수 있다. 이 경우 effect 단위 식별 및 각각의 멱등성 계약이 필요하다. 실행에는 고정 Action/Function 버전, 입력 참조 또는 digest, 인가 context 참조, deadline, 취소·재시도 정책을 결합한다. 새로운 논리호출은 새 invocation/execution이며, 기존 호출의 재시도는 같은 invocation/execution 안의 새 attempt다.

## 4. 상태와 외부효과 확실성

실행 상태와 외부효과의 확실성은 별도 축으로 기록한다. 완료 여부만으로 외부효과의 발생 여부를 추론하지 않는다.

execution의 최소 상태 전이 **제안**은 아래와 같다. `accepted`는 내구성 있는 접수이며 실행 시작을 의미하지 않는다. `unresolved`는 수행 종료 여부가 불명확한 상태다. attempt에는 별도 시작·관찰·종료 기록을 두고 invocation은 실행 기록을 참조한다.

| 현재 상태 | 사건과 필요한 증거 | 다음 상태 |
| --- | --- | --- |
| accepted | 소유권과 유효한 인가 제약 확인, 호출 의도 커밋 | running |
| accepted | 실행 전 취소와 시작 차단을 원자적으로 확정, 호출 미시작 증명 | stopped; 효과 not_started |
| accepted | 시작 전 검증 실패 또는 Arbiter의 만료·회수 판단 적용, 시작 차단 확정 | failed; 효과 not_started |
| running | 권위 있는 수행 성공 확인 | succeeded; 효과는 별도 증거로 결정 |
| running | 권위 있는 수행 실패 및 해당 시도 종료 확인 | failed; 효과 unknown도 허용 |
| running | 정지 확인 | stopped; 효과는 별도 증거로 결정 |
| running | timeout·응답 유실·소유권 상실 등으로 종료 불명 | unresolved; 효과는 기존 증거 유지, 확인 불가 시 unknown |
| unresolved | 권위 있는 조회로 성공·실패·정지 확인 | 각각 succeeded / failed / stopped |
| unresolved | 같은 attempt가 여전히 수행 중임을 권위 있게 확인 | running; 새 호출을 시작하지 않음 |
| unresolved 또는 failed | 6절의 재시도 조건과 인가 제약 충족, 소유권 및 새 attempt 의도 원자 기록 | running; invocation/execution 유지 |
| succeeded / failed / stopped | 늦은 효과 증거 도착 | 수행 상태 유지, 효과 확실성과 근거만 갱신 |

취소 요청만 접수했거나 조회가 실패한 경우 수행 상태를 정지 확정으로 바꾸지 않는다. 실행 전 취소와 시작이 경합하여 미시작을 증명하지 못하면 running/unresolved 경로를 따른다. confirmed_present 자체는 수행 성공의 증거가 아니므로 효과 발생만으로 succeeded로 전이하지 않는다. failed/stopped는 확인된 시도의 종료를 표현하고, 효과 정산까지 완료했다는 뜻은 아니다. unresolved에서 재시도할 때 기존 시도의 잔여 실행까지 포함해 안전성을 확인해야 한다.

외부효과 확실성 후보:

| 값 | 의미 |
| --- | --- |
| `not_started` | 외부 호출이 시작되지 않았다는 증거가 있음 |
| `confirmed_absent` | 권위 있는 확인으로 효과 미발생을 확인함 |
| `confirmed_present` | 권위 있는 확인으로 효과 발생을 확인함 |
| `unknown` | 발생 여부를 확인할 수 없음 |

확실성에는 증거의 출처, 관찰 시각, 적용 범위를 남긴다. 여러 효과가 있으면 효과별로 기록하고 전체를 단일 boolean으로 축약하지 않는다. Function의 반환 성공도 모든 외부효과의 영속성을 증명하지 못할 수 있다.

취소는 별도 요청 사실과 확인 사실로 기록한다. `cancel_requested`는 정지 확인이 아니다. timeout은 관찰 기한이 끝났다는 사실이며 효과 미발생을 뜻하지 않는다. `stopped`도 이미 발생한 효과가 되돌려졌다는 뜻은 아니다. 응답 성공과 취소가 경합하면 실제 완료 증거와 취소 요청을 함께 보존하며 성공을 취소 완료로 덮어쓰지 않는다.

조회 API 최소 표현 **제안**: `invocation_id`, `execution_id`, `current_attempt_id`, `execution_status`, `effects[]`(effect_id, certainty, evidence_ref), `cancel_requested`, `stop_confirmed`, `reconciliation_required`, `retry_eligibility`(allowed, reason, evidence_ref)을 각각 반환한다. 단일 cancelled 플래그로 요청과 정지를 합치지 않는다. attempt 이력과 증거는 재시도 후에도 보존한다. 기존 시도의 늦은 결과는 해당 attempt에 귀속시키고 최신 시도의 수행 상태를 직접 덮어쓰지 않는다. 실행 전 정지로 attempt가 없는 경우 current_attempt_id는 비어 있을 수 있다.

예를 들어 수행 실패가 확인됐지만 효과가 불명확하면 `execution_status=failed`, `effects[].certainty=unknown`, `reconciliation_required=true`로 표현한다. 정지 확인이 없으면 `stop_confirmed=false`이며 재시도는 기본 `allowed=false`다. 수행 종료도 불명확하다면 failed 대신 unresolved를 사용한다. 재시도가 허용될 때도 unknown을 임의로 confirmed_absent로 바꾸지 않는다.

## 5. 실행·취소·복구 절차

1. 요청과 인가 context를 검증하고 접수 키 충돌을 검사한다.
2. invocation/execution 생성, 접수 키 연결, 접수 journal을 한 원자적 변경으로 저장한 후 접수 성공을 응답한다.
3. attempt 생성과 호출 의도를 먼저 내구성 있게 기록한다.
4. 실행 소유권을 확인한 worker만 Function 어댑터를 호출한다.
5. 반환값, 오류, 정지 확인, 효과 증거를 journal에 기록하고 상태 투영을 같은 원자적 변경으로 갱신한다.
6. 취소 요청은 먼저 기록하고 어댑터에 전달한다. 정지 확인이 없으면 요청만 존재하는 상태로 표시한다.
7. 재기동 시 미종결 attempt의 권위 있는 상태를 조회한다. 수행 종료 확인이 불가하면 `unresolved`를 유지하고, 효과는 기존 증거를 보존하며 확인되지 않은 효과만 `unknown`으로 둔다.

권고: lease와 fencing token으로 실행 소유권을 관리한다. lease 만료는 기존 worker의 종료 증거가 아니다. 외부 시스템이 fencing을 지원하지 않으면 중복 외부 실행을 완전히 막을 수 없으며, 불확실한 호출의 자동 재실행을 제한한다.

호출 의도 저장과 외부효과 발생 사이에는 일반적으로 단일 트랜잭션이 없다. 의도만 기록된 호출도 장애 시점에 따라 이미 외부로 전송되었을 수 있다. journal만으로 exactly-once 실행을 보장하지 않는다.

## 6. 안전한 재시도

Safe retry는 기본 비활성이고 Function별 명시적 opt-in이다. 등록 계약은 멱등성 키의 범위·보존 기간, 원자적인 중복 방지, 상태 조회 가능 여부, 재시도 가능한 오류를 설명해야 한다. 모든 재시도에는 유효한 인가 제약과 남은 실행 기한이 필요하며, 취소 요청 또는 Arbiter의 만료·회수 판단이 적용된 호출은 재시도하지 않는다.

- 호출 전 실패를 증명할 수 있으면 새 attempt를 검토할 수 있다.
- 효과가 confirmed_absent이고 Function 계약이 허용하면 새 attempt를 검토한다. 단순 조회 시점의 미발생만으로는 부족하며 기존 시도가 이후 효과를 낼 수 없다는 증거 또는 잔여 실행까지 중복 방지하는 멱등성 보장이 필요하다.
- 효과가 confirmed_present면 기존 결과 회수 또는 조정으로 진행한다.
- 효과가 unknown이면 재시도는 기본 금지다. 명시적 opt-in에 더해, 어댑터가 실제로 보장하는 권위 있는 조회 또는 외부효과 멱등성으로 해당 재호출의 안전성이 확인된 경우에만 허용한다. 조회가 미발생을 확인하면 confirmed_absent로 갱신하고 그 조건을 적용한다. unknown이 남는 경우에는 기존 시도의 잔여 실행과 재호출 모두에 대해 중복 효과를 막는 멱등성 보장이 필요하다. 조회 capability의 존재, timeout, 연결 오류만으로는 허용하지 않는다. 판단 근거·키 범위·보존 기간의 유효성을 기록한다.

새 attempt에서도 동일한 논리적 효과의 외부효과 키를 유지한다. invocation_id와 execution_id도 유지하며 attempt_id만 새로 만든다. 효과 키의 보존 기간이 지났거나 안전 계약이 적용되지 않으면 재시도를 허용하지 않는다. 보상은 재시도와 별개의 외부효과이며 별도 계약과 기록이 필요하다. 초기 범위에 일반 보상 엔진은 포함하지 않는다.

## 7. Journal과 원자성

권고 journal 필드: event_id, execution_id, attempt_id, invocation_id, execution 내 단조 sequence, 사건 종류, 기록 시각, 관찰 시각, actor, 인가 context 참조, Function 버전, 효과 증거 참조, 오류 분류, correlation 정보.

필수 원자성 조건:

- 접수 키 예약·invocation/execution 생성·접수 사건이 함께 커밋된다.
- 상태 전이와 근거 사건이 함께 커밋된다. 또는 journal만을 진실의 원천으로 두고 투영 지연을 API에 드러낸다.
- 동일 sequence/event의 중복 기록과 경쟁 전이를 저장 계층에서 차단한다.
- 호출 의도 커밋 실패 시 외부 호출을 시작하지 않는다.
- 마지막 소유권 버전과 기대 상태를 조건으로 기록하여 늦은 worker가 최신 상태를 덮어쓰지 못하게 한다.

저장소 선정 기준은 원자적 변경, unique 제약, 조건부 갱신, crash durability, 조회와 보존 요구다. 특정 제품이나 언어는 확정하지 않는다. journal에 비밀값과 전체 인가 credential을 기록하지 않고 검토 가능한 참조와 최소 메타데이터만 보존한다.

## 8. Function 계약과 향후 어댑터 후보

초기 Function 계약 후보는 `invoke`, `observe`, `request_cancel`이다. invoke에는 식별자, 고정 버전, 입력, 인가 context, deadline, 효과 키, 소유권 정보를 전달한다. 반환은 결과 또는 오류 외에 효과 확실성·증거를 표현해야 한다.

observe와 request_cancel의 지원 여부를 capability로 명시한다. 미지원 응답과 확인 불가 응답을 구분한다. cancel 응답은 요청 접수, 정지 확인, 이미 완료를 구분한다. observe가 조회 실패했다고 효과 미발생으로 해석하지 않는다.

Workflow와 Agent는 같은 수명주기·식별·효과 증거 경계를 사용할 수 있는 후보지만, 다단계 실행과 자식 실행 관계는 후속 설계 대상이다. 초기 Function에 그들의 상태 머신이나 계획기를 끼워 넣지 않는다.

## 9. FC/IS 검토 기준

FC/IS는 Functional Core / Imperative Shell 구조로 정리한다. 이는 초기 설계 권고이며 언어나 프레임워크를 고정하지 않는다.

FC에는 상태 전이 허용 여부, 취소 경합 해석, 효과 확실성에 따른 복구·재시도 판단을 둔다. 명시적인 현재 상태와 사건을 입력받아 다음 상태와 실행할 명령을 반환하며 네트워크, 저장, 시계 조회를 직접 수행하지 않는다. 시간과 인가 검증 결과도 입력으로 전달한다.

IS에는 journal 트랜잭션, lease 및 fencing, Function 호출, 권위 있는 상태 조회, 취소 전달, 시각 수집을 둔다. FC가 반환한 명령을 수행하고 결과를 사건으로 변환한다. FC의 판단만으로 저장 원자성이나 외부효과 안전성이 보장되지는 않으므로 각 경계를 독립 검증한다.

## 10. 목적별 독립 검증 기준

아래는 후속 구현의 수용 기준이며 이 문서 작업에서 실행한 테스트가 아니다. 같은 구현 로직을 기대값으로 복제하지 말고, 외부 호출 계수·독립 관찰 기록·영속 기록 등 별도 근거로 검증한다.

| 목적 | 독립 검증 기준 |
| --- | --- |
| 기능 정확성: 정상 실행 | 고정 Function과 입력의 알려진 결과, 한 execution의 완전한 사건 순서를 대조 |
| 접수 멱등성 | 동시·반복 접수 및 응답 유실에도 invocation/execution 하나. 다른 payload의 동일 키는 충돌 |
| 외부효과 멱등성 | 외부 측 효과 계수로 중복 방지를 확인. 접수 중복 방지 결과와 독립 평가 |
| 원자성 | 각 커밋 경계에서 장애를 주입하여 고아 접수 키, 근거 없는 상태, 기록 없는 호출이 없는지 확인 |
| 취소 | 실행 전 취소의 원자적 시작 차단, 지연·미지원·완료 경합에서 요청과 정지 확인을 구분. 외부 관찰과 정지 주장 대조 |
| timeout | 응답 유실 뒤 실제 효과가 발생한 사례가 unknown 또는 증거 기반 confirmed_present로 남는지 확인 |
| 복구 | 의도 저장 전후, 외부 발생 전후, 결과 저장 전후의 장애별로 재호출과 회수 결정 검증 |
| 재시도 | opt-in 부재 또는 안전성 근거 부재 시 재호출 없음. unknown은 6절의 실제 보장과 근거를 충족할 때만 허용. invocation/execution 및 효과 키 유지, 새 attempt, 기존 시도 잔여 실행의 중복 방지와 계약 유효성 확인 |
| 실행 소유권 | lease 만료·오래된 worker 복귀 때 stale 상태 쓰기 차단. 외부 fencing 미지원 한계도 검증 |
| 인가 경계 | 만료·변조·범위 불일치 context를 거절하고 요청·실행·감사 기록의 결합을 확인 |
| 상태와 API | unresolved의 해소 전이가 권위 있는 수행 증거와 일치하고 failed+unknown, 취소 요청+정지 미확인을 별도 필드로 반환 |
| Action 연결 | 고정 Action 버전의 접수·조회·취소가 같은 invocation/execution에 연결되고 재시도만 새 attempt를 생성 |
| 기록 회수 | journal에서 상태 재구성 결과와 읽기 API를 비교하고 투영 지연을 구분 |

## 11. 다음 결정 사항

Action 등록 주체·저장 위치·버전 규칙과 요청 fingerprint 정규화, 상태/API 제안의 확정, Function 계약의 효과 조회와 취소 능력, 인가 만료·철회 규칙, 멱등성 보존 기간, journal 저장소의 원자성 방식, 결과 및 증거 보존 기간을 먼저 확정한다. 이후 언어·저장소·프로세스·배포를 선택한다. Archon 도입과 Workflow/Agent 실행은 초기 Function의 복구 및 안전 조건이 검증된 뒤 별도 설계한다.
