#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"

source "${script_dir}/lib/redact.sh"

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_local_env() {
  local env_file="${repo_dir}/.env"
  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(CLAUDE_CLI_[A-Za-z0-9_]+)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      value="$(trim_space "${BASH_REMATCH[3]}")"
      if [[ "$value" == \"*\" && "$value" == *\" && "${#value}" -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "$value" == \'*\' && "$value" == *\' && "${#value}" -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      fi
      export "$key=$value"
    fi
  done <"$env_file"
}

load_local_env

claude_bin() {
  printf '%s\n' "${CLAUDE_CLI_BIN:-claude}"
}

run_claude() {
  "$(claude_bin)" "$@"
}

require_claude() {
  if ! command -v "$(claude_bin)" >/dev/null 2>&1; then
    echo "Claude CLI was not found on PATH. Install Claude Code or set CLAUDE_CLI_BIN." >&2
    exit 127
  fi
}

check_auth() {
  local auth_json
  auth_json="$(run_claude auth status 2>/dev/null || true)"
  if [[ -z "$auth_json" ]]; then
    echo "Unable to read Claude auth status. Run: claude auth login" >&2
    exit 2
  fi

  if command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$auth_json" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
      echo "Claude CLI is not logged in. Run: claude auth login" >&2
      exit 2
    fi
  elif [[ "$auth_json" != *'"loggedIn": true'* && "$auth_json" != *'"loggedIn":true'* ]]; then
    echo "Claude CLI is not logged in. Run: claude auth login" >&2
    exit 2
  fi
}

check_config() {
  require_claude
  run_claude --version >/dev/null
  check_auth
}

print_config() {
  check_config
  {
    echo "claude_path=$(command -v "$(claude_bin)")"
    echo "claude_version=$(run_claude --version)"
    echo "CLAUDE_CLI_DEFAULT_BUDGET_USD=${CLAUDE_CLI_DEFAULT_BUDGET_USD:-0.12}"
    echo "CLAUDE_CLI_OUTPUT_WORDS=${CLAUDE_CLI_OUTPUT_WORDS:-900}"
    echo "CLAUDE_CLI_LEAN_BUDGET_USD=${CLAUDE_CLI_LEAN_BUDGET_USD:-0.08}"
    echo "CLAUDE_CLI_LEAN_OUTPUT_WORDS=${CLAUDE_CLI_LEAN_OUTPUT_WORDS:-250}"
    echo "CLAUDE_CLI_LEAN_EFFORT=${CLAUDE_CLI_LEAN_EFFORT:-low}"
    echo "CLAUDE_CLI_RETRY_OUTPUT_WORDS=${CLAUDE_CLI_RETRY_OUTPUT_WORDS:-450}"
    echo "CLAUDE_CLI_RETRY_INPUT_CHARS=${CLAUDE_CLI_RETRY_INPUT_CHARS:-16000}"
    echo "CLAUDE_CLI_WARN_INPUT_CHARS=${CLAUDE_CLI_WARN_INPUT_CHARS:-24000}"
    echo "CLAUDE_CLI_PERMISSION_MODE=${CLAUDE_CLI_PERMISSION_MODE:-dontAsk}"
    echo "CLAUDE_CLI_TOOLS=${CLAUDE_CLI_TOOLS-}"
    echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:+<configured>}"
    echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:+<configured>}"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+<configured>}"
    echo "auth_status=$(run_claude auth status)"
  } | redact_stream
}

run_async() {
  exec python3 "${script_dir}/claude_cli_async.py" "$@"
}

warn_if_mutating_tools() {
  local tools_lc
  tools_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$tools_lc" in
    *bash*|*edit*|*write*|*multiedit*|*notebookedit*)
      echo "Warning: --allow-tools includes mutating or executable tools while permission mode is '${permission_mode}'. Prefer --permission-mode default unless silent mutation is intended." >&2
      ;;
  esac
}

is_budget_error_file() {
  local file="$1"
  grep -q 'error_max_budget_usd\|maximum budget\|max_budget_usd' "$file"
}

