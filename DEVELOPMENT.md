# 개발 훅 운영

설치할 버전의 checkout에서 `./scripts/install-hooks`를 실행한다. Git common directory의 `codex-hooks/`에 push gate를 복사하고 절대 hooksPath를 등록하여 이전 커밋의 linked worktree에서도 검사한다. 변경 후 재설치해야 설치된 gate가 갱신된다. 기존 `.githooks` 설정은 이전하며 다른 hooksPath와 worktree별 override는 덮어쓰지 않는다. pre-commit은 해당 checkout의 기존 검사를 호출하며 누락 시 차단한다. 기존 pre-commit 검사는 유지한다. 코드 작성 후 `.githooks/post-code`를 에이전트/편집기가 호출하며 자동 staging하지 않는다. Git에는 코드 작성 완료 이벤트가 없다.

## Push 준비

1. 의도한 변경을 커밋하고 작업 디렉터리를 정리한다. `main` 직접 push는 차단하며 작업 브랜치/PR을 사용한다.
2. `./scripts/prepare-push origin BRANCH`로 계획을 생성한다. 단일 원격 URL/ref/기존 SHA/head를 기록한다. 복수 push URL 및 인증정보가 포함된 URL은 계획 저장 전에 차단한다. HTTPS 인증은 credential helper를 사용한다. 새 브랜치는 원격 main과의 공통 조상을 scan_base로 사용한다. 원격 main에 이미 도달 가능한 과거 변경은 이번 diff 검사 대상에서 제외되며, 과거 비밀 정보 검사는 별도다. 광고된 원격 커밋이 없으면 먼저 fetch한다.
3. Codex에게 출력된 정확한 base/head로 `$codex-security:security-diff-scan`을 실행하도록 요청한다. 설치된 플러그인의 전체 절차를 수행하고 완료한 sealed 결과 디렉터리를 보존한다. 준비 명령/Git hook이 자동으로 모델을 호출하는 방식은 아니다.
4. 같은 범위에 독립 리뷰를 수행한다. 아래 JSON에 실제 근거를 기록한다.
5. `./scripts/review-gate record PLAN_JSON COMPLETED_SCAN_DIR AGENT_JSON`으로 등록하고 승인된 `git push origin BRANCH`를 실행한다.

```json
{
  "kind": "agent",
  "verdict": "pass",
  "independent": true,
  "reviewed_base": "계획의 scan_base 전체 SHA",
  "reviewed_head": "계획의 head 전체 SHA",
  "reviewer": "실제 독립 리뷰어 및 모델/버전",
  "summary": "검사 범위, 검토 근거, 한계와 결과",
  "blocking_findings": []
}
```

보안 결과는 수동 pass JSON이 아니라 플러그인의 `scan-manifest.json`, `findings.json`, `coverage.json`, `report.md`를 사용한다. 설치된 `validate_scan_contract.py`로 seal/계약을 확인한다. 전체 diff 범위, 완료 coverage, 미해결 항목 없음, findings 없음만 통과한다. 현 정책은 낮은 심각도라도 confirmed finding을 차단한다. waiver는 구현하지 않았다.

플러그인은 기본 Codex 캐시에서 발견한다. 다른 경로라면 `git config --local codex.securityPluginDir /absolute/plugin/path`로 지정한다. 미설치/검증 실패는 차단하며 설치를 자동 수행하지 않는다. 플러그인 validator는 신뢰하는 로컬 설치 코드다.

Git common directory의 `push-reviews/`에 계획/등록 결과를 저장한다. push 시 같은 원격/ref/base/head와 증거 해시 및 canonical 결과를 재검증한다. 증거 디렉터리와 agent JSON을 보존해야 한다. 다른 작업 디렉터리에서도 같은 Git 저장소는 증거를 공유한다. 등록된 결과가 바뀌면 다시 검사한다. 새 브랜치의 remote main은 등록과 push 때 실제 목적지에서 다시 확인한다. 기준 또는 목적지 브랜치가 바뀌면 새 계획과 검사가 필요하다.

