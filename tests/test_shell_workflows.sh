#!/usr/bin/env bash
set -euo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
env_file="$skill_dir/.env"
env_backup=""
if [[ -f "$env_file" ]]; then
  env_backup="$tmp/original.env"
  cp "$env_file" "$env_backup"
fi

cleanup() {
  if [[ -n "$env_backup" ]]; then
    cp "$env_backup" "$env_file"
  else
    rm -f "$env_file"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

mock="$tmp/claude"
cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  echo "2.1.181 (Claude Code)"
  exit 0
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  echo '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}'
  exit 0
fi

if [[ "${1:-}" == "-p" || "${1:-}" == "--print" ]]; then
  if [[ -n "${SHOULD_NOT_LEAK-}" ]]; then
    echo "unexpected environment leak" >&2
    exit 65
  fi
  : >"${CLAUDE_MOCK_ARGS:?}"
  for arg in "$@"; do
    printf '<%s>\n' "$arg" >>"$CLAUDE_MOCK_ARGS"
  done
  cat >"${CLAUDE_MOCK_PROMPT:?}"
  if [[ -n "${CLAUDE_MOCK_BUDGET_FAIL_ONCE-}" && ! -f "${CLAUDE_MOCK_BUDGET_MARKER:?}" ]]; then
    touch "$CLAUDE_MOCK_BUDGET_MARKER"
    echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"errors":["Reached maximum budget"]}'
    exit 1
  fi
  if [[ -n "${CLAUDE_MOCK_MODEL_USAGE-}" ]]; then
    printf '{"type":"result","subtype":"success","is_error":false,"result":"MOCK_OK","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0,"usage":{},"modelUsage":{"%s":{"costUSD":0}}}\n' "$CLAUDE_MOCK_MODEL_USAGE"
    exit 0
  fi
  echo '{"type":"result","subtype":"success","is_error":false,"result":"MOCK_OK","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0,"usage":{}}'
  exit 0
fi

echo "unexpected mock invocation: $*" >&2
exit 64
MOCK
chmod +x "$mock"

export CLAUDE_CLI_BIN="$mock"
export CLAUDE_MOCK_ARGS="$tmp/args"
export CLAUDE_MOCK_PROMPT="$tmp/prompt"
export CLAUDE_CLI_RUNS_DIR="$tmp/runs"
export CLAUDE_MOCK_BUDGET_MARKER="$tmp/budget-failed-once"

{
  echo "CLAUDE_CLI_DEFAULT_BUDGET_USD=0.07"
  echo "SHOULD_NOT_LEAK=secret-value"
} >"$env_file"

"$skill_dir/scripts/run-claude-cli.sh" --check >/tmp/claude_cli_check.out
grep -q "configuration looks usable" /tmp/claude_cli_check.out

ANTHROPIC_BASE_URL="https://private.example.test" \
ANTHROPIC_AUTH_TOKEN="fake-private-token-1234567890" \
  "$skill_dir/scripts/run-claude-cli.sh" --print-config >"$tmp/print-config.out"
grep -q 'ANTHROPIC_BASE_URL=<configured>' "$tmp/print-config.out"
grep -q 'ANTHROPIC_AUTH_TOKEN=<redacted>' "$tmp/print-config.out"
grep -q 'CLAUDE_CLI_RETRY_INPUT_CHARS=16000' "$tmp/print-config.out"
grep -q 'CLAUDE_CLI_WARN_INPUT_CHARS=24000' "$tmp/print-config.out"
if grep -q 'private.example.test\\|fake-private-token' "$tmp/print-config.out"; then
  echo "print-config leaked Anthropic environment values" >&2
  exit 1
fi
env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
  "$skill_dir/scripts/run-claude-cli.sh" --print-config >"$tmp/print-config-unset.out"
grep -q 'ANTHROPIC_BASE_URL=$' "$tmp/print-config-unset.out"
grep -q 'ANTHROPIC_AUTH_TOKEN=$' "$tmp/print-config-unset.out"
grep -q 'ANTHROPIC_API_KEY=$' "$tmp/print-config-unset.out"

"$skill_dir/scripts/run-claude-cli.sh" consult --list-templates | grep -q '^review$'

context="$tmp/context.md"
printf '# Context\n\nsecret API_KEY=super-secret\n' >"$context"

out="$(printf '%s' 'Check this task.' | "$skill_dir/scripts/run-claude-cli.sh" consult review --context "$context" --extra "No cosmetic findings.")"
printf '%s' "$out" | jq -e '.result == "MOCK_OK"' >/dev/null
grep -Fx '<--output-format>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<json>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<0.07>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<--tools>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<--permission-mode>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<dontAsk>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<--no-session-persistence>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -q 'Claude Review Preset' "$CLAUDE_MOCK_PROMPT"
grep -q 'Output Budget' "$CLAUDE_MOCK_PROMPT"
grep -q 'at most 900 words' "$CLAUDE_MOCK_PROMPT"
grep -q 'Check this task.' "$CLAUDE_MOCK_PROMPT"
grep -q 'No cosmetic findings.' "$CLAUDE_MOCK_PROMPT"

rm -f "$CLAUDE_MOCK_BUDGET_MARKER"
budget_retry_out="$(CLAUDE_MOCK_BUDGET_FAIL_ONCE=1 "$skill_dir/scripts/run-claude-cli.sh" consult review --context "$context" 2>"$tmp/budget-retry.err")"
printf '%s' "$budget_retry_out" | jq -e '.result == "MOCK_OK"' >/dev/null
grep -q 'retrying once in concise recovery mode' "$tmp/budget-retry.err"
grep -q 'Budget Recovery Mode' "$CLAUDE_MOCK_PROMPT"
grep -q 'at most 450 words' "$CLAUDE_MOCK_PROMPT"