compact_prompt_for_retry() {
  local prompt="$1"
  local max_chars="$2"
  local length="${#prompt}"

  if [[ ! "$max_chars" =~ ^[0-9]+$ || "$max_chars" -eq 0 || "$length" -le "$max_chars" ]]; then
    printf '%s' "$prompt"
    return 0
  fi

  local head_chars=$((max_chars * 45 / 100))
  local tail_chars=$((max_chars - head_chars))
  if [[ "$head_chars" -lt 1000 && "$max_chars" -ge 2000 ]]; then
    head_chars=1000
    tail_chars=$((max_chars - head_chars))
  fi
  local tail_start=$((length - tail_chars))
  local omitted=$((length - head_chars - tail_chars))

  printf '%s' "${prompt:0:head_chars}"
  printf '\n\n[CLAUDE_CLI_CONTEXT_COMPACTED: omitted %s characters from the middle after a budget-limit error. Raise --budget or --retry-input-chars, or pass --retry-input-chars 0 to keep the full retry prompt.]\n\n' "$omitted"
  printf '%s' "${prompt:tail_start:tail_chars}"
}

warn_if_large_prompt() {
  local prompt="$1"
  local budget="$2"
  local warn_chars="$3"
  local length="${#prompt}"

  if [[ "$warn_chars" =~ ^[0-9]+$ && "$warn_chars" -gt 0 && "$length" -gt "$warn_chars" ]]; then
    local approx_tokens=$(((length + 3) / 4))
    echo "Warning: Claude prompt is ${length} characters (~${approx_tokens} tokens) against budget USD ${budget}. Large context packets may exceed budget before output; shrink context, raise --budget, or rely on input-compacted retry." >&2
  fi
}

requested_model_from_args() {
  local args=("$@")
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--model" && $((i + 1)) -lt ${#args[@]} ]]; then
      printf '%s' "${args[$((i + 1))]}"
      return 0
    fi
  done
  return 0
}

warn_if_model_mismatch() {
  local file="$1"
  shift
  local requested
  requested="$(requested_model_from_args "$@")"
  [[ -n "$requested" ]] || return 0

  local models
  if command -v jq >/dev/null 2>&1; then
    models="$(jq -r '.modelUsage? | keys[]?' "$file" 2>/dev/null | paste -sd ',' -)"
  else
    models="$(python3 - "$file" <<'PY' 2>/dev/null
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(0)
model_usage = data.get("modelUsage") if isinstance(data, dict) else None
if isinstance(model_usage, dict):
    print(",".join(model_usage.keys()))
PY
)"
  fi
  [[ -n "$models" ]] || return 0

  local requested_lc models_lc
  requested_lc="$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')"
  models_lc="$(printf '%s' "$models" | tr '[:upper:]' '[:lower:]')"
  if [[ "$models_lc" != *"$requested_lc"* ]]; then
    echo "Warning: requested --model '${requested}', but Claude JSON modelUsage reports '${models}'. The model alias may not be honored; do not treat --model as a cost control unless modelUsage confirms it." >&2
  fi
}

replace_budget_arg() {
  local new_budget="$1"
  shift
  local args=("$@")
  local replaced=0
  local i
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--max-budget-usd" && $((i + 1)) -lt ${#args[@]} ]]; then
      printf '%s\0' "--max-budget-usd" "$new_budget"
      i=$((i + 1))
      replaced=1
    else
      printf '%s\0' "${args[$i]}"
    fi
  done
  if [[ "$replaced" -eq 0 ]]; then
    printf '%s\0' "--max-budget-usd" "$new_budget"
  fi
}