**보장 범위:** canonical seal은 내용 일관성 검사이며 모델 실행을 암호학적으로 증명하지 않는다. 독립 리뷰 JSON도 리뷰어의 attestation이다. 로컬 훅은 우회 가능하며 신뢰할 수 있는 CI/서버 정책을 대신하지 않는다. 코드/질문을 외부 모델에 보내기 전 데이터 전달 범위와 승인을 확인한다. 검사 완료가 전체 보안 보장은 아니다.

## PR

문제·변경 결과, 계약/책임 변경, 검사 및 리뷰 대상 SHA와 결과, 미실행 이유, 위험·복구 방법을 적는다. 기본 squash merge이며 commit/push/merge는 각각 명시적 승인을 받는다. 하위 커밋을 먼저 원격에 올리고 acropolis에서 이전/이후 SHA, 관련 PR과 조합 검증을 기록한다.

## Producer 호환성

Desktop codex-security 결과의 `target.remote`는 선택 필드다. 없으면 full base/head Git object SHA로 검사 코드를 식별하고, 별도 receipt가 실제 push URL/ref를 결합한다. remote가 제공되면 SSH/HTTPS 표기를 정규화해 저장소 위치도 비교한다. 다른 저장소라도 동일한 base/head 객체는 같은 검사 코드이며, seal 자체는 실행자 신원을 인증하지 않는다.

## Push gate 회귀 검사

`./scripts/test-push-boundary`는 플러그인 없이 임시 로컬 Git 저장소에서 계획·기준·URL·linked worktree 설치 경계를 검사하며 pre-commit에 연결된다. `./scripts/test-push-gate`는 설치된 Codex Security validator와 synthetic sealed fixture로 receipt/evidence 및 Git pre-push 프로토콜을 검사한다. 이는 제품 보안 리뷰가 아니며 실제 원격에는 push하지 않는다.

## 추가 push 경계

상대 로컬 push URL은 worktree마다 다른 목적지가 될 수 있어 거부한다. 절대 경로나 절대 `file://` URL을 사용한다. push 직전에도 현재 remote의 모든 push URL을 다시 열거하여 복수 목적지를 차단한다. Git replacement refs, custom replacement namespace 및 legacy grafts가 있으면 prepare/record/push 모두 거부한다. 검사와 전송이 같은 Git 객체를 다루도록 먼저 해당 설정을 제거하고 새 계획과 리뷰를 만든다.

변경된 기존 gitlink마다 하위 저장소의 정확한 이전/이후 SHA에 대한 sealed 검사와 독립 리뷰 receipt가 필요하다. 하위 커밋을 먼저 push하고 다음 JSON을 `record`의 마지막 선택 인자로 전달한다:

```json
{
  "akashic": {
    "repository": "/absolute/child-repository",
    "receipt_path": "/absolute/child-git-common-dir/push-reviews/identity.json"
  }
}
```

실제 변경된 경로만 넣는다. 상위 receipt는 하위 receipt의 해시를 보존하고 등록/push 때 하위 sealed 결과·agent 해시·범위 및 원격 ref에서 새 커밋의 도달 가능성을 재검사한다. 하위 receipt와 검사 파일을 보존한다. gitlink 삭제는 새 코드가 없으므로 하위 검사를 요구하지 않는다. 최초 gitlink 추가/일반 파일에서 gitlink 전환은 초기 보안 기준이 정의되지 않아 현재 gate가 차단한다. 하위 리뷰 없이 상위 coverage만으로 통과하지 않는다.

테스트와 설정 검사에서 Python 최적화 모드를 사용하지 않는다. `PYTHONOPTIMIZE`/`python -O`로 assertion이 제거되는 실행은 fixture 생성 전 비영 종료한다.

## PR 피드백 완료 확인

