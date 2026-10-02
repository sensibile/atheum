# Atheum 독립 보안 검증 — 2026-10-02

## 판정과 범위

실제 소스 및 실행 경계를 한 차례 수동 검토했다. **신뢰된 로컬 BEAM 호출자라는 현재 전제에서 새로운 권한을 획득하는 공격 경로는 이번 검증에서 입증하지 못했다.** 아래에는 재현된 DB 보호 조건의 결함 1개와 응답 신뢰·자원 제한의 보완사항 2개를 남긴다. 전체 안전, 공식 감사 완료, Standard security-scan 완료를 의미하지 않는다.

대상은 `/Users/tonton/Documents/workspace/alaya/atheum`의 `lib/atheum.ex`, `lib/atheum/{core,postgres,akashic}.ex`, `priv/schema.sql`, 테스트·실행 스크립트·README다. Function 접수, PostgreSQL journal, Akashic 객체 변경, 동일 Apply의 복구, 취소·timeout·unknown·stale worker 보호를 검토했다. Arbiter 인증/정책 전달, Axiom 관리, 외부 gateway, 공개 API는 제외했다. Akashic의 CLI argv 및 receipt 계약만 형제 소스를 읽어 확인했으며 그 저장 엔진 전체를 감사하지 않았다.

구현 대화나 다른 검증자의 보고서·결론은 읽지 않았다. 기존 `VERIFICATION.md`, `verification/independent-20261002/*`도 검증 근거로 읽지 않았다. README와 실제 테스트는 운영 조건 및 재현 절차의 근거다.

## 절차·스냅샷·한계

- 적용 가능한 상위 경로와 Atheum 최상위에서 AGENTS.md/SECURITY.md를 확인했으나 파일이 없었다. 경계 계약을 읽은 Akashic의 AGENTS.md는 읽기 전용으로 확인했다.
- `codex-security:security-scan` SKILL.md와 desktop-scan 참조를 확인했다. 활성 도구 목록에는 `start_codex_security_standard_scan`, `start_codex_security_prompt_only_scan`, capability preflight, core audit, progress/draft/complete 도구가 없었다. `references/scan-prologue.md` 읽기는 `failed to read skill resource`로 실패했다. 따라서 필수 ready preflight, 독립 audit worker, canonical artifact/finalization은 수행하지 못했다. 이 파일은 **수동 verification 보고서**다. Standard의 정식 산출물처럼 seal하거나 성공 처리하지 않았다. 토큰 사용량 측정은 제공되지 않았다.
- 저장소 HEAD는 unborn이며 commit이 없다. 커밋 해시 대신 [source-hashes.json](source-hashes.json)에 검토 전 SHA-256을 고정했다. [unchanged.json](unchanged.json)으로 검토 후 해당 Atheum 파일이 모두 동일함을 확인했다. 보고서와 새 검증 fixture만 `verification/security-20261002`에 추가했다.
- Akashic 실행 파일 SHA-256: `eeacb10fefdbf76bd086c7288aa9eab0a202aca57e5f1d27d1a754b93f446230`. [binary-hash.txt](binary-hash.txt), [boundary-source-hashes.json](boundary-source-hashes.json)을 보존했다. 바이너리를 다시 빌드하지 않았으므로 현재 형제 소스와의 재현 가능한 빌드 동등성은 주장하지 않는다.
- 종료 검사에서 Atheum 대상 파일, Akashic 검토 코드 3개와 바이너리는 동일했다. 형제 `akashic/AGENTS.md`만 외부에서 변경된 것을 [boundary-final-drift.json](boundary-final-drift.json)에 기록했고 새 지침을 재확인했다. 변경은 gate 결과 보고서 참조의 갱신이며 검토한 실행 경계 코드에 영향이 없다. 본 검증은 형제 파일을 수정하지 않았다.
- Mix 실행은 sandbox의 TCP filesystem lock 제한으로 실패했다([baseline.log](baseline.log)). 설치·생산 코드 수정 없이 Elixir가 실제 소스를 직접 로드해 ExUnit을 실행했다. README에 명시된 `127.0.0.1:55440/atheum_cycle_test`만 이용했다. 각 기존 통합 테스트는 고유 identity/행·임시 Akashic DB를 생성하고 자기 자원을 정리한다. 결과 쓰기 실패 테스트의 임시 trigger는 한 invocation에만 적용하며 해제된다. Axiom/다른 DB는 연결하지 않았다.
- 기존 테스트 14개 통과([baseline-elixir.log](baseline-elixir.log)), 새 격리 probe 7개 통과([security-probe.log](security-probe.log)), 실제 PG 읽기 전용 probe 통과([pg-probe.log](pg-probe.log)). 테스트 합격은 검토 범위의 동작 증거이며 전체 보안 증명은 아니다. 설치·네트워크 공개·commit/remote/push·배포는 수행하지 않았다.