run_sync_consult() {
  local prompt="$1"
  local retry_on_budget="$2"
  local retry_budget="$3"
  local retry_output_words="$4"
  local retry_input_chars="$5"
  shift 5
  local claude_args=("$@")
  local stdout_file stderr_file status
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"

  set +e
  printf '%s' "$prompt" | run_claude "${claude_args[@]}" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e

  if [[ "$status" -ne 0 && "$retry_on_budget" -eq 1 ]] && { is_budget_error_file "$stdout_file" || is_budget_error_file "$stderr_file"; }; then
    echo "Claude CLI hit the configured budget; retrying once in concise recovery mode." >&2
    local retry_prompt retry_stdout retry_stderr retry_status
    retry_prompt="${prompt}"$'\n\n## Budget Recovery Mode\n\nThe previous attempt exceeded the configured Claude CLI budget. Return only the highest-signal result in at most '"${retry_output_words}"$' words. Do not restate the context. Prefer bullets over prose. Include only blocker/high findings, final verdict, or next checks.\n'
    if [[ "$retry_input_chars" =~ ^[0-9]+$ && "$retry_input_chars" -gt 0 && "${#retry_prompt}" -gt "$retry_input_chars" ]]; then
      echo "Claude CLI budget recovery is compacting retry input from ${#retry_prompt} to about ${retry_input_chars} characters." >&2
      retry_prompt="$(compact_prompt_for_retry "$retry_prompt" "$retry_input_chars")"
    fi
    retry_stdout="$(mktemp)"
    retry_stderr="$(mktemp)"
    local retry_args=()
    while IFS= read -r -d '' arg; do
      retry_args+=("$arg")
    done < <(replace_budget_arg "$retry_budget" "${claude_args[@]}")

    set +e
    printf '%s' "$retry_prompt" | run_claude "${retry_args[@]}" >"$retry_stdout" 2>"$retry_stderr"
    retry_status=$?
    set -e
    cat "$retry_stderr" >&2
    warn_if_model_mismatch "$retry_stdout" "${retry_args[@]}"
    cat "$retry_stdout"
    rm -f "$stdout_file" "$stderr_file" "$retry_stdout" "$retry_stderr"
    return "$retry_status"
  fi

  cat "$stderr_file" >&2
  warn_if_model_mismatch "$stdout_file" "${claude_args[@]}"
  cat "$stdout_file"
  rm -f "$stdout_file" "$stderr_file"
  return "$status"
}

list_templates() {
  find "${repo_dir}/references/prompts" -maxdepth 1 -type f -name '*.md' -print \
    | sed -E 's#^.*/([^/]+)\.md$#\1#' \
    | sort
}

usage() {
  cat <<'EOF'
Usage:
  scripts/run-claude-cli.sh --check
  scripts/run-claude-cli.sh --print-config
  scripts/run-claude-cli.sh consult --list-templates
  scripts/run-claude-cli.sh consult <preset> [options] [-- prompt text]
  scripts/run-claude-cli.sh start [async options] -- [claude arguments...]
  scripts/run-claude-cli.sh status <run-id>
  scripts/run-claude-cli.sh wait <run-id> [--timeout N]
  scripts/run-claude-cli.sh logs <run-id> [--stderr|--events] [--tail N] [--follow]
  scripts/run-claude-cli.sh result <run-id> [--raw|--json|--status-code]
  scripts/run-claude-cli.sh cancel <run-id>
  scripts/run-claude-cli.sh list [--limit N]
  scripts/run-claude-cli.sh [claude arguments...]

Consult options:
  --context FILE          Append a context packet. Repeatable.
  --extra TEXT            Append extra instructions. Repeatable.
  --model MODEL           Pass --model.
  --effort LEVEL          Pass --effort low|medium|high|xhigh|max.
  --budget USD            Pass --max-budget-usd. Default: 0.12.
  --output-words N        Add a hard response budget. Default: 900.
  --no-output-budget      Do not add the response budget instruction.
  --lean                  Use low-cost consult defaults unless overridden:
                          --bare, --effort low, --output-words 250, --budget 0.08.
  --retry-budget USD      Budget used by one concise retry after budget errors.
  --retry-input-chars N   Compact retry prompt to this size after budget errors.
                          Default: 16000. Use 0 to disable input compaction.
  --warn-input-chars N    Warn before calls whose prompt exceeds this size.
                          Default: 24000. Use 0 to disable.
  --no-retry-on-budget-error
                          Disable one-shot concise retry on budget errors.
  --schema FILE|JSON      Pass --json-schema.
  --stream                Use --output-format stream-json and add --verbose.
  --tools LIST            Set available tools. Default: empty string.
  --allow-tools LIST      Set available tools and --allowedTools.
  --permission-mode MODE  Default: dontAsk.
  --session-id UUID       Use a specific session id and allow persistence.
  --resume [ID]           Resume latest or an ID-like session and allow persistence.
  --resume=VALUE          Resume an explicit session id, prefix, or name.
  --continue              Continue the most recent session and allow persistence.
  --persist               Do not add --no-session-persistence.
  --bare                  Add --bare.
  --max-wall N            Async hard wall-clock timeout in seconds.
  --idle-timeout N        Async no-output timeout in seconds.
  --heartbeat N           Async status heartbeat interval in seconds.
  --grace N               Async process termination grace period in seconds.
  --async                 Start under async supervisor and print run id.
  --wait-timeout N        With --async, wait up to N seconds on stderr.
EOF
}

