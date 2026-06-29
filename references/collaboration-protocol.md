# Codex-Claude Collaboration Protocol

Use this protocol when Claude CLI is more than a one-off answer source. The goal is independent, evidence-grounded collaboration between a primary code agent and Claude Code CLI.

## Roles

- Primary agent: Owns repository inspection, edits, tests, and final judgment.
- Claude reviewer: Gives read-only second opinions, risks, missing tests, and root-cause hypotheses.
- Evidence: Files, diffs, logs, commands, tests, rendered artifacts, and reproducible failures decide disagreements.

## Default Loop

1. Propose: Primary agent states the task, constraints, and intended approach.
2. Critique: Claude reviews the plan, diff, failure, or test surface using a prompt preset.
3. Adjudicate: Primary agent accepts, rejects, or converts each finding into a targeted experiment.
4. Verify: Primary agent runs targeted checks before treating a finding as resolved.

Use at most two critique/adjudication rounds for one concern. If evidence is still inconclusive, escalate to the user with both positions and the missing experiment.

## When to Consult

Consult Claude when any condition is true:

- The diff is large, cross-cutting, or touches shared contracts.
- The task is ambiguous and could be implemented in meaningfully different ways.
- The change touches auth, security, data integrity, billing, migrations, concurrency, public APIs, or high-cost user workflows.
- A test or CI failure survives one fix attempt.
- The primary agent wants independent test ideas before accepting an implementation.

Skip Claude for trivial mechanical edits, formatting-only changes, or localized changes already covered by strong tests.

## Finding Contract

Ask Claude to return a single `BEGIN_RESULT` / `END_RESULT` block. Each finding should include:

- severity: `blocker`, `high`, `medium`, `low`, or `question`
- location: file path plus line hint when available
- claim: the concrete risk or defect
- trigger: input, state, or condition that exposes the issue
- evidence_needed: command, test, file inspection, or experiment needed to verify it
- confidence: `0.00` to `1.00`

Primary agents should not fix a Claude finding until they can reproduce, inspect, or otherwise verify the claim. Unverified claims become watch notes or user questions, not accepted facts.

## Adjudication Rules

- Accept a finding only when local evidence supports it.
- Reject a finding with a concrete reason, such as an existing test, contract, or code path that contradicts it.
- Convert unclear findings into targeted experiments.
- Do not let agent consensus replace tests or source evidence.
- Do not paste Claude's suggested code blindly. Re-derive the fix locally and verify it.

## Context Packet

Use `scripts/pack-context.sh` to give Claude bounded, redacted evidence:

```bash
./scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
./scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md
```

Context packets should include only relevant evidence and avoid secrets. The packer redacts common keys and tokens, but the primary agent is still responsible for not sending private data that should not leave the machine or provider boundary.

## Timeout Contract

Use `wait --timeout` as the outer agent's patience budget. It must not be treated as Claude failure. Use `--max-wall` and `--idle-timeout` on `start` or `consult --async` as real task lifetime controls.
