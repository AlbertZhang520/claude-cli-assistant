# Claude CLI Assistant

언어: [English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | 한국어

Claude CLI Assistant는 로컬 Claude Code CLI를 자문 협업자로 호출하기 위한 credential-neutral Codex Skill입니다. 이 저장소의 산출물은 Codex Skill이며, `claude`는 이 Skill이 호출하는 외부 CLI입니다.

이 저장소에는 API key, 비공개 엔드포인트, Bearer token, 로컬 shell alias, 머신별 경로가 포함되어 있지 않습니다. Claude 인증과 Provider routing은 사용자의 로컬 환경에 두어야 합니다.

## 사용 사례

- **Codex-Claude 교차 개발**: Codex가 로컬에서 구현한 뒤 Claude CLI에 계획, diff, 누락된 테스트, 위험한 가정을 검토하게 할 수 있습니다.
- **다중 에이전트 코드 리뷰**: 한 assistant는 주요 구현을 담당하고, Claude는 독립 reviewer로 사용해 변경을 수락하기 전에 두 번째 의견을 얻습니다.
- **디버깅 지원**: 실패한 명령 출력, 로그, 축소된 재현 설명을 Claude에 전달해 근본 원인 가설을 얻고, 각 주장을 로컬에서 검증합니다.
- **아키텍처 및 영향 범위 검토**: cross-module contract, public API, migration, data integrity risk, production impact를 점검합니다.
- **테스트 계획**: 변경 범위가 정해진 뒤 high-signal test case와 edge condition을 요청합니다.
- **장시간 협업**: Claude를 로컬 async supervisor 아래에서 실행해 외부 agent가 대기를 멈춰도 Claude task가 종료되지 않게 합니다.

## 설치

이 저장소를 Codex skills 디렉터리에 clone 합니다:

```bash
mkdir -p ~/.codex/skills
git clone https://github.com/AlbertZhang520/claude-cli-assistant.git ~/.codex/skills/claude-cli-assistant
```

Claude Code CLI는 별도로 설치하고 인증한 뒤 사용 가능 여부를 확인합니다:

```bash
claude --version
claude auth status
```

## 설정

wrapper는 호출자의 현재 shell 환경을 상속합니다. 로컬 shell 설정에 Anthropic 또는 gateway 변수가 있으면 `claude`가 이를 상속할 수 있습니다.

선택적 wrapper 설정은 환경 변수나 이 Skill 디렉터리의 로컬 `.env`에 둘 수 있습니다. `.env` parser는 `CLAUDE_CLI_` prefix가 있는 변수만 읽습니다.

자주 쓰는 설정:

- `CLAUDE_CLI_BIN`: Claude CLI 경로 또는 명령 이름.
- `CLAUDE_CLI_DEFAULT_BUDGET_USD`: `consult` 기본 비용 상한. 기본값은 `0.12`.
- `CLAUDE_CLI_OUTPUT_WORDS`: 기본 응답 단어 예산. 기본값은 `900`.
- `CLAUDE_CLI_RETRY_OUTPUT_WORDS`: budget recovery retry의 응답 단어 예산. 기본값은 `450`.
- `CLAUDE_CLI_RETRY_INPUT_CHARS`: budget error 이후 retry prompt 목표 문자 수. 기본값은 `16000`.
- `CLAUDE_CLI_WARN_INPUT_CHARS`: 큰 prompt 경고를 발생시키는 문자 수. 기본값은 `24000`.

설정을 확인합니다:

```bash
cd ~/.codex/skills/claude-cli-assistant
./scripts/run-claude-cli.sh --check
./scripts/run-claude-cli.sh --print-config
```

`--print-config`는 Provider 값을 redaction 처리하고 설정 여부만 표시합니다.

## 사용

```bash
printf '%s' "Review this plan for missing cases. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult plan-critique
```

Codex에서 Skill로 호출할 수도 있습니다:

```text
Use $claude-cli-assistant to consult local Claude CLI on this implementation plan.
```

## Agent 협업

Claude를 일회성 ad hoc prompt 답변이 아니라 다른 code agent와 협업하는 reviewer로 사용할 때는 구조화 preset을 사용하세요:

```bash
./scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
./scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md --async --wait-timeout 30
```

사용 가능한 preset:

- `review`: code 또는 diff에 대한 adversarial review.
- `plan-critique`: 구현 계획 비평.
- `spec-rederive`: 작업 이해를 독립적으로 재도출.
- `test-design`: 독립적인 테스트 아이디어.
- `debug-root-cause`: 실패 및 로그 원인 분석.
- `blast-radius`: production 및 integration risk review.

Preset prompt는 Claude가 `BEGIN_RESULT` / `END_RESULT` 결과 블록을 반환하도록 요청합니다. 비동기 run이 완료된 뒤 `result <run_id>`로 추출된 답변을 읽을 수 있습니다.

## 장시간 작업

다른 code agent가 Claude CLI 완료 전에 대기를 중단할 수 있는 경우 비동기 모드를 사용하세요:

```bash
run_id=$(printf '%s' "Review this large refactor. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult review --async --wait-timeout 25)
./scripts/run-claude-cli.sh status "$run_id"
./scripts/run-claude-cli.sh logs "$run_id" --tail 80
./scripts/run-claude-cli.sh result "$run_id"
```

비동기 명령:

- `consult <preset> --async`: preset prompt를 만들고 supervisor 아래에서 Claude를 실행합니다.
- `start`: 같은 supervisor로 raw Claude CLI arguments를 실행합니다.
- `status <run_id>`: 상태, 경과 시간, idle 시간, 이유, 종료 코드를 표시합니다.
- `wait <run_id> --timeout N`: 호출자의 대기 예산만큼만 기다립니다. 아직 실행 중이면 현재 상태를 반환하고 Claude를 종료하지 않습니다.
- `logs <run_id>`: stdout을 표시합니다. `--stderr` 또는 `--events`로 다른 로그를 볼 수 있습니다.
- `result <run_id>`: 추출된 결과 블록을 표시합니다. 결과 블록이 없으면 stdout을 표시합니다.
- `cancel <run_id>`: Claude 프로세스 그룹을 종료하고 run을 cancelled로 표시합니다.
- `list`: 최근 run을 표시합니다.

timeout은 서로 분리되어 있습니다:

- `wait --timeout`: 호출자의 대기 예산일 뿐이며 작업 실패가 아닙니다.
- async run의 `--max-wall`: 전체 작업 실행 시간 hard cap입니다. 기본값은 `600`초, 종료 코드는 `125`입니다.
- async run의 `--idle-timeout`: 출력이 없는 상태의 timeout입니다. 기본값은 `120`초, 종료 코드는 `124`입니다.

## 예산과 모델 참고 사항

- 큰 context packet은 Claude가 유용한 출력을 쓰기 전에 입력 token만으로 설정된 예산을 소진할 수 있습니다.
- wrapper는 큰 prompt에 경고를 표시하고 budget-limit error 이후 compacted input과 concise output으로 한 번 retry합니다.
- `--model sonnet` 같은 alias가 비용을 낮췄다고 가정하지 마세요. JSON `modelUsage`를 확인하세요. 동기 wrapper 호출은 요청한 문자열이 `modelUsage`에 없으면 경고합니다.

## 보안

- `.env`, API key, Bearer token, 비공개 엔드포인트, 로컬 계정 정보, Provider 인증 정보를 commit 하지 마세요.
- secret을 과거에 commit 한 적이 있다면 새 저장소를 만들거나 공개 전에 Git 기록을 정리하세요.
- 기본 consult는 read-only입니다: tools 없음, `permission-mode dontAsk`, session persistence 없음.
- Claude 출력은 참고용으로만 사용하고, 실행하기 전에 로컬 파일, 명령, 테스트, diff로 검증하세요.
- `agents/openai.yaml`은 Skill 템플릿이 생성한 Codex UI 메타데이터이며, 이 Skill이 OpenAI Provider 전용이라는 뜻은 아닙니다.

## Release Notes

### 2026-06-29

- 큰 Claude prompt에 대한 input-size warning을 추가했습니다.
- 동기 `consult` 호출에 compacted-input budget recovery retry를 추가했습니다.
- 요청한 model alias와 `modelUsage`가 일치하지 않을 때 경고를 추가했습니다.

### 2026-06-28

- `consult <preset>`을 통한 구조화 agent collaboration preset을 추가했습니다.
- bounded/redacted context packet을 생성하는 `scripts/pack-context.sh`를 추가했습니다.
- 장시간 작업 관리를 위해 `start`, `status`, `wait`, `logs`, `result`, `cancel`, `list`를 추가했습니다.
- role, consultation gate, finding contract, adjudication rule을 다루는 collaboration protocol을 추가했습니다.

## 라이선스

MIT
