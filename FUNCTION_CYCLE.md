# Function 실행 완료 계약 v1

사용자는 공개 Atheum API로 Function을 접수하고 실행 결과와 이력을 조회한다.
이 계약은 그 제품 경로의 완료를 기계적으로 판정한다. 공급사 지식은 기존 고정
Function의 합성 테스트 데이터이며, 공급망 업무 앱을 제품 목표로 삼지 않는다.
범용 Function 등록, 온톨로지 정의 자동 로딩, HTTP/UI, 인가, 배포는 이번 범위 밖이다.

## 실행

기존 Elixir/mix, psql, 설치된 프로젝트 의존성, Akashic binary와 별도의 localhost
`atheum_` 테스트 DB가 필요하다. 검증기는 설치나 컨테이너 생성, 다른 프로젝트 빌드를 하지 않는다.
DB 연결 허용 범위는 기존 Atheum.Postgres 계약을 따른다.

```sh
ATHEUM_TEST_PG_URL=postgres://postgres@127.0.0.1:55440/atheum_cycle_test \
AKASHIC_BINARY=/absolute/akashic/target/debug/akashic \
./scripts/verify-function-cycle
```

종료 코드 0은 모든 필수 조건 통과, 1은 실패, 4는 필수 실행 설정/도구 누락이다.
`artifacts/<run>-function-cycle/report.json`의 `complete=true`가 이 계약의 완료 판정이다.
실행 로그와 조건별 ExUnit 관찰은 같은 디렉터리에 보존한다. 실패 로그에는 입력이나
로컬 경로가 포함될 수 있으므로 artifacts를 자동 외부 업로드하지 않는다.

## 필수 조건

버전과 조건 목록은 [계약 파일](scripts/function-cycle-contract.json)에 고정한다.

| 조건 | 검사 |
| --- | --- |
| execution_and_restart | 접수 ID, 성공 결과, 실제 저장 효과, 별도 BEAM VM의 결과·이력 재조회 |
| duplicate_acceptance | 동시 중복 접수의 단일 invocation, 중복 run 거절, 성공 후 재접수의 원래 결과, 충돌 입력 거절 |
| invalid_input | 입력 타입·필드·버전 위반 거절, 접수 행 미생성, 실제 그래프 무변경 |
| unknown_result | 실제 효과 커밋 후 응답 유실에서 unresolved/unknown 유지, 허용된 복구의 동일 버전 |
| interrupted_execution | 효과 후 worker 강제 종료, 호출 의도·unknown 보존, 동일 receipt의 명시적 복구 |

각 조건에 정확히 한 번 실행된 PASS 관찰이 있어야 하며 실행 프로세스도 정상 종료해야 한다.
누락, 중복, skip, 실패, 알 수 없는 조건, 빈 계약은 완료가 아니다. 코드·계약·binary
해시와 HEAD/작업 트리 상태를 기록하고, 실행 중 검사 대상 파일/binary가 바뀌면 실패한다.
HEAD만으로 uncommitted 작업을 식별하지 않는다. 해시는 실행자 신원이나 악의적인
검증기 변경을 증명하지 않으며, 실행 중 변경했다가 되돌리는 경우까지 감지하지 않는다.

검사는 실제 PostgreSQL과 새 임시 RocksDB를 사용한다. 본인 invocation/event와
임시 파일만 정리한다. 기대 효과는 작은 고정 정답 및 별도 저장 조회와 비교하며 앱의
완료 status만 믿지 않는다. 검증기 판정의 반례 검사는 `./scripts/test-function-cycle-verdict`다.
이 검사는 precommit에도 포함된다. 기존 전체 `./scripts/check review`는 별도로 유지한다.

## 판정 경계

통과는 고정 Function 하나의 로컬 실행 계약에 대한 증거다. 범용 온톨로지 Function
시스템, 임의 외부 효과의 exactly-once, 운영 내구성, 다중 host, 권한 검증의 완료가 아니다.
복구 안전성은 동일 Akashic DB와 receipt 보존, safe_retry/deadline/취소 계약에 한정된다.
조건을 바꾸면 계약 버전을 올리고 변경 이유를 검토한다. 앱에 맞추기 위해 실패 조건을 제거하지 않는다.