push 성공은 PR 피드백 처리 완료가 아니다. 최신 head에서 봇 재리뷰 완료를 확인하고, 새 지적을 원문별로 검증한다. 타당한 지적은 수정·검사·새 push 범위 리뷰를 거쳐 올린다. 검증한 수정에는 근거 답글을 남긴 뒤 resolve한다. outdated 표시나 시간 경과만으로 resolve하지 않는다. 판단이 갈리거나 같은 지적이 반복되면 원문·재현·반증을 BOSS에게 제시한다.

`./scripts/pr-review-status OWNER/REPO PR_NUMBER`는 최신 head와 Codex 봇 summary의 Code Review 완료, 모든 미해결 스레드, 현재 머지 상태를 읽는다. 최신 head의 봇 완료 기록이 없거나 진행 중이면 대기 상태다. 모두 충족한 관측에만 exit 0, 미완료는 3, API/파싱 오류는 비영 종료한다. 봇 summary 형식이 바뀌거나 요약이 없으면 완료를 추정하지 않는다. 이 도구는 반복 감시·답글·resolve·merge를 실행하지 않는다. 관측 후 새 push/리뷰가 생길 수 있으므로 머지 직전 다시 실행한다.

## Endpoint 리뷰의 이력 제한과 설치 보완

현재 canonical diff 리뷰는 endpoint tree 비교이므로 새 커밋 1개인 선형 update만 prepare/record/push에서 허용한다. `scan_base`가 head의 유일한 부모여야 한다. 내용이 추가됐다 삭제되는 중간 커밋과 merge history를 endpoint 리뷰만으로 승인하지 않는다. 여러 미전송 커밋은 공유 이력을 바꾸지 말고 커밋별로 계획·검사·push하거나 별도의 전체 이력 검증 지원을 먼저 마련한다.

설치기는 worktreeConfig boolean을 Git의 `--type=bool`로 읽고 기존 worktree override를 검사한다. 완성된 임시 실행파일에 실행 권한을 준 뒤 같은 디렉터리에서 rename하여 기존 파일을 빈 파일/부분 코드로 노출하지 않는다. 설치된 세 실행파일의 교체는 각각 원자적이며 전체 세 파일의 단일 트랜잭션은 아니다.

하위 변경 탐지는 `--ignore-submodules=none`으로 로컬 ignore 설정을 덮어쓴다. committed head의 `.gitmodules` path/URL과 하위 receipt 목적지를 비교하고 그 소비자 URL에서 커밋 도달 가능성을 확인한다. URL은 절대 로컬 경로, 절대 file URL 또는 기존 네트워크 URL을 사용한다. 상대 submodule URL은 resolution 계약이 정의되지 않아 차단한다. SHA와 소비자 URL이 같은 정확한 gitlink 이동은 기존 baseline을 보존하여 하위 코드 재리뷰를 요구하지 않는다. 모호한 이동/최초 추가와 SHA 변경 없는 소비자 URL 교체는 별도 증거 계약이 없어 차단한다.

하위 evidence는 기존 `receipt_path` 1개 또는 순서가 있는 `receipt_paths` 배열을 받는다. 배열의 각 receipt는 직전 head를 다음 scan_base로 사용해야 하며 첫 base/마지막 head가 상위 gitlink 변경과 일치해야 한다. 모든 단계를 별도로 재검증하고 receipt 해시를 상위 등록 결과에 보존한다. 원격 ref tip이 로컬에 없으면 검증 shell이 `fetch --no-tags --no-write-fetch-head URL SHA`로 객체만 가져오며 작업 브랜치와 FETCH_HEAD는 갱신하지 않는다. PR 상태 도구는 pagination 이후 metadata를 다시 읽고 같은 head인지 확인한 뒤 최종 머지 상태로 판단한다.