build_prompt() {
  local template="$1"
  shift
  local prompt
  prompt="$(cat "$template")"

  if [[ "${output_budget:-0}" -eq 1 && -n "${output_words:-}" && "${output_words}" != "0" ]]; then
    prompt+=$'\n\n## Output Budget\n\n'
    prompt+="Return one ${BEGIN_RESULT:-BEGIN_RESULT} / ${END_RESULT:-END_RESULT} block in at most ${output_words} words. Prioritize concrete findings, verdicts, and next checks over exhaustive narration. If the context is large, summarize only the highest-signal issues."
  fi

  local context_file
  for context_file in "${contexts[@]+"${contexts[@]}"}"; do
    if [[ ! -f "$context_file" ]]; then
      echo "Missing context file: ${context_file}" >&2
      return 2
    fi
    prompt+=$'\n\n## Context Packet: '"${context_file}"$'\n\n'
    prompt+="$(cat "$context_file")"
  done

  if [[ -n "${stdin_prompt:-}" ]]; then
    prompt+=$'\n\n## Task\n\n'
    prompt+="$stdin_prompt"
  fi

  if [[ -n "${positional_prompt:-}" ]]; then
    prompt+=$'\n\n## Task\n\n'
    prompt+="$positional_prompt"
  fi

  if [[ -n "${extra_text:-}" ]]; then
    prompt+=$'\n\n## Additional Instructions\n\n'
    prompt+="$extra_text"
  fi

  printf '%s' "$prompt"
}

