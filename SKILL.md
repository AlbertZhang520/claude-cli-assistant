---
name: claude-cli-assistant
description: Use local Claude Code CLI as an advisory collaborator. Use when Codex should consult Claude for read-only second opinions, code review, plan critique, debugging hypotheses, test design, blast-radius analysis, spec re-derivation, or structured multi-agent collaboration through the locally authenticated `claude` command without hard-coding credentials.
---

# Claude CLI Assistant

## Overview

Invoke the local `claude` CLI in non-interactive mode and treat its output as advisory. Use this skill to widen analysis with Claude, then verify claims with local files, commands, tests, or diffs before acting.

This skill is intentionally CLI-first and credential-neutral. Do not hard-code API keys, private endpoints, bearer tokens, local account details, or machine-specific paths.

For multi-agent work, follow `references/collaboration-protocol.md`. Use Claude as a constrained reviewer or specialist, not as an authority.

## Quick Start

Check the local Claude CLI and authentication:

```bash
./scripts/run-claude-cli.sh --check
```

Run a read-only one-shot consultation:

```bash
printf '%s' "Review this plan for missing cases. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult plan-critique
```

Review the current diff with a bounded context packet:

```bash
./scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
./scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md
```

When asking Claude to choose a next slice or judge whether a capability is missing, include a lightweight inventory:

```bash
./scripts/pack-context.sh --inventory --file README.md --output /tmp/claude-context.md
```

Start a long-running consultation without blocking the caller:

```bash
run_id=$(./scripts/run-claude-cli.sh consult blast-radius --context /tmp/claude-context.md --async --wait-timeout 30)
./scripts/run-claude-cli.sh status "$run_id"
./scripts/run-claude-cli.sh result "$run_id"
```

Inspect sanitized configuration:

```bash
./scripts/run-claude-cli.sh --print-config
```

## Workflow

1. Confirm `claude` is installed and authenticated with `./scripts/run-claude-cli.sh --check`.
2. Build a bounded, redacted context packet when asking about repository state.
3. Use `consult <preset>` for repeatable roles:
   - `review`: adversarial code/diff review.
   - `plan-critique`: missing cases and risky assumptions before implementation.
   - `test-design`: independent test ideas from a task or diff.
   - `debug-root-cause`: hypotheses for failures or logs.
   - `blast-radius`: integration and production impact analysis.
   - `spec-rederive`: independent task/spec interpretation.
4. Prefer the default read-only mode. It invokes `claude -p` with JSON output, `--tools ""`, `--permission-mode dontAsk`, `--no-session-persistence`, a cost budget, and a bounded response budget.
   - If the context packet is large, expect an input-size warning. Shrink the packet or raise `--budget` for deep reviews.
   - On budget-limit errors, the wrapper retries once with a concise output budget and a compacted retry prompt.
5. Use `--async` plus bounded `wait --timeout` for longer tasks.
6. Adjudicate Claude findings with local evidence. Do not copy suggested code blindly.

## Invocation Patterns

Structured review:

```bash
./scripts/run-claude-cli.sh consult review \
  --context /tmp/claude-context.md \
  --extra "Return concrete findings only. Do not propose cosmetic changes."
```

Plan critique:

```bash
printf '%s' "<plan text>" \
  | ./scripts/run-claude-cli.sh consult plan-critique --budget 0.18 --output-words 1000
```

Stream JSON output:

```bash
printf '%s' "Think through this failure and report likely causes." \
  | ./scripts/run-claude-cli.sh consult debug-root-cause --stream
```

Opt into a tool-enabled consultation only when needed:

```bash
./scripts/run-claude-cli.sh consult review \
  --context /tmp/claude-context.md \
  --allow-tools "Read,Grep" \
  --permission-mode dontAsk
```

## Safety Rules

- Never commit `.env`, credentials, provider URLs, API keys, bearer tokens, or private account data.
- Default to read-only consultations. Widen tools only with explicit `--allow-tools`.
- Redact secrets before sending context. The packer handles common patterns, but the caller owns final judgment.
- A local `.env` is only read for `CLAUDE_CLI_*` wrapper variables; do not use it for provider credentials.
- When enabling mutating tools such as `Bash`, `Edit`, or `Write`, prefer `--permission-mode default` unless silent mutation is intentional.
- Keep input and output bounded for deep reviews. The wrapper defaults to `--output-words 900`, warns on large prompts, and retries once with a compacted input prompt plus concise recovery mode if Claude returns a budget error.
- For capability-gap analysis, provide `pack-context.sh --inventory` and require absence claims to cite evidence. If inventory is missing or reports `TRUNCATED`, treat "missing capability" conclusions as unverified assumptions until targeted local searches confirm them.
- Do not assume `--model sonnet` or another alias reduced cost. Check `modelUsage`; synchronous wrapper calls warn when the requested model string is absent from `modelUsage`.
- Treat `wait --timeout` as caller patience, not task failure. Use async status/result commands to inspect the real terminal state.
- If a prompt may have caused edits because tools were enabled, inspect relevant diffs immediately.

## Resources

- `scripts/run-claude-cli.sh`: wrapper around local `claude` for checks, sync consultation, async runs, and result retrieval.
- `scripts/pack-context.sh`: read-only, redacted context packet builder for status, diffs, files, and logs.
- `references/collaboration-protocol.md`: role protocol, finding contract, and adjudication rules.
- `references/prompts/*.md`: prompt presets used by `consult`.
- `references/claude-cli.md`: verified local CLI behavior, options, troubleshooting, and publication checklist.