목적지 비교는 커스텀 포트와 일반 SSH 서버의 상대/절대 경로를 보존한다. HTTPS/SSH 별칭은 GitHub의 동일 저장소 namespace에 한해 정규화하고, 로컬 경로/file URL은 실제 절대 경로로 비교한다. SHA가 같은 기존 gitlink도 base/head 전체 목록에서 committed `.gitmodules` URL을 비교하여 URL만 변경한 커밋이 하위 도달 가능성 검증을 건너뛰지 못하게 한다.

빈 worktree hooksPath도 명시적 override이므로 설치를 차단한다. URL의 query/fragment는 전송 의미의 동등성을 보장할 수 없어 거부하고, 일반 네트워크 URL의 escaped path는 그대로 비교한다.

하위 URL은 file/HTTP(S)/SSH/Git 전송과 절대 로컬 경로만 지원하며 `<helper>::<address>` 및 임의 scheme은 Git 호출 전에 차단한다. 설치 대상 실행파일 경로가 디렉터리이면 기존 상태를 보존하고 차단한다. PR 완료 관찰은 thread pagination 뒤 최신 봇 요약과 metadata를 읽으며, 최종 reviewDecision/각 리뷰어의 latestReviews에 Changes requested가 남으면 mergeable 표시와 무관하게 차단한다.

등록된 worktree를 검사할 수 없거나 설정 조회가 오류이면 설치를 차단한다. `reported` coverage도 push를 차단한다. 하위 원격 도달 가능성은 receipt 목적지 ref를 먼저 검사하고 tip을 순차적으로 검증하며, 첫 증명 이후 관련 없는 ref를 fetch하지 않는다. 특정 tip fetch 실패만으로 종료하지 않으며 어느 ref에서도 증명하지 못하면 차단한다.

worktree 목록은 `--porcelain -z`와 NUL-safe reader로 읽어 줄바꿈이 있는 경로도 검사한다. 새 브랜치 준비 시 advertised main 객체가 없으면 local ref/FETCH_HEAD를 갱신하지 않고 해당 SHA만 fetch한 뒤 baseline을 검증한다. pre-commit 경계 테스트는 모듈 로드 전 bytecode 쓰기를 끈다.

`-`로 시작하는 repository URL은 Git 옵션으로 해석되지 않도록 모든 목적지 검증에서 거부하며, ls-remote/fetch에도 옵션 종료자 `--`를 사용한다.

추가 경계: 훅 설치는 등록된 checkout의 실제 common Git 디렉터리를 비교하고, hooksPath가 없을 때 활성 기본 훅을 보존하기 위해 설치를 거부한다. 로컬 push URL은 심볼릭 링크 경유를 거부하며 canonical 경로를 사용해야 한다. PR 상태 조회는 마지막 API 조회 뒤 스레드를 다시 페이지 조회하지만 원자적 스냅샷은 아니며 실제 merge 시점의 GitHub 보호 규칙이 최종 gate다.

조건부 include를 포함한 모든 checkout의 hooksPath 출처를 검사한다. 선언된 저장소와 다른 위치로 확장하는 URL rewrite는 거부한다. 봇 요약의 짧은 커밋 ID는 GitHub commit API의 전체 SHA로 확인하며 모호하거나 조회할 수 없는 ID는 완료로 인정하지 않는다.

공유 codex-hooks 디렉터리 자체의 심볼릭 링크도 설치 전에 거부한다. 기존·끊어진 링크 모두 대상 파일이나 hooksPath를 수정하지 않는다.

커밋된 .gitmodules 경로는 NUL record와 첫 newline 구분자로 읽어 경로 안의 줄바꿈을 보존한다. 준비·실제 훅은 remote.<name>.receivepack 설정(명령행 -c 주입 포함)을 거부한다. 지원하는 전달 명령은 일반 git push origin BRANCH이며 --receive-pack/--exec는 금지한다. Git은 그 명령행 옵션을 pre-push 인자로 전달하지 않으므로 훅만으로 이를 강제할 수 없다. --no-verify와 같은 소유자 우회는 신뢰 경계 밖이며 서버 보호 규칙을 대신하지 않는다.
