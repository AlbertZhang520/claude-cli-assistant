# Claude CLI Reference

## Verified Local Behavior

The local machine was verified with Claude Code CLI `2.1.181`.

Useful non-interactive flags:

| Purpose | Flag |
| --- | --- |
| Non-interactive output | `-p` or `--print` |
| Output format | `--output-format text|json|stream-json` |
| Streaming JSON | `--output-format stream-json --verbose` |
| Disable tools | `--tools ""` |
| Tool permissions | `--allowedTools`, `--disallowedTools`, `--permission-mode` |
| No saved session | `--no-session-persistence` |
| Cost cap | `--max-budget-usd <amount>` |
| Model and effort | `--model`, `--effort` |
| Session control | `--session-id`, `--resume`, `--continue` |
| Strict minimal mode | `--bare` |
| External tools | `--mcp-config`, `--settings` |

Verified calls:

```bash
printf '%s' "Return exactly STDIN_OK" \
  | claude -p --output-format json --max-budget-usd 0.05 --tools "" --permission-mode dontAsk --no-session-persistence
```

```bash
claude -p "Return exactly STREAM_OK" \
  --output-format stream-json --verbose --max-budget-usd 0.05 --tools "" --permission-mode dontAsk --no-session-persistence
```

`--output-format json` returns a single JSON object. Common fields include:

- `result`: the assistant text.
- `session_id`: the conversation id.
- `total_cost_usd`: spend for the call.
- `usage` and `modelUsage`: token and model accounting.
- `structured_output`: present when `--json-schema` is used successfully.
- `is_error`, `api_error_status`, `terminal_reason`: terminal state details.

## Wrapper Defaults

`scripts/run-claude-cli.sh consult <preset>` defaults to:

```bash
claude -p \
  --output-format json \
  --max-budget-usd 0.12 \
  --tools "" \
  --permission-mode dontAsk \
  --no-session-persistence
```

The wrapper sends the prompt on stdin. This avoids shell interpolation and supports larger context packets than argv-only prompt passing.

The wrapper also injects an output budget instruction by default:

```text
Return one BEGIN_RESULT / END_RESULT block in at most 900 words.
```

The wrapper warns when the assembled prompt is large enough to risk exhausting the cost budget on input tokens before useful output is produced.

If Claude returns a budget-limit error in synchronous JSON mode, the wrapper retries once in concise recovery mode with a 450-word output budget and a compacted retry prompt. This codifies the manual "rerun a shorter version" recovery pattern that works for complex review tasks.

Synchronous calls with `--model` compare the requested model string against returned JSON `modelUsage`. If the requested string is absent, the wrapper warns that the model alias may not be honored. Treat the JSON `modelUsage` field as authoritative for cost/model analysis.

## Configuration

Optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_CLI_BIN` | `claude` | Path or command name for Claude CLI. |
| `CLAUDE_CLI_DEFAULT_BUDGET_USD` | `0.12` | Default `--max-budget-usd`. |
| `CLAUDE_CLI_OUTPUT_WORDS` | `900` | Default response budget injected into consult prompts. |
| `CLAUDE_CLI_RETRY_OUTPUT_WORDS` | `450` | Response budget for the one-shot budget-error retry. |
| `CLAUDE_CLI_RETRY_INPUT_CHARS` | `16000` | Retry prompt size target after a budget-limit error. Set `0` to keep full retry input. |
| `CLAUDE_CLI_WARN_INPUT_CHARS` | `24000` | Prompt size that triggers a pre-call budget warning. Set `0` to disable. |
| `CLAUDE_CLI_RETRY_BUDGET_USD` | same as request | Optional retry budget after a budget-limit error. |
| `CLAUDE_CLI_PERMISSION_MODE` | `dontAsk` | Default permission mode. |
| `CLAUDE_CLI_TOOLS` | empty | Default tool set. Empty means no tools. |
| `CLAUDE_CLI_RUNS_DIR` | `.claude-cli/runs` | Async run storage. |
| `CLAUDE_CLI_MAX_WALL` | `600` | Async hard wall-clock timeout in seconds. |
| `CLAUDE_CLI_IDLE_TIMEOUT` | `120` | Async no-output timeout in seconds. |

Do not store private values in the skill. A local `.env` is parsed only for `CLAUDE_CLI_*` variables and does not execute shell code or export arbitrary provider credentials to the Claude child process.

The wrapper does not source shell startup files itself, but the `claude` process inherits the caller's existing environment. If the user's shell config provides `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, or `ANTHROPIC_API_KEY`, Claude Code may use those values. `--print-config` reports only whether those variables are configured, with values redacted.

Do not assume `--model <alias>` changed the actual backend model. Confirm the returned JSON `modelUsage` field when model selection or cost matters.

## Troubleshooting

Run:

```bash
./scripts/run-claude-cli.sh --check
./scripts/run-claude-cli.sh --print-config
./scripts/run-claude-cli.sh consult --list-templates
claude --help
claude auth status
```

Common issues:

- Missing `claude`: install Claude Code CLI and ensure it is on `PATH`, or set `CLAUDE_CLI_BIN`.
- Not authenticated: run `claude auth login`.
- `stream-json` rejected: add `--verbose`.
- Unexpected tool behavior: inspect whether `--allow-tools`, `--tools`, or session persistence was enabled.
- Long-running call: use `consult --async`, then `status`, `logs`, and `result`.

## Publication Checklist

Before publishing a repository:

1. Confirm `.env` and `.claude-cli/` are ignored.
2. Search for secrets and private endpoints in the working tree.
3. Search Git history if the repository has prior commits.
4. Prefer a fresh repository if any private values were ever committed.
5. Keep examples generic and credential-neutral.
