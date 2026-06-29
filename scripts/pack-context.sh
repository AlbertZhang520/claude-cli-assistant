#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/lib/redact.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/pack-context.sh [options]

Options:
  --status              Include git status. Enabled by default when no section is selected.
  --diff [range]        Include git diff. Enabled by default when no section is selected.
  --staged              Use staged diff instead of working-tree diff.
  --file <path>         Include a file excerpt. May be repeated.
  --log <path>          Include command/log output from a file. May be repeated.
  --max-lines <n>       Max lines per --file/--log excerpt. Default: 220.
  --max-bytes <n>       Max bytes in final redacted packet. Default: 120000.
  --output <path>       Write packet to path instead of stdout.

The packet is read-only and redacted for common secret patterns.
EOF
}

include_status=0
include_diff=0
staged=0
diff_range=""
max_lines=220
max_bytes=120000
output=""
files=()
logs=()
selected=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --status)
      include_status=1
      selected=1
      shift
      ;;
    --diff)
      include_diff=1
      selected=1
      shift
      if [[ $# -gt 0 && "${1:0:2}" != "--" ]]; then
        diff_range="$1"
        shift
      fi
      ;;
    --staged)
      staged=1
      selected=1
      shift
      ;;
    --file)
      [[ $# -ge 2 ]] || { echo "--file requires a path" >&2; exit 2; }
      files+=("$2")
      selected=1
      shift 2
      ;;
    --log)
      [[ $# -ge 2 ]] || { echo "--log requires a path" >&2; exit 2; }
      logs+=("$2")
      selected=1
      shift 2
      ;;
    --max-lines)
      [[ $# -ge 2 ]] || { echo "--max-lines requires a value" >&2; exit 2; }
      max_lines="$2"
      shift 2
      ;;
    --max-bytes)
      [[ $# -ge 2 ]] || { echo "--max-bytes requires a value" >&2; exit 2; }
      max_bytes="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$selected" -eq 0 ]]; then
  include_status=1
  include_diff=1
fi

if [[ "$staged" -eq 1 && -n "$diff_range" ]]; then
  echo "--staged cannot be combined with --diff <range>" >&2
  exit 2
fi

if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  is_git_repo=1
else
  repo_root="$(pwd)"
  is_git_repo=0
fi

tmp="$(mktemp)"
redacted_tmp="$(mktemp)"
trap 'rm -f "$tmp" "$redacted_tmp"' EXIT

section() {
  {
    echo
    echo "## $1"
    echo
  } >>"$tmp"
}

append_cmd() {
  local title="$1"
  shift
  section "$title"
  {
    echo '```text'
    "$@" 2>&1 || true
    echo '```'
  } >>"$tmp"
}

append_file() {
  local title="$1"
  local path="$2"
  section "$title"
  {
    echo '```text'
    if [[ -f "$path" ]]; then
      nl -ba "$path" | sed -n "1,${max_lines}p"
    else
      echo "Missing file: $path"
    fi
    echo '```'
  } >>"$tmp"
}

append_untracked_files() {
  [[ "$is_git_repo" -eq 1 ]] || return 0
  local found=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if [[ "$found" -eq 0 ]]; then
      section "Untracked Files"
      echo '```text' >>"$tmp"
      found=1
    fi
    echo "$file" >>"$tmp"
  done < <(git -C "$repo_root" ls-files --others --exclude-standard)

  if [[ "$found" -eq 1 ]]; then
    echo '```' >>"$tmp"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      [[ -f "${repo_root}/${file}" ]] || continue
      append_file "Untracked File: ${file}" "${repo_root}/${file}"
    done < <(git -C "$repo_root" ls-files --others --exclude-standard)
  fi
}

{
  echo "# Claude CLI Context Packet"
  echo
  echo "- Generated at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- Repository: $(basename "$repo_root")"
} >>"$tmp"

if [[ "$include_status" -eq 1 ]]; then
  if [[ "$is_git_repo" -eq 1 ]]; then
    append_cmd "Git Status" git -C "$repo_root" status --short --branch
  else
    section "Git Status"
    {
      echo '```text'
      echo "Not a git repository."
      echo '```'
    } >>"$tmp"
  fi
fi

if [[ "$include_diff" -eq 1 || "$staged" -eq 1 ]]; then
  if [[ "$is_git_repo" -eq 0 ]]; then
    section "Git Diff"
    {
      echo '```text'
      echo "Not a git repository."
      echo '```'
    } >>"$tmp"
  elif [[ "$staged" -eq 1 ]]; then
    append_cmd "Git Diff Stat (staged)" git -C "$repo_root" diff --staged --stat
    append_untracked_files
    append_cmd "Git Diff (staged)" git -C "$repo_root" diff --staged --unified=80
  elif [[ -n "$diff_range" ]]; then
    append_cmd "Git Diff Stat (${diff_range})" git -C "$repo_root" diff --stat "$diff_range"
    append_untracked_files
    append_cmd "Git Diff (${diff_range})" git -C "$repo_root" diff --unified=80 "$diff_range"
  else
    append_cmd "Git Diff Stat" git -C "$repo_root" diff --stat
    append_untracked_files
    append_cmd "Git Diff" git -C "$repo_root" diff --unified=80
  fi
fi

for file in "${files[@]+"${files[@]}"}"; do
  if [[ "$file" = /* ]]; then
    append_file "File: ${file}" "$file"
  else
    append_file "File: ${file}" "${repo_root}/${file}"
  fi
done

for log in "${logs[@]+"${logs[@]}"}"; do
  append_file "Log: ${log}" "$log"
done

redact_stream <"$tmp" >"$redacted_tmp"

total_bytes="$(wc -c <"$redacted_tmp" | tr -d ' ')"
if [[ "$total_bytes" -gt "$max_bytes" ]]; then
  {
    head -c "$max_bytes" "$redacted_tmp"
    echo
    echo
    echo "[TRUNCATED: context packet exceeded ${max_bytes} bytes after redaction]"
  } >"${redacted_tmp}.truncated"
  mv "${redacted_tmp}.truncated" "$redacted_tmp"
fi

if [[ -n "$output" ]]; then
  mkdir -p "$(dirname "$output")"
  cp "$redacted_tmp" "$output"
else
  cat "$redacted_tmp"
fi
