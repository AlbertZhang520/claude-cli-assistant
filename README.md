# Claude CLI Assistant

Languages: English | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

A credential-neutral Codex skill for consulting the local Claude Code CLI as an advisory collaborator. This is a Codex skill; `claude` is the external CLI it invokes.

This repository does not contain API keys, private endpoints, bearer tokens, local shell aliases, or machine-specific paths. Claude authentication and provider routing must stay in the user's local environment.

## Use Cases

- **Codex-Claude cross-development**: let Codex implement locally, then ask Claude CLI to critique a plan, review a diff, identify missing tests, or challenge risky assumptions.
- **Multi-agent code review**: use one assistant as the primary implementer and Claude as an independent reviewer before accepting changes.
- **Debugging support**: pass failing command output, logs, or reduced reproduction notes to Claude for root-cause hypotheses, then verify every claim locally.
- **Architecture and blast-radius review**: ask Claude to inspect cross-module contracts, public APIs, migrations, data integrity risks, or production impact.
- **Test planning**: ask for high-signal test cases and edge conditions after a change is scoped.
- **Long-running collaboration**: run Claude under a local async supervisor so another agent can stop waiting without killing the Claude task.

## Install

Clone this repository into your Codex skills directory:

```bash
mkdir -p ~/.codex/skills
git clone https://github.com/AlbertZhang520/claude-cli-assistant.git ~/.codex/skills/claude-cli-assistant
```

Install and authenticate Claude Code CLI separately, then confirm it is available:

```bash
claude --version
claude auth status
```

## Configure

The wrapper uses the caller's existing shell environment. If your local shell config provides Anthropic or gateway variables, `claude` may inherit them.

Optional wrapper settings can be placed in environment variables or a local `.env` file in this skill directory. The `.env` parser only accepts variables prefixed with `CLAUDE_CLI_`.

Common settings:

- `CLAUDE_CLI_BIN`: path or command name for Claude CLI.
- `CLAUDE_CLI_DEFAULT_BUDGET_USD`: default cost cap for `consult`, default `0.12`.
- `CLAUDE_CLI_OUTPUT_WORDS`: default response budget, default `900`.
- `CLAUDE_CLI_RETRY_OUTPUT_WORDS`: response budget for budget-recovery retry, default `450`.
- `CLAUDE_CLI_RETRY_INPUT_CHARS`: retry prompt size target after a budget error, default `16000`.
- `CLAUDE_CLI_WARN_INPUT_CHARS`: prompt size that triggers a pre-call warning, default `24000`.

Check configuration:

```bash
cd ~/.codex/skills/claude-cli-assistant
./scripts/run-claude-cli.sh --check
./scripts/run-claude-cli.sh --print-config
```

`--print-config` redacts provider values and only reports whether they are configured.

## Use

```bash
printf '%s' "Review this plan for missing cases. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult plan-critique
```

Or invoke the skill in Codex:

```text
Use $claude-cli-assistant to consult local Claude CLI on this implementation plan.
```

## Agent Collaboration

Use structured presets when Claude should collaborate with another code agent instead of answering an ad hoc prompt:

```bash
./scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
./scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md --async --wait-timeout 30
```

Available presets:

- `review`: adversarial code or diff review.
- `plan-critique`: implementation plan critique.
- `spec-rederive`: independent task interpretation.
- `test-design`: independent test ideas.
- `debug-root-cause`: failure and log diagnosis.
- `blast-radius`: production and integration risk review.

Preset prompts ask Claude to return a `BEGIN_RESULT` / `END_RESULT` block. Use `result <run_id>` to read the extracted answer from an async run.

## Long-running Tasks

Use async mode when another code agent may stop waiting before Claude CLI finishes:

```bash
run_id=$(printf '%s' "Review this large refactor. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult review --async --wait-timeout 25)
./scripts/run-claude-cli.sh status "$run_id"
./scripts/run-claude-cli.sh logs "$run_id" --tail 80
./scripts/run-claude-cli.sh result "$run_id"
```

Async commands:

- `consult <preset> --async`: build a preset prompt and launch Claude under a supervisor.
- `start`: launch raw Claude CLI arguments under the same supervisor.
- `status <run_id>`: show state, elapsed time, idle time, reason, and exit code.
- `wait <run_id> --timeout N`: wait only for the caller's budget. If the run is still active, it returns the current state and does not kill Claude.
- `logs <run_id>`: show stdout; use `--stderr` or `--events` for other logs.
- `result <run_id>`: show the extracted result block when present, otherwise stdout.
- `cancel <run_id>`: terminate the Claude process group and mark the run as cancelled.
- `list`: show recent runs.

Timeouts are separate:

- `wait --timeout`: caller wait budget only, never a task failure.
- `--max-wall` on async runs: hard task runtime cap, default `600` seconds, exit code `125`.
- `--idle-timeout` on async runs: no-output timeout, default `120` seconds, exit code `124`.

## Budget and Model Notes

- Large context packets can exhaust the configured budget on input tokens before Claude writes useful output.
- The wrapper warns when a prompt is large and retries budget-limit errors once with compacted input plus concise output.
- Do not assume `--model sonnet` or another alias reduced cost. Inspect JSON `modelUsage`; synchronous wrapper calls warn when the requested string is absent from `modelUsage`.

## Security

- Never commit `.env`, API keys, bearer tokens, private endpoints, local account details, or provider credentials.
- If secrets were ever committed, create a fresh repository or clean history before publishing.
- Default consultations are read-only: no tools, `permission-mode dontAsk`, and no session persistence.
- Treat Claude output as advisory and verify with local files, commands, tests, or diffs before acting.
- `agents/openai.yaml` is Codex skill UI metadata generated by the skill template; it does not make the skill OpenAI-provider-specific.

## Release Notes

### 2026-06-29

- Added input-size warnings for large Claude prompts.
- Added compacted-input budget recovery for synchronous `consult` calls.
- Added `modelUsage` mismatch warnings for requested model aliases.

### 2026-06-28

- Added structured agent collaboration presets through `consult <preset>`.
- Added `scripts/pack-context.sh` for bounded, redacted context packets.
- Added async run management: `start`, `status`, `wait`, `logs`, `result`, `cancel`, and `list`.
- Added a collaboration protocol covering roles, consultation gates, finding contracts, and adjudication rules.

## License

MIT
