# atheum 개발 지침

## 공통 개발·Git 정책

- 사용자는 항상 BOSS로 부른다. 변경 전 전용 브랜치와 worktree를 만들고 기존 변경을 보존한다.
- FC/IS: I/O, 환경, 시계, 난수, ID와 상태 변경은 shell에 격리한다. core는 명시적 입력을 받아 불변 데이터와 변경 의도를 반환한다.
- Mock 라이브러리는 기본적으로 사용하지 않는다. 과도한 mocking이 필요하면 책임과 경계를 재검토한다. 실제 I/O는 격리 통합 테스트로 확인하며 fake는 실제 구현과 공통 계약 테스트를 적용한다.
- 구조 변경 디텍터는 연구 중이며 현재 필수 gate에 포함하지 않는다.
- 코드 작성 후 `.githooks/post-code`를 실행한다. 이는 Git 표준 이벤트가 아니라 에이전트/편집기가 호출하는 명시적 훅이다. 자동 stage하지 않는다. 포맷 후 diff를 확인한다.
- pre-commit은 포맷 검증, 정적 분석, 빠른 core/경계 테스트를 실행한다. 파일/index를 수정하지 않는다. 기존 프로젝트 검사를 유지한다.
- pre-push는 PR 대상 브랜치의 merge-base부터 최종 head까지 전체 누적 범위와 push 원격/ref에 대한 보안·독립 에이전트 리뷰 결과를 확인한다. 도구 오류, 미실행, blocking finding은 통과가 아니다.
- 외부 모델로 소스를 전달하려면 먼저 데이터 전달 범위를 설명하고 BOSS의 승인을 받는다. 리뷰는 코드를 수정하거나 commit/push하지 않는다.
- 한 커밋은 한 의도다. 무관한 포맷/리팩터링을 섞지 않는다. 제목은 `feat|fix|refactor|test|docs|chore: 변경 요약`이다. 필요하면 본문에 이유·제약·호환성을 적는다.
- main 변경은 작업 브랜치와 PR을 거친다. Draft PR을 허용한다. 기본 squash merge이며 단계 이력이 중요할 때만 일반 merge를 선택한다.
- PR은 문제와 변경 결과, 주요 계약/책임 변경, 검사 및 리뷰 대상 커밋과 결과, 미실행 이유, 위험과 복구 방법을 설명한다. 리뷰 후 변경은 영향 범위를 재검사한다.
- submodule PR은 소비자 계약 영향을 설명한다. acropolis PR은 이전/이후 커밋, 관련 PR, 조합 검증을 기록한다. 하위 커밋의 원격 존재를 확인한 뒤 상위 포인터를 push한다.
- 에이전트의 commit, push, merge는 각각 BOSS의 명시적 승인에 따른다. 공유 이력을 임의로 변경하지 않는다.
- 설치 및 리뷰 증거 형식은 `DEVELOPMENT.md`를 따른다. 로컬 훅은 GitHub 서버 검사를 대신하지 않으며 우회 가능하다.

## Codex push 준비 절차

- push 요청을 받으면 먼저 `./scripts/prepare-push origin BRANCH [TARGET_BRANCH]`로 불변 계획을 만든다. 준비 명령은 검사나 push를 실행하지 않는다.
- TARGET_BRANCH는 실제 PR 대상이며 기본 main이다. 기존 원격 브랜치가 있어도 직전 push 이후 변경분으로 축소하지 않는다. 계획의 정확한 scan_base/head에 `$codex-security:security-diff-scan`을 적용한다. 설치된 스킬의 preflight, 위협 모델, 발견·검증, coverage 및 완료 절차를 따르고 sealed canonical 결과를 보존한다.
- 같은 범위를 구현 대화 없이 독립 에이전트에게 리뷰하도록 한다. 에이전트 실행은 이 절차에서 명시적으로 허용한다. 코드·요구사항·검증 근거만 전달하고 수정·commit·push 권한은 주지 않는다.
- 외부 모델 데이터 전달 승인이 없으면 검사 실행 전에 범위를 설명하고 승인받는다. 계획 생성과 로컬 검증은 계속 진행할 수 있다.
- `review-gate record PLAN_JSON COMPLETED_SCAN_DIR AGENT_JSON`으로 완료 결과를 등록한다. Git pre-push가 canonical seal과 범위·내용 변경을 다시 검증한다. 수동 security pass는 허용하지 않는다.
- 검사 누락/범위 축소/미해결 coverage/취약점이 있으면 차단한다. 발견 사항을 자동 무시하지 않는다. 검사 이후 커밋이 바뀌면 새 계획과 새 검사를 수행한다.
- submodule 커밋의 보안은 상위 포인터 검사만으로 보증되지 않는다. 각 하위 저장소를 별도로 검사하고 push한다.
