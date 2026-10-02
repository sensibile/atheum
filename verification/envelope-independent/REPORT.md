# 독립 최종 envelope 회귀 검증

결과: 검증 범위에서 재현 가능한 생산 코드 결함을 발견하지 않았다. 원본 생산 코드, 기존 테스트/증거 및 실제 Git index는 변경하지 않았다. `preservation.json`과 before/after SHA-256 목록이 이를 확인한다. 실제 index가 존재하는 경우 목록에 포함하며, 현재 Git main은 commit 없는 상태이므로 과거 revision과의 비교는 불가능하다.

## 실행 범위와 결과

- 조상 디렉터리 및 현재 디렉터리의 AGENTS.md를 확인했으나 없었다. 형제 프로젝트의 지침은 본 프로젝트에 적용되지 않으며 수정하지 않았다.
- final source를 임시 디렉터리로 복사해 실행했다. priv/schema.sql, deps, cache를 복사했다. 기존 integration 테스트의 고정 `current_database()` 기대 문자열만 격리 복사본에서 이번 새 DB명으로 바꿨다. 다른 기존 assertion은 유지했다.
- 기존 localhost PG 서버(55440)에 새 `atheum_envelope_78e0f224b6` DB를 생성했다. 기존 DB는 사용하지 않았다. 실행 종료 후 DROP DATABASE 성공. Akashic DB는 매 테스트마다 임시 경로에 생성·제거했다. binary는 기존 파일을 사용했으며 before/after SHA-256 동일.
- scripts/check precommit: exit 0. format, 강제 compile/warnings-as-errors, Credo strict, Dialyzer, 테스트 실행. 15 passed / 15 integration excluded.
- scripts/check review: exit 0. 동일 품질 검사 및 실제 integration 포함 30 passed.
- 독립 test 파일 단독 실행: exit 0, 2 passed. scripts/check-hook: exit 0, fixture index 불변성 검사 통과.
- isolated purpose mutation: 성공 envelope exit 0을 2로 변경했을 때 독립 검사가 실패했다. mutation-exit.raw 및 mutation.json 참고. mutation은 복사본에만 적용하고 원래 내용으로 복원했다.

## 독립 매트릭스와 실제 효과

38개 map/exit 조합: 정상 success/failure 각각 exit -1/0/1/2/127, 최상위 필수 키 삭제, apply의 changed/difference/version/work 각각 null/string/negative/list/map/boolean 타입 변형. 정상 성공 exit 0 및 정상 실패 exit 2가 수용되었고 나머지는 transport_failure → unresolved/unknown. 별도로 중복 detail, escape로 동일해지는 중복 ok, 뒤따르는 두 번째 JSON 값을 거부했다. MATRIX 레코드에 각각 입력·exit·판정이 있다.

실제 CLI가 set_active 변경을 먼저 commit한 다음 6개 변형을 적용했다: success exit 2, duplicate ok, null error, false+result+error, error.detail 누락, apply.work 누락. 각 요청은 실제 supplier active를 번갈아 변경하여 changed=true를 확인했다. 모두 unresolved/unknown, stop_confirmed=false로 남았고 confirmed_absent가 되지 않았다. 같은 request ID 및 전체 request payload로 recover 성공; execution_id 유지, receipt 정확 일치, validate version이 expected+1이었다. receipt 추가 호출 후에도 version이 그대로였다. 각 이력은 accepted → call_intent → unknown attempt_observed → call_intent → successful attempt_observed의 5개 항목으로 정합했다. REAL 레코드에 unknown/recovered/receipt 및 전체 PG history 원시 결과가 있다.

기존 실제 integration은 worker death, timeout, malformed success, 대칭 모순, 정상 성공, 정상 version_conflict 실패, cancel before/after effect, retry opt-in/target, stale worker result, journal write failure, paging/PG bounded I/O를 그대로 통과했다. deadline 경계는 기존 Core pure test로 검증했다. 과도한 입력 거부 여부는 기존 boundary/core와 실제 정상 성공·정상 실패·impact·validate 통과로 확인했다.

## 보존·한계·재현

commands.json에 실제 argv/cwd/exit, *.raw에 stdout+stderr 원시 결과가 있다. run.py와 independent_test.exs로 재실행 가능하다. mutate.py는 preservation.json의 격리 복사본에서만 수행한다. attempt-1/attempt-2에는 검증 harness 실패도 보존했다: 초기 schema 복사 누락/포맷 및 새 테스트 Credo 스타일 지적을 보완한 뒤 최종 실행을 통과했다. 초기 sandbox localhost 연결 거부는 escalation 후 허용되어 해소됐다.

기존 재현의 주요 assertion(unknown 보존, 동일 request 복구, 모순 응답의 양방향 검사)은 소스에서 유지됨을 확인했고 기존 파일 해시가 불변이다. commit 없는 저장소이므로 이전 구현과의 historical 약화 여부를 완전히 입증하지 못한다. 실제 independent wrapper의 변조 stdout 별도 파일은 보존하지 않았으나 변형 생성 코드와 PG 원시 관찰 결과를 남겼고 기존 review의 ENVELOPE_VARIANT 레코드는 wire를 포함한다. 새로운 cancellation/deadline 동시성 전체 탐색, records storage, 악의적인 CLI가 완전한 유효 실패만 위조하는 경우, 전면 보안/운영 보증은 검증 범위가 아니다. 결과는 이 binary/source 및 한정된 실행에 대한 증거이며 exactly-once 보증이 아니다.
