# 개발 훅 운영

각 checkout에서 `./scripts/install-hooks`를 실행한다. 기존 hooksPath가 다르면 덮어쓰지 않는다. 기존 pre-commit 검사는 유지한다. 코드 작성 후 `.githooks/post-code`를 에이전트/편집기가 호출하며 자동 staging하지 않는다. Git에는 코드 작성 완료 이벤트가 없다.

## Push 준비

1. 의도한 변경을 커밋하고 작업 디렉터리를 정리한다. `main` 직접 push는 차단하며 작업 브랜치/PR을 사용한다.
2. `./scripts/prepare-push origin BRANCH`로 계획을 생성한다. 원격 URL/ref/기존 SHA/head를 기록한다. 새 브랜치는 원격 main과의 공통 조상을 scan_base로 사용한다. 원격 main에 이미 도달 가능한 과거 변경은 이번 diff 검사 대상에서 제외되며, 과거 비밀 정보 검사는 별도다. 광고된 원격 커밋이 없으면 먼저 fetch한다.
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

Git common directory의 `push-reviews/`에 계획/등록 결과를 저장한다. push 시 같은 원격/ref/base/head와 증거 해시 및 canonical 결과를 재검증한다. 증거 디렉터리와 agent JSON을 보존해야 한다. 다른 작업 디렉터리에서도 같은 Git 저장소는 증거를 공유한다. 등록된 결과가 바뀌면 다시 검사한다.

**보장 범위:** canonical seal은 내용 일관성 검사이며 모델 실행을 암호학적으로 증명하지 않는다. 독립 리뷰 JSON도 리뷰어의 attestation이다. 로컬 훅은 우회 가능하며 신뢰할 수 있는 CI/서버 정책을 대신하지 않는다. 코드/질문을 외부 모델에 보내기 전 데이터 전달 범위와 승인을 확인한다. 검사 완료가 전체 보안 보장은 아니다.

## PR

문제·변경 결과, 계약/책임 변경, 검사 및 리뷰 대상 SHA와 결과, 미실행 이유, 위험·복구 방법을 적는다. 기본 squash merge이며 commit/push/merge는 각각 명시적 승인을 받는다. 하위 커밋을 먼저 원격에 올리고 acropolis에서 이전/이후 SHA, 관련 PR과 조합 검증을 기록한다.

## Producer 호환성

Desktop codex-security 결과의 `target.remote`는 선택 필드다. 없으면 full base/head Git object SHA로 검사 코드를 식별하고, 별도 receipt가 실제 push URL/ref를 결합한다. remote가 제공되면 SSH/HTTPS 표기를 정규화해 저장소 위치도 비교한다. 다른 저장소라도 동일한 base/head 객체는 같은 검사 코드이며, seal 자체는 실행자 신원을 인증하지 않는다.