large_retry_context="$tmp/large-retry-context.md"
{
  perl -e 'print "A" x 9000'
  printf 'MIDDLE_SHOULD_BE_OMITTED'
  perl -e 'print "Z" x 9000'
} >"$large_retry_context"
rm -f "$CLAUDE_MOCK_BUDGET_MARKER"
budget_compact_out="$(CLAUDE_MOCK_BUDGET_FAIL_ONCE=1 "$skill_dir/scripts/run-claude-cli.sh" consult review --context "$large_retry_context" --retry-input-chars 6000 2>"$tmp/budget-compact.err")"
printf '%s' "$budget_compact_out" | jq -e '.result == "MOCK_OK"' >/dev/null
grep -q 'compacting retry input' "$tmp/budget-compact.err"
grep -q 'CLAUDE_CLI_CONTEXT_COMPACTED' "$CLAUDE_MOCK_PROMPT"
if grep -q 'MIDDLE_SHOULD_BE_OMITTED' "$CLAUDE_MOCK_PROMPT"; then
  echo "budget recovery retry did not compact the middle of the prompt" >&2
  exit 1
fi

"$skill_dir/scripts/run-claude-cli.sh" consult review --context "$large_retry_context" --warn-input-chars 1000 >/dev/null 2>"$tmp/large-warning.err"
grep -q 'Large context packets may exceed budget before output' "$tmp/large-warning.err"

model_out="$(CLAUDE_MOCK_MODEL_USAGE='claude-opus-4-8-cc[1m]' "$skill_dir/scripts/run-claude-cli.sh" consult review --model sonnet --context "$context" 2>"$tmp/model-warning.err")"
printf '%s' "$model_out" | jq -e '.modelUsage["claude-opus-4-8-cc[1m]"]' >/dev/null
grep -q "requested --model 'sonnet'" "$tmp/model-warning.err"

"$skill_dir/scripts/run-claude-cli.sh" consult review --stream --context "$context" >/dev/null
grep -Fx '<stream-json>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<--verbose>' "$CLAUDE_MOCK_ARGS" >/dev/null

"$skill_dir/scripts/run-claude-cli.sh" consult review --allow-tools "Read,Grep" --context "$context" >/dev/null
grep -Fx '<--allowedTools>' "$CLAUDE_MOCK_ARGS" >/dev/null
if [[ "$(grep -Fxc '<Read,Grep>' "$CLAUDE_MOCK_ARGS")" -ne 2 ]]; then
  echo "--allow-tools should set both --tools and --allowedTools to the requested read-only tools" >&2
  exit 1
fi

"$skill_dir/scripts/run-claude-cli.sh" consult review --resume "Resume prompt." >/dev/null
grep -Fx '<--resume>' "$CLAUDE_MOCK_ARGS" >/dev/null
if grep -Fx '<Resume prompt.>' "$CLAUDE_MOCK_ARGS" >/dev/null; then
  echo "--resume swallowed a positional prompt as a session id" >&2
  exit 1
fi
grep -q 'Resume prompt.' "$CLAUDE_MOCK_PROMPT"

"$skill_dir/scripts/run-claude-cli.sh" consult review --resume=project-name >/dev/null
grep -Fx '<--resume>' "$CLAUDE_MOCK_ARGS" >/dev/null
grep -Fx '<project-name>' "$CLAUDE_MOCK_ARGS" >/dev/null

mutating_out="$("$skill_dir/scripts/run-claude-cli.sh" consult review --allow-tools "Bash" --context "$context" 2>"$tmp/mutating-warning.err")"
printf '%s' "$mutating_out" | jq -e '.result == "MOCK_OK"' >/dev/null
grep -q 'mutating or executable tools' "$tmp/mutating-warning.err"

run_id="$(printf '%s' 'Async task.' | "$skill_dir/scripts/run-claude-cli.sh" consult review --async --wait-timeout 5)"
"$skill_dir/scripts/run-claude-cli.sh" status "$run_id" | jq -e '.state == "succeeded"' >/dev/null
"$skill_dir/scripts/run-claude-cli.sh" result "$run_id" | grep -q 'MOCK_OK'
"$skill_dir/scripts/run-claude-cli.sh" result "$run_id" --status-code >/dev/null

packet="$tmp/packet.md"
"$skill_dir/scripts/pack-context.sh" --file "$context" --output "$packet"
grep -q '<redacted>' "$packet"
if grep -q 'super-secret' "$packet"; then
  echo "raw secret was not redacted" >&2
  exit 1
fi
json_secret="$tmp/json-secret.md"
printf '%s\n' '{"api_key=not-a-real-secret-json-value-1234567890","token=not-a-real-jwt-token-value-1234567890"}' >"$json_secret"
"$skill_dir/scripts/pack-context.sh" --file "$json_secret" --output "$tmp/json-secret-packet.md"
if grep -q 'not-a-real-secret-json-value\\|not-a-real-jwt-token-value' "$tmp/json-secret-packet.md"; then
  echo "json-style secret was not redacted" >&2
  exit 1
fi

big="$tmp/big.txt"
perl -e 'print "x" x 5000' >"$big"
"$skill_dir/scripts/pack-context.sh" --file "$big" --max-bytes 400 --output "$tmp/truncated.md"
grep -Fq '[TRUNCATED: context packet exceeded 400 bytes after redaction]' "$tmp/truncated.md"

echo "shell workflows ok"