consult() {
  if [[ $# -eq 0 || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage:
  scripts/run-claude-cli.sh consult --list-templates
  scripts/run-claude-cli.sh consult <preset> [options] [-- prompt text]

Examples:
  scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
  scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md
  printf '%s' "<plan>" | scripts/run-claude-cli.sh consult plan-critique --budget 0.08
EOF
    return 0
  fi

  if [[ "${1:-}" == "--list-templates" ]]; then
    list_templates
    return 0
  fi

  local preset="$1"
  shift
  local template="${repo_dir}/references/prompts/${preset}.md"
  if [[ ! -f "$template" ]]; then
    echo "Unknown consult preset: ${preset}" >&2
    echo "Available presets:" >&2
    list_templates >&2
    return 2
  fi

  local async=0
  local stream=0
  local wait_timeout=""
  local budget="${CLAUDE_CLI_DEFAULT_BUDGET_USD:-0.12}"
  local output_words="${CLAUDE_CLI_OUTPUT_WORDS:-900}"
  local output_budget=1
  local lean=0
  local budget_explicit=0
  local output_budget_explicit=0
  local effort_explicit=0
  local retry_budget="${CLAUDE_CLI_RETRY_BUDGET_USD:-}"
  local retry_output_words="${CLAUDE_CLI_RETRY_OUTPUT_WORDS:-450}"
  local retry_input_chars="${CLAUDE_CLI_RETRY_INPUT_CHARS:-16000}"
  local warn_input_chars="${CLAUDE_CLI_WARN_INPUT_CHARS:-24000}"
  local retry_on_budget=1
  local output_format="json"
  local permission_mode="${CLAUDE_CLI_PERMISSION_MODE:-dontAsk}"
  local tools_mode="${CLAUDE_CLI_TOOLS-}"
  local tools_explicit=0
  local allow_tools=""
  local model=""
  local effort=""
  local schema=""
  local session_id=""
  local resume_value=""
  local continue_recent=0
  local persist=0
  local bare=0
  local async_args=()
  local contexts=()
  local extra_text=""
  local positional_prompt=""
  local stdin_prompt=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context)
        [[ $# -ge 2 ]] || { echo "--context requires a file" >&2; return 2; }
        contexts+=("$2")
        shift 2
        ;;
      --extra)
        [[ $# -ge 2 ]] || { echo "--extra requires text" >&2; return 2; }
        extra_text+=$'\n'"$2"
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || { echo "--model requires a value" >&2; return 2; }
        model="$2"
        shift 2
        ;;
      --effort)
        [[ $# -ge 2 ]] || { echo "--effort requires a value" >&2; return 2; }
        effort="$2"
        effort_explicit=1
        shift 2
        ;;
      --budget)
        [[ $# -ge 2 ]] || { echo "--budget requires USD amount" >&2; return 2; }
        budget="$2"
        budget_explicit=1
        shift 2
        ;;
      --output-words)
        [[ $# -ge 2 ]] || { echo "--output-words requires a value" >&2; return 2; }
        output_words="$2"
        output_budget=1
        output_budget_explicit=1
        shift 2
        ;;
      --no-output-budget)
        output_budget=0
        output_budget_explicit=1
        shift
        ;;
      --lean)
        lean=1
        shift
        ;;
      --retry-budget)
        [[ $# -ge 2 ]] || { echo "--retry-budget requires USD amount" >&2; return 2; }
        retry_budget="$2"
        shift 2
        ;;
      --retry-input-chars)
        [[ $# -ge 2 ]] || { echo "--retry-input-chars requires a character count" >&2; return 2; }
        retry_input_chars="$2"
        shift 2
        ;;
      --warn-input-chars)
        [[ $# -ge 2 ]] || { echo "--warn-input-chars requires a character count" >&2; return 2; }
        warn_input_chars="$2"
        shift 2
        ;;
      --no-retry-on-budget-error)
        retry_on_budget=0
        shift
        ;;
      --schema)
        [[ $# -ge 2 ]] || { echo "--schema requires a file path or JSON schema" >&2; return 2; }
        schema="$2"
        shift 2
        ;;
      --stream)
        stream=1
        output_format="stream-json"
        shift
        ;;
      --tools)
        [[ $# -ge 2 ]] || { echo "--tools requires a value" >&2; return 2; }
        tools_mode="$2"
        tools_explicit=1
        shift 2
        ;;
      --allow-tools|--allowed-tools)
        [[ $# -ge 2 ]] || { echo "$1 requires a tool list" >&2; return 2; }
        allow_tools="$2"
        if [[ "$tools_explicit" -eq 0 ]]; then
          tools_mode="$2"
        fi
        shift 2
        ;;
      --permission-mode)
        [[ $# -ge 2 ]] || { echo "--permission-mode requires a value" >&2; return 2; }
        permission_mode="$2"
        shift 2
        ;;
      --session-id)
        [[ $# -ge 2 ]] || { echo "--session-id requires a UUID" >&2; return 2; }
        session_id="$2"
        persist=1
        shift 2
        ;;
      --resume)
        persist=1
        shift
        if [[ $# -gt 0 && "${1:0:2}" != "--" && "$1" =~ ^([0-9a-fA-F]{7,}|[0-9a-fA-F]{8}-[0-9a-fA-F-]{20,})$ ]]; then
          resume_value="$1"
          shift
        else
          resume_value="__latest__"
        fi
        ;;
      --resume=*)
        persist=1
        resume_value="${1#--resume=}"
        shift
        ;;
      --continue)
        continue_recent=1
        persist=1
        shift
        ;;
      --persist)
        persist=1
        shift
        ;;
      --bare)
        bare=1
        shift
        ;;
      --async)
        async=1
        shift
        ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || { echo "--wait-timeout requires seconds" >&2; return 2; }
        async=1
        wait_timeout="$2"
        shift 2
        ;;
      --max-wall|--idle-timeout|--heartbeat|--grace)
        [[ $# -ge 2 ]] || { echo "$1 requires seconds" >&2; return 2; }
        async_args+=("$1" "$2")
        shift 2
        ;;
      --)
        shift
        positional_prompt="$*"
        break
        ;;
      -)
        stdin_prompt="$(cat)"
        shift
        ;;
      *)
        if [[ -n "$positional_prompt" ]]; then
          positional_prompt+=" "
        fi
        positional_prompt+="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$stdin_prompt" && ! -t 0 ]]; then
    stdin_prompt="$(cat)"
  fi
  if [[ "$lean" -eq 1 ]]; then
    bare=1
    if [[ "$effort_explicit" -eq 0 ]]; then
      effort="${CLAUDE_CLI_LEAN_EFFORT:-low}"
    fi
    if [[ "$output_budget_explicit" -eq 0 ]]; then
      output_words="${CLAUDE_CLI_LEAN_OUTPUT_WORDS:-250}"
      output_budget=1
    fi
    if [[ "$budget_explicit" -eq 0 ]]; then
      budget="${CLAUDE_CLI_LEAN_BUDGET_USD:-0.08}"
    fi
  fi
  if [[ -z "$retry_budget" ]]; then
    retry_budget="$budget"
  fi

  local prompt
  prompt="$(build_prompt "$template")"
  warn_if_large_prompt "$prompt" "$budget" "$warn_input_chars"

  local claude_args=(-p --output-format "$output_format" --max-budget-usd "$budget" --tools "$tools_mode" --permission-mode "$permission_mode")
  if [[ "$stream" -eq 1 ]]; then
    claude_args+=(--verbose)
  fi
  if [[ "$persist" -eq 0 ]]; then
    claude_args+=(--no-session-persistence)
  fi
  if [[ -n "$model" ]]; then
    claude_args+=(--model "$model")
  fi
  if [[ -n "$effort" ]]; then
    claude_args+=(--effort "$effort")
  fi
  if [[ -n "$schema" ]]; then
    if [[ -f "$schema" ]]; then
      claude_args+=(--json-schema "$(cat "$schema")")
    else
      claude_args+=(--json-schema "$schema")
    fi
  fi
  if [[ -n "$allow_tools" ]]; then
    warn_if_mutating_tools "$allow_tools"
    claude_args+=(--allowedTools "$allow_tools")
  fi
  if [[ -n "$session_id" ]]; then
    claude_args+=(--session-id "$session_id")
  fi
  if [[ -n "$resume_value" ]]; then
    if [[ "$resume_value" == "__latest__" ]]; then
      claude_args+=(--resume)
    else
      claude_args+=(--resume "$resume_value")
    fi
  fi
  if [[ "$continue_recent" -eq 1 ]]; then
    claude_args+=(--continue)
  fi
  if [[ "$bare" -eq 1 ]]; then
    claude_args+=(--bare)
  fi

  if [[ "$async" -eq 1 ]]; then
    local tmp_prompt
    tmp_prompt="$(mktemp)"
    printf '%s' "$prompt" >"$tmp_prompt"
    local run_id
    run_id="$(python3 "${script_dir}/claude_cli_async.py" start --stdin-file "$tmp_prompt" "${async_args[@]+"${async_args[@]}"}" -- "${claude_args[@]}")"
    rm -f "$tmp_prompt"
    echo "$run_id"
    if [[ -n "$wait_timeout" ]]; then
      python3 "${script_dir}/claude_cli_async.py" wait "$run_id" --timeout "$wait_timeout" >&2 || true
    fi
  else
    run_sync_consult "$prompt" "$retry_on_budget" "$retry_budget" "$retry_output_words" "$retry_input_chars" "${claude_args[@]}"
  fi
}

case "${1:-}" in
  --check)
    check_config
    echo "Claude CLI configuration looks usable."
    ;;
  --print-config)
    print_config
    ;;
  --help-wrapper|--help)
    usage
    ;;
  consult)
    shift
    if [[ $# -gt 0 && "${1:-}" != "--help" && "${1:-}" != "--list-templates" ]]; then
      check_config
    fi
    consult "$@"
    ;;
  start)
    check_config
    shift
    run_async start "$@"
    ;;
  status|wait|logs|result|cancel|list)
    cmd="$1"
    shift
    run_async "$cmd" "$@"
    ;;
  *)
    check_config
    exec "$(claude_bin)" "$@"
    ;;
esac
