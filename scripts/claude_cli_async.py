#!/usr/bin/env python3
import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


TERMINAL_STATES = {"succeeded", "failed", "timed_out", "idle_timeout", "cancelled", "launch_error"}
BEGIN_RESULT = "BEGIN_RESULT"
END_RESULT = "END_RESULT"


def now() -> float:
    return time.time()


def iso(ts: Optional[float] = None) -> str:
    return datetime.fromtimestamp(now() if ts is None else ts, timezone.utc).isoformat().replace("+00:00", "Z")


def repo_dir() -> Path:
    return Path(__file__).resolve().parents[1]


def runs_root() -> Path:
    return Path(os.environ.get("CLAUDE_CLI_RUNS_DIR", repo_dir() / ".claude-cli" / "runs")).expanduser()


def run_dir(run_id: str) -> Path:
    return runs_root() / run_id


def atomic_write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_iso_ts(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def status_path(path: Path) -> Path:
    return path / "status.json"


def terminal_exit_code(state: str, claude_code: Optional[int] = None) -> int:
    if state == "succeeded":
        return 0
    if state == "idle_timeout":
        return 124
    if state == "timed_out":
        return 125
    if state == "cancelled":
        return 130
    if state == "launch_error":
        return 127
    if claude_code is not None:
        return claude_code if claude_code != 0 else 1
    return 1


def update_status(path: Path, **updates) -> dict:
    data = {}
    sp = status_path(path)
    if sp.exists():
        data = read_json(sp)
    data.update(updates)
    atomic_write_json(sp, data)
    return data


def status_snapshot(path: Path, persist: bool = False) -> dict:
    data = read_json(status_path(path))
    if data.get("state") in TERMINAL_STATES:
        return data

    current = now()
    updates = {}
    started_ts = parse_iso_ts(data.get("started_at"))
    last_activity_ts = parse_iso_ts(data.get("last_activity_at"))
    if started_ts is not None:
        updates["elapsed_s"] = round(current - started_ts, 3)
    if last_activity_ts is not None:
        updates["idle_s"] = round(current - last_activity_ts, 3)
    if updates:
        data.update(updates)
        if persist:
            update_status(path, **updates)
    return data


def print_json(data: dict) -> None:
    print(json.dumps(data, indent=2, sort_keys=True))


def extract_result_text(text: str) -> str:
    stripped = text.strip()
    if not stripped:
        return ""

    def extract_block(value: str) -> str:
        start = value.find(BEGIN_RESULT)
        if start < 0:
            return ""
        body_start = start + len(BEGIN_RESULT)
        end = value.find(END_RESULT, body_start)
        if end >= 0:
            return value[body_start:end].strip()
        return value[body_start:].strip()

    try:
        data = json.loads(stripped)
        if isinstance(data, dict):
            if data.get("structured_output") is not None:
                structured = json.dumps(data["structured_output"], indent=2, sort_keys=True)
                return extract_block(structured) or structured
            if data.get("result") is not None:
                result = str(data["result"]).strip()
                return extract_block(result) or result
    except json.JSONDecodeError:
        pass

    result = ""
    for line in stripped.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and data.get("type") == "result" and data.get("result") is not None:
            result = str(data["result"]).strip()
    if result:
        return extract_block(result) or result

    return extract_block(stripped) or stripped


def kill_process_group(pid: int, grace_s: int) -> None:
    try:
        os.killpg(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return

    deadline = now() + grace_s
    while now() < deadline:
        try:
            os.killpg(pid, 0)
        except (ProcessLookupError, PermissionError):
            return
        time.sleep(0.2)

    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        return


def append_event(path: Path, event: dict) -> None:
    event = {"ts": iso(), **event}
    with (path / "events.log").open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")


def start(args: argparse.Namespace) -> int:
    if args.claude_args and args.claude_args[0] == "--":
        args.claude_args = args.claude_args[1:]
    if not args.claude_args:
        print("start requires Claude CLI arguments, for example: start -- -p --output-format json", file=sys.stderr)
        return 2

    rid = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    path = run_dir(rid)
    path.mkdir(parents=True, exist_ok=False)

    stdin_path = None
    if args.stdin_file:
        src = Path(args.stdin_file).expanduser()
        if not src.exists():
            print(f"stdin file does not exist: {src}", file=sys.stderr)
            return 2
        stdin_path = path / "stdin.txt"
        stdin_path.write_bytes(src.read_bytes())

    meta = {
        "run_id": rid,
        "created_at": iso(),
        "cwd": os.getcwd(),
        "claude_bin": os.environ.get("CLAUDE_CLI_BIN", "claude"),
        "claude_args": args.claude_args,
        "stdin_path": str(stdin_path) if stdin_path else None,
        "max_wall_s": args.max_wall,
        "idle_timeout_s": args.idle_timeout,
        "heartbeat_s": args.heartbeat,
        "grace_s": args.grace,
    }
    atomic_write_json(path / "meta.json", meta)
    atomic_write_json(status_path(path), {
        "run_id": rid,
        "state": "starting",
        "started_at": meta["created_at"],
        "last_activity_at": meta["created_at"],
        "elapsed_s": 0,
        "idle_s": 0,
        "exit_code": None,
        "reason": None,
    })

    supervisor = [sys.executable, str(Path(__file__).resolve()), "_supervise", rid]
    supervisor_log = (path / "supervisor.log").open("ab")
    proc = subprocess.Popen(
        supervisor,
        cwd=os.getcwd(),
        env=os.environ.copy(),
        stdin=subprocess.DEVNULL,
        stdout=supervisor_log,
        stderr=supervisor_log,
        start_new_session=True,
    )
    supervisor_log.close()
    (path / "supervisor.pid").write_text(str(proc.pid) + "\n", encoding="utf-8")
    print(rid)
    return 0


def supervise(args: argparse.Namespace) -> int:
    path = run_dir(args.run_id)
    meta = read_json(path / "meta.json")
    claude_cmd = [meta.get("claude_bin") or "claude", *meta["claude_args"]]
    started = now()
    last_activity = started
    last_heartbeat = started
    stdout_path = path / "stdout.log"
    stderr_path = path / "stderr.log"
    heartbeat_s = int(meta["heartbeat_s"])
    idle_timeout_s = int(meta["idle_timeout_s"])
    max_wall_s = int(meta["max_wall_s"])
    grace_s = int(meta["grace_s"])

    append_event(path, {"event": "launch", "cmd": claude_cmd})
    stdin_fh = None
    try:
        if meta.get("stdin_path"):
            stdin_fh = open(meta["stdin_path"], "rb")
        proc = subprocess.Popen(
            claude_cmd,
            cwd=meta["cwd"],
            env=os.environ.copy(),
            stdin=stdin_fh if stdin_fh is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError:
        update_status(
            path,
            state="launch_error",
            finished_at=iso(),
            elapsed_s=round(now() - started, 3),
            idle_s=0,
            exit_code=127,
            reason="claude binary not found",
        )
        append_event(path, {"event": "launch_error", "reason": "claude binary not found"})
        return 127
    finally:
        if stdin_fh is not None:
            stdin_fh.close()

    (path / "pid").write_text(str(proc.pid) + "\n", encoding="utf-8")
    update_status(path, state="running", pid=proc.pid, started_at=iso(started), last_activity_at=iso(last_activity))

    selector = selectors.DefaultSelector()
    assert proc.stdout is not None and proc.stderr is not None
    selector.register(proc.stdout, selectors.EVENT_READ, ("stdout", stdout_path))
    selector.register(proc.stderr, selectors.EVENT_READ, ("stderr", stderr_path))

    terminal_state: Optional[str] = None
    terminal_reason: Optional[str] = None
    terminal_code: Optional[int] = None

    def record_activity(stream_name: str, log_path: Path, chunk: bytes) -> None:
        nonlocal last_activity
        if chunk:
            with log_path.open("ab") as fh:
                fh.write(chunk)
            last_activity = now()
            update_status(path, last_activity_at=iso(last_activity))
            append_event(path, {"event": "activity", "stream": stream_name, "bytes": len(chunk)})

    try:
        while True:
            for key, _ in selector.select(timeout=0.5):
                stream_name, log_path = key.data
                chunk = os.read(key.fileobj.fileno(), 8192)
                if chunk:
                    record_activity(stream_name, log_path, chunk)
                else:
                    selector.unregister(key.fileobj)

            elapsed = now() - started
            idle = now() - last_activity
            if now() - last_heartbeat >= heartbeat_s:
                append_event(path, {"event": "heartbeat", "elapsed_s": round(elapsed, 3), "idle_s": round(idle, 3)})
                update_status(path, elapsed_s=round(elapsed, 3), idle_s=round(idle, 3))
                last_heartbeat = now()

            if max_wall_s > 0 and elapsed >= max_wall_s:
                terminal_state = "timed_out"
                terminal_reason = f"max wall-clock timeout exceeded ({max_wall_s}s)"
                terminal_code = 125
                kill_process_group(proc.pid, grace_s)
                break

            if idle_timeout_s > 0 and idle >= idle_timeout_s:
                terminal_state = "idle_timeout"
                terminal_reason = f"idle timeout exceeded ({idle_timeout_s}s without output)"
                terminal_code = 124
                kill_process_group(proc.pid, grace_s)
                break

            rc = proc.poll()
            if rc is not None:
                terminal_code = rc
                terminal_state = "succeeded" if rc == 0 else "failed"
                terminal_reason = "claude exited successfully" if rc == 0 else f"claude exited with code {rc}"
                break

        for stream_name, log_path, pipe in (("stdout", stdout_path, proc.stdout), ("stderr", stderr_path, proc.stderr)):
            if pipe is not None:
                try:
                    while True:
                        chunk = os.read(pipe.fileno(), 8192)
                        if not chunk:
                            break
                        record_activity(stream_name, log_path, chunk)
                except OSError:
                    pass
    finally:
        selector.close()

    finished = now()
    exit_code = terminal_exit_code(terminal_state or "failed", terminal_code)
    existing = read_json(status_path(path))
    if existing.get("state") == "cancelled":
        append_event(path, {"event": "finish_after_cancel", "exit_code": 130})
        return 130
    if stdout_path.exists():
        result_text = extract_result_text(stdout_path.read_text(encoding="utf-8", errors="replace"))
        if result_text:
            (path / "result.txt").write_text(result_text + "\n", encoding="utf-8")
    update_status(
        path,
        state=terminal_state or "failed",
        finished_at=iso(finished),
        elapsed_s=round(finished - started, 3),
        idle_s=round(finished - last_activity, 3),
        exit_code=exit_code,
        reason=terminal_reason or "unknown failure",
    )
    append_event(path, {"event": "finish", "state": terminal_state, "exit_code": exit_code, "reason": terminal_reason})
    return exit_code


def status(args: argparse.Namespace) -> int:
    path = run_dir(args.run_id)
    if not status_path(path).exists():
        print(f"unknown run_id: {args.run_id}", file=sys.stderr)
        return 2
    print_json(status_snapshot(path, persist=True))
    return 0


def wait_run(args: argparse.Namespace) -> int:
    deadline = now() + args.timeout
    path = run_dir(args.run_id)
    if not status_path(path).exists():
        print(f"unknown run_id: {args.run_id}", file=sys.stderr)
        return 2

    while True:
        data = status_snapshot(path)
        if data.get("state") in TERMINAL_STATES:
            print_json(data)
            return int(data.get("exit_code") or terminal_exit_code(data["state"]))
        if now() >= deadline:
            print_json(data)
            return 0
        time.sleep(0.5)


def output_file(path: Path, follow: bool, tail: Optional[int]) -> int:
    if not path.exists():
        return 0
    if tail is not None:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for line in lines[-tail:]:
            print(line)
    else:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            sys.stdout.write(fh.read())
    if follow:
        pos = path.stat().st_size
        while True:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                fh.seek(pos)
                data = fh.read()
                if data:
                    sys.stdout.write(data)
                    sys.stdout.flush()
                    pos = fh.tell()
            sp = status_path(path.parent)
            if sp.exists():
                state = read_json(sp).get("state")
                if state in TERMINAL_STATES:
                    return 0
            time.sleep(1)
    return 0


def logs(args: argparse.Namespace) -> int:
    path = run_dir(args.run_id)
    if not path.exists():
        print(f"unknown run_id: {args.run_id}", file=sys.stderr)
        return 2
    name = "events.log" if args.events else "stderr.log" if args.stderr else "stdout.log"
    return output_file(path / name, args.follow, args.tail)


def result(args: argparse.Namespace) -> int:
    path = run_dir(args.run_id)
    if not status_path(path).exists():
        print(f"unknown run_id: {args.run_id}", file=sys.stderr)
        return 2

    data = status_snapshot(path, persist=True)
    result_path = path / "result.txt"
    stdout_path = path / "stdout.log"
    text = ""
    if result_path.exists() and not args.raw:
        text = result_path.read_text(encoding="utf-8", errors="replace").strip()
    elif stdout_path.exists():
        text = stdout_path.read_text(encoding="utf-8", errors="replace")
        if not args.raw:
            text = extract_result_text(text)
        text = text.strip()

    if args.json:
        print_json({
            "run_id": args.run_id,
            "state": data.get("state"),
            "exit_code": data.get("exit_code"),
            "result": text,
        })
    elif text:
        print(text)

    if args.status_code and data.get("state") in TERMINAL_STATES:
        return int(data.get("exit_code") or terminal_exit_code(data["state"]))
    return 0


def cancel(args: argparse.Namespace) -> int:
    path = run_dir(args.run_id)
    if not status_path(path).exists():
        print(f"unknown run_id: {args.run_id}", file=sys.stderr)
        return 2
    data = read_json(status_path(path))
    if data.get("state") in TERMINAL_STATES:
        print_json(data)
        return int(data.get("exit_code") or 0)
    pid = data.get("pid")
    if pid:
        kill_process_group(int(pid), args.grace)
    finished = now()
    updated = update_status(path, state="cancelled", finished_at=iso(finished), exit_code=130, reason="cancelled by user")
    append_event(path, {"event": "cancel", "reason": "cancelled by user"})
    print_json(updated)
    return 130


def list_runs(args: argparse.Namespace) -> int:
    root = runs_root()
    if not root.exists():
        return 0
    rows = []
    for sp in sorted(root.glob("*/status.json"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            data = read_json(sp)
        except Exception:
            continue
        rows.append({
            "run_id": data.get("run_id"),
            "state": data.get("state"),
            "started_at": data.get("started_at"),
            "finished_at": data.get("finished_at"),
            "exit_code": data.get("exit_code"),
            "reason": data.get("reason"),
        })
        if len(rows) >= args.limit:
            break
    print_json({"runs": rows})
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Async runner for Claude CLI wrapper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("start")
    p.add_argument("--max-wall", type=int, default=int(os.environ.get("CLAUDE_CLI_MAX_WALL", "600")))
    p.add_argument("--idle-timeout", type=int, default=int(os.environ.get("CLAUDE_CLI_IDLE_TIMEOUT", "120")))
    p.add_argument("--heartbeat", type=int, default=int(os.environ.get("CLAUDE_CLI_HEARTBEAT", "15")))
    p.add_argument("--grace", type=int, default=int(os.environ.get("CLAUDE_CLI_KILL_GRACE", "10")))
    p.add_argument("--stdin-file")
    p.add_argument("claude_args", nargs=argparse.REMAINDER)
    p.set_defaults(func=start)

    p = sub.add_parser("_supervise")
    p.add_argument("run_id")
    p.set_defaults(func=supervise)

    p = sub.add_parser("status")
    p.add_argument("run_id")
    p.set_defaults(func=status)

    p = sub.add_parser("wait")
    p.add_argument("run_id")
    p.add_argument("--timeout", type=int, default=30)
    p.set_defaults(func=wait_run)

    p = sub.add_parser("logs")
    p.add_argument("run_id")
    p.add_argument("--stderr", action="store_true")
    p.add_argument("--events", action="store_true")
    p.add_argument("--follow", action="store_true")
    p.add_argument("--tail", type=int)
    p.set_defaults(func=logs)

    p = sub.add_parser("result")
    p.add_argument("run_id")
    p.add_argument("--raw", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--status-code", action="store_true", help="exit with the run's terminal status code")
    p.set_defaults(func=result)

    p = sub.add_parser("cancel")
    p.add_argument("run_id")
    p.add_argument("--grace", type=int, default=int(os.environ.get("CLAUDE_CLI_KILL_GRACE", "10")))
    p.set_defaults(func=cancel)

    p = sub.add_parser("list")
    p.add_argument("--limit", type=int, default=20)
    p.set_defaults(func=list_runs)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