## 신뢰 모델

현재 호출자는 같은 BEAM VM에서 함수, config, opts를 넘기는 신뢰된 로컬 코드다. 그러한 호출자는 이미 `System.cmd`, 파일 API, 임의 callback, 직접 SQL 실행을 할 수 있다. `config.binary`, `config.psql`, DB 경로, PostgreSQL URL, `opts[:after_effect]`를 임의 지정하는 능력 자체는 이 호출자의 권한 상승 취약점이 아니다.

PostgreSQL journal과 Akashic executable/DB는 신뢰된 종속성이다. 낮은 권한 주체가 이들을 변경할 수 있는 파일 권한·DB grant·외부 import 경로가 있는지는 이번 소스만으로 확인할 수 없다. receipt 보존과 DB lifetime/identity의 정확성도 운영 계약이다. 미래에 외부 입력을 이 경계에 전달한다면 서버가 config/opts를 소유하고 tenant 권한·별도의 자원 한계를 검증해야 한다. 그 조건이 이미 구현돼 있다고 가정하지 않았다.

## 재현된 결함 및 보완사항

### S1 — libpq query parameter로 전용 localhost DB 검사 우회

**현재 심각도: Low(운영 보호 조건 결함), 신뢰도: 높음.** 권한 상승은 검증되지 않았다.

