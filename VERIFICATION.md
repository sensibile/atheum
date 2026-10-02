# 첫 실행 사이클 자체 검증 기록

이 문서는 최초 사이클의 역사적 기록이다. 이후 안전 경계와 정적 분석 보완의 최신 결과는 [hardening 보고서](verification/hardening-20261002/REPORT.md)를 따른다.

2026-10-02. 구현과 자체 검증을 마쳤으며 이후 독립 검증 전까지 코드를 멈춘다. 독립 검증 완료를 주장하지 않는다.

## 실행 환경과 최종 결과

- Elixir 1.20.4 / Erlang OTP 29, psql 18.6, 실제 PostgreSQL 서버 17.10.
- 전용 컨테이너 `atheum-cycle-test-pg-20261002`, localhost:55440, DB `atheum_cycle_test`. 이 자원은 후속 독립 검증용으로 남겨 두었다. Axiom DB는 사용하거나 변경하지 않았다.
- 기존 Akashic binary SHA-256: `eeacb10fefdbf76bd086c7288aa9eab0a202aca57e5f1d27d1a754b93f446230`. Akashic 생산 코드/빌드/설정 변경 없음.
- 최종 review: format 확인 PASS, compiler 정적 검사 PASS, 빠른 테스트 4 PASS/통합 10 제외, 전체 14 PASS(그중 실제 I/O 10).
- 로그와 단계별 명령/종료코드: [최종 report](artifacts/20261002T004321145130Z-review/report.json), 해당 디렉터리의 0~3.log. raw artifacts는 Git ignore한다.
- `python3 scripts/check-hook`: 격리 Git fixture의 hook 호출, 성공 허용, 검사 실패 거절, staged 파일의 unstaged 수정 거절 PASS. stub check는 hook 전달만 검증하며 실제 compiler/test 성공은 위 review가 별도로 증명한다.
- Git은 Atheum에서만 init 및 로컬 core.hooksPath 설정. 원격/identity/전역 설정/commit/push 없음. ignore는 _build/artifacts/.env/data 경로에서 실제 확인했다.

## 목적별 증거

| 목적 | 실행한 근거 |
| --- | --- |
| 실제 Function | 새 RocksDB fixture의 S1=true를 false로 바꾼 뒤 full impact가 수동 정답 P→B 차단과 일치 |
| 기록 영속성 | 실제 PostgreSQL 상태/journal 조회, 독립 SQL의 succeeded/version=2/event count=3 대조, 새 BEAM VM에서 같은 결과 회수 |
| 접수 중복 | 실제 PostgreSQL에 동시 4개 접수, invocation 하나와 accepted 사건 하나. 다른 입력은 충돌 |
| receipt/효과 중복 | 프로세스 재기동 후 동일 요청의 최초 ApplyResult 회수. 다른 요청으로 현재 버전을 3으로 진전시킨 뒤 replay는 최초 version=2를 반환하며 raw CLI write_work.logical_writes=0. 실제 현재 version=3 impact도 유지 |
| 핵심 장애 | Akashic 성공 응답을 받은 barrier에서 worker 강제 종료. running/unknown이 남고 새 attempt에서 동일 request ID/payload로 최초 결과 회수 |
| 두 DB 경계 | 실제 PostgreSQL trigger로 결과 사건 쓰기를 실패시킴. RocksDB 효과는 남고 PostgreSQL 상태는 원자적으로 running/unknown 유지. trigger 제거 후 복구 |
| 실행 전 취소 | 원자적으로 stopped/not_started, attempt 없음, run 거절, graph는 원래 version=1 유지 |
| 이미 발생한 효과와 취소 | 실제 효과 뒤 journal 전 취소 요청. 정지 미확인 상태를 거쳐 성공을 보존하며 효과 원복 없음 |
| timeout | 실제 CLI 커밋 후 응답을 stdin EOF barrier로 지연하는 wrapper 사용. timeout은 unresolved/unknown/stop_confirmed=false, 동일 요청 복구 결과는 version=2 |
| 복구 제약 | safe_retry=false, target identity 변경, 취소 후 실제 재전달 거절. deadline 만료 조건은 빠른 순수 테스트로 검증 |
| stale worker | 원래 worker의 효과 뒤 대기, 복구 완료 후 늦은 응답 도착. 최신 상태 덮어쓰기 거절 및 stale_attempt_observed 이력 보존 |
| 버전 충돌 | 실제 CLI version_conflict가 failed/confirmed_absent로 기록되고 graph 변경 없음 |

## 독립 검증자가 확인할 불변식

1. 접수 성공 이전에 key/invocation/execution/accepted 사건이 함께 커밋되고 동일 키의 다른 의미는 충돌한다.
2. 외부 호출 전 request ID·정확한 payload·대상·attempt 의도가 영속 저장된다.
3. PostgreSQL 결과 쓰기 실패가 Akashic 효과를 되돌리거나 두 DB의 원자성을 주장하지 않는다.
4. 복구는 invocation/execution/request ID/payload/expected version을 유지하고 attempt만 바꾼다. 새 버전으로 자동 rebase하지 않는다.
5. safe_retry 기본 false. deadline 만료·취소·target 변경·request_conflict에서는 apply 재전달이 금지된다.
6. cancel_requested는 stop_confirmed가 아니다. timeout은 confirmed_absent가 아니다. Port.close는 외부효과 원복이나 child 종료 증명이 아니다.
7. 늦은 관찰은 원래 attempt 이력에 남고 generation으로 최신 상태를 보호한다.
8. Akashic receipt 범위를 벗어난 임의 효과 exactly-once를 주장하지 않는다.

## 재현과 남은 한계

재현 명령은 [README](README.md)의 review와 check-hook이다. 검증 중 반복 실행은 wire envelope 수정, stale 증거 보존, fresh VM 영속성 검증 등 실제 변경 후 회귀로 수행했다. 최초 actual CLI 확인에서 result.apply envelope를 발견해 Atheum adapter만 수정했다.

- Akashic의 순수 request ID receipt 조회가 없다. 취소·만료 후 재전달은 새 효과를 만들 수 있어 금지하며 unknown이 남을 수 있다.
- target identity는 운영자가 관리하는 DB 생애 표식이다. 동일 경로에서 receipt를 삭제/복원하는 것을 자동 탐지하지 못한다. safe retry는 같은 DB의 receipt 보존이 유지되는 명시적 로컬 실험 계약에 의존한다.
- subprocess timeout 후 완전한 child 정리/정지 확인, OS crash·전원 손실·장기 경쟁 조건, production 인가·driver pooling·journal 보존 정책은 미검증/미구현이다.
- 계획의 풍부한 effects[]/retry_eligibility API는 후속 후보다. 현재 단일 Function은 단일 effect_certainty와 원래 request/result/error를 공개한다. unknown을 확정 성공으로 표시하지 않는다.
- full impact를 수동 정답과 대조했다. Akashic 내부 인덱스 구현이나 full/incremental 전 범위 회귀를 별도로 재검증했다고 주장하지 않는다.