근거: [postgres.ex:3](../../lib/atheum/postgres.ex#L3)–21의 `URI.parse` 검사는 `uri.host`와 `uri.path` 접두만 확인하고 원래 URL 전체를 libpq/psql에 전달한다. libpq의 query parameter는 실제 연결 DB를 덮어쓴다.

최소 재현: `pg_probe.exs`가 `postgres://postgres@127.0.0.1:55440/atheum_decoy?dbname=atheum_cycle_test`로 `SELECT current_database()`를 호출했으며 응답은 `atheum_cycle_test`였다. 존재하지 않는 decoy 경로와 다른 실제 DB 이름이 적용됨을 **전용 fixture DB만으로** 확인했다. fake psql probe는 이 URL이 adapter 검사를 통과하고 argv에 그대로 전달되는 것도 확인한다.

영향·전제: 오설정된 trusted config에서도 README의 `/atheum_` 제한이 실제 목적지 제한을 보장하지 않는다. 다른 `dbname`, `host`/`hostaddr` 등의 libpq 연결 옵션을 제공할 수 있는 설정 주체와 접속 권한이 있으면 다른 목적지에 SQL을 보낼 수 있다. 외부 host/다른 기존 DB 연결은 재현하지 않았다. SQL 권한은 여전히 실제 연결 계정의 권한에 제한된다. URL을 신뢰된 로컬 코드만 지정하는 현재 모델에서 이를 외부 공격자의 임의 DB 접근으로 과장하지 않는다.

제안: scheme 및 허용 query option을 엄격히 검사하거나 연결 요소를 분리해 고정된 argv/env로 구성하고, 실제 목적지·DB 및 최소 권한 계정을 검증한다. DB 이름 접두는 독립적인 접근 통제를 대신하지 못한다.

### H1 — psql 무기한 대기·출력/이력 크기 제한 부재

**현재 분류: 가용성 보완사항. 비신뢰 호출·출력 경로가 추가되면 Medium 후보. 신뢰도: 높음.** 현재 범위에서 비신뢰 공격 주체는 입증되지 않았다.

근거: [postgres.ex:18](../../lib/atheum/postgres.ex#L18)–25의 `System.cmd`에 timeout/cancel/출력 한도가 없다. [akashic.ex:21](../../lib/atheum/akashic.ex#L21)–26은 모든 stdout/stderr를 `output <> bytes`로 누적하고 종료 후 JSON으로 해석한다. [postgres.ex:52](../../lib/atheum/postgres.ex#L52)–58의 history는 전체 events를 한 번에 `json_agg`한다. `get/history/cancel` ID 크기, 전체 journal 양, 동시 실행 수, CLI 결과 JSON 깊이·크기의 명시적 한도는 없다.

최소 재현: 설정 `timeout_ms: 10`에서 fake psql의 250ms 대기가 460ms 후 성공했다. 실제 테스트 PG의 `SELECT pg_sleep(0.25)`도 설정 timeout을 넘어서 성공했다(최종 로그의 실측값 참조). 4 MiB padding이 있는 CLI 결과도 거절 없이 전체 decode됐다. 무한 출력/OOM이나 대규모 DB는 만들지 않았다.

영향·전제: lock/느린 PG 때문에 Function deadline 전후의 `get/claim/finish` 및 취소 자체가 막힐 수 있다. CLI timeout은 전체 API 작업 시간을 제한하지 않는다. 비정상 종속성 출력·큰 그래프 결과·반복된 취소/복구 이벤트는 BEAM 메모리와 DB 저장량을 증가시킨다. depth 폭주와 timeout 중 계속 도착하는 메시지의 deadline 지연 가능성은 소스상 보완 후보이며 스트레스 재현하지 않았다. `Port.close`가 OS child 전체 종료를 보장한다고 보지 않는다.

제안: PG 연결/statement/lock timeout 및 프로세스 관찰 timeout, 출력 byte cap·JSON shape/depth cap, history pagination, 실행·journal quota를 정한다. child 종료 확인이 없으면 현재처럼 effect certainty는 unknown으로 유지한다.

### H2 — CLI 성공 결과의 shape/type 검증 부족

**현재 분류: 종속성 응답 무결성 보완사항. 비신뢰 CLI/wrapper가 경계 안에 들어오면 Low–Medium 후보. 신뢰도: 높음.** 현재 trusted executable을 장악한 주체에게 새 실행 권한을 주는 취약점은 아니다.

근거: [akashic.ex:37](../../lib/atheum/akashic.ex#L37)–42는 exit 0과 `ok: true`만으로 `result.apply` 또는 임의 `result`를 성공으로 인정한다. [core.ex:28](../../lib/atheum/core.ex#L28)–35는 `changed`의 truthiness로 certainty를 결정하고 version/request 연관성·boolean 타입을 확인하지 않는다.

최소 재현: fixture executable의 `{"ok":true,"result":{"apply":{}}}`가 `{:ok, %{}}`로 반환되고 `Core.completion`은 `succeeded/confirmed_absent`로 분류했다. `changed: "false"`는 `confirmed_present`로 분류했다. 결과가 비 map이면 caller 예외도 가능하다(소스 근거, 별도 재현 안 함). known rejection `invalid_input/version_conflict`는 CLI error code를 그대로 신뢰해 `confirmed_absent`가 된다.

영향·전제: 고장 난 wrapper/프로토콜 변경·변조된 CLI 응답이 PostgreSQL에 사실처럼 저장되거나 작업을 중단시킬 수 있다. timeout 및 invalid JSON을 unknown으로 처리하는 기존 방어와 별개로, syntactically valid지만 잘못된 결과는 검증하지 않는다. malicious executable을 고를 수 있는 trusted caller는 이미 임의 명령 실행 능력이 있으므로 이를 새로운 RCE로 보고하지 않는다.

제안: Function 전용 성공·오류 schema와 boolean/u64/version 의미를 검증하고, 불완전·비정상 shape를 transport failure/unknown으로 유지한다. journal write access 및 executable 교체 권한은 별도로 제한한다.

## 요청 경계별 검증 근거

| 경계 | 확인된 동작·근거 | 남은 조건/한계 |
| --- | --- | --- |
| CLI argv/path·명령/파일 접근 | `spawn_executable` + 4개 별도 argv(akashic.ex:7–12). 실제 CLI는 정확히 4개 argv와 storage flag/`--json`을 검사(main.rs:5–18). probe의 shell metacharacter 경로·payload는 그대로 한 argv에 전달됐다. submit은 `set_active` 1개 operation으로 고정(Atheum:29–34). | 경로·실행 파일은 trusted config 권한이며 jail/allowlist는 없다. Path.expand는 symlink/DB 교체를 탐지하지 않는다. CLI DB 파일 열기는 호출자 OS 권한으로 수행된다. |
| SQL/조작 입력 | JSON→hex→decode→jsonb의 값 변환(postgres.ex:32–35). 실제 PG에서 quote·DROP TABLE 문자열·backslash·newline·한글이 literal text로 round-trip됐다. | `Postgres.query/transition`은 raw SQL/조건/assignment를 받는 로컬 adapter API다. 외부 전달 경계로 노출하면 안 된다. DB 저장행을 적대적으로 변경하는 경우 raw generation interpolation 등도 안전한 경계로 간주할 수 없다. |
| tenant/execution 참조 | get/history/run/cancel은 invocation_id를 정확히 비교. execution_id는 UNIQUE이고 새 acceptance에 생성된다. 고유 attempt와 generation으로 관찰을 연관한다. | tenant 열/tenant별 key namespace/행별 인가는 없다. 현재 단일 trusted local scope에서는 IDOR 증거가 아니다. 다중 tenant 노출 전 ID 기반 조회·취소·접수키 모두 권한을 결합해야 한다. |
| acceptance/request ID 충돌 | acceptance_key UNIQUE, 같은 fingerprint만 기존 invocation 반환(postgres.ex:62–89). 기존 실제 PG 동시 접수·다른 input 충돌 테스트 통과. request_id는 128bit crypto random(118), submit이 만들고 recovery는 저장된 동일 Apply를 사용. | request_id 전역 UNIQUE PG 제약은 없다. 임의 UUID collision은 재현·취약점 주장 안 함. 식별자는 인증 토큰이 아니다. Akashic receipt는 DB 안에서 payload 불일치 시 request_conflict(lib.rs:109–119), Core는 unknown 후 복구 거부(core.ex:22). |
| callback 권한 | `after_effect`는 caller가 전달한 BEAM 함수이며 같은 worker 안에서 실행(Atheum:117). 기존 실제 테스트가 callback으로 완료 직전 crash/cancel을 재현했다. | callback 예외/무기한 대기는 finish를 막는다. 네트워크 입력→함수 생성 경로는 없다. trusted caller의 기존 권한이며 외부 wrapper가 callback/config를 고정해야 한다. |
| journal/결과·오류 조작 | 상태 변경·event가 한 SQL CTE에 기록되어 trigger 실패 시 둘 다 rollback. 실제 효과 후 journal 실패 테스트에서 running/unknown이 남고 exact replay로 복구됨. stale event는 이전 attempt_id와 보존됨. | journal에 암호학적 무결성/append-only DB grant가 없다. journal writer/admin은 결과·request·target·cancel을 바꿀 수 있다. 이 권한 보유자는 이미 직접 변조 가능하며 별도 escalation 경로는 입증 안 됨. H2 참고. |
| 취소 후 재시도·권한 범위 | accepted 취소와 run claim은 NOT cancel 조건으로 경합. recoverable과 claim, perform 재검사에서 cancel을 확인(Atheum:56–65,95–107). 취소 후 recover 거부·성공 효과 유지·stop 미확정의 실제 테스트 통과. | 최종 DB 확인과 OS spawn 사이에 원자적 취소 경계는 없다. running 취소는 새 송신이 완전히 막혔다는 확인/rollback 약속이 아니다. running의 stop_confirmed=false 계약을 유지한다. 역할/정책 범위는 미구현·범위 밖이며 미래 노출 전 필요하다. |
| stale worker | recover claim은 읽은 generation 조건, finish는 generation+attempt 조건(Atheum:62,128). 이전 worker의 late finish가 recovered 상태를 덮지 않고 stale_attempt_observed로 남는 실제 테스트 통과. | generation은 상태 write fence이며 OS effect fence가 아니다. 동시 Apply의 효과 안전성은 같은 target·payload와 Akashic receipt/DB serialization에 의존한다. |
| timeout/unknown·멱등 복구 | timeout/transport failure는 unresolved/unknown. safe_retry 기본 false, target/path/identity/storage·deadline·cancel 검사. 실제 committed effect 후 worker death/timeout/write failure에서 동일 result/version/execution 유지 테스트 통과. | 같은 경로의 receipt 삭제·restore·symlink 교체는 identity만으로 발견 불가. trusted 운영 계약이 깨지면 exactly-once 보장 없음. deadline은 PG 대기 전체를 제한하지 않음(H1). |
| 크기/깊이·자원 | supplier_id와 acceptance key 128byte 및 UTF-8/nonblank. input 필드 3개 고정, boolean·nonnegative integer. extra operation·과대 supplier ID 거부 probe 통과. | expected_version/deadline 정수 상한 없음(1001자리 version 허용 재현); CLI u64에 맞춘 validation 필요. 반복 이력/응답/ID/config 값·timeout upper bound·JSON depth/concurrency cap 없음. 현재 trusted caller가 이미 메모리를 할당할 수 있다는 점을 가용성 공격과 구분한다. |

## 재현 명령

Atheum 디렉터리에서 기존 설치 도구만 사용한다. probe는 `/tmp` 아래 고유 임시 executable을 생성하고 정리한다. 과대 출력은 4 MiB로 제한된다.

```sh
elixir verification/security-20261002/security_probe.exs
elixir verification/security-20261002/pg_probe.exs
ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/Users/tonton/Documents/workspace/alaya/akashic/target/debug/akashic \
elixir -r lib/atheum/core.ex -r lib/atheum/akashic.ex \
  -r lib/atheum/postgres.ex -r lib/atheum.ex \
  -e 'Code.require_file("test/test_helper.exs"); ExUnit.configure(exclude: []); Code.require_file("test/core_test.exs"); Code.require_file("test/cycle_integration_test.exs")'
```

남은 검증: Standard 도구 기반 독립 scan과 정식 finalization, 실제 배포 OS/DB 권한, receipt lifetime 운영, 결과 schema의 adversarial integration, 무한 출력·depth/동시성·deadline 경합 스트레스 검증. 공개 API/Arbiter 정책 설계의 안전성은 이 보고서로 평가할 수 없다.
