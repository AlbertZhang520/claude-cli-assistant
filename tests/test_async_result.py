#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path


module_path = Path(__file__).resolve().parents[1] / "scripts" / "claude_cli_async.py"
spec = importlib.util.spec_from_file_location("claude_cli_async", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def assert_equal(actual, expected):
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


json_result = json.dumps({
    "type": "result",
    "result": "prefix\nBEGIN_RESULT\nline1\nline2\nEND_RESULT\nsuffix",
})
assert_equal(module.extract_result_text(json_result), "line1\nline2")

structured = json.dumps({"structured_output": {"ok": True, "items": [1, 2]}})
assert_equal(module.extract_result_text(structured), '{\n  "items": [\n    1,\n    2\n  ],\n  "ok": true\n}')

stream = "\n".join([
    json.dumps({"type": "assistant", "message": "ignored"}),
    json.dumps({"type": "result", "result": "BEGIN_RESULT\nstream-ok\nEND_RESULT"}),
])
assert_equal(module.extract_result_text(stream), "stream-ok")

plain = "BEGIN_RESULT\nplain-ok\nEND_RESULT"
assert_equal(module.extract_result_text(plain), "plain-ok")

json_result_no_block = json.dumps({"type": "result", "result": "plain-json-result"})
assert_equal(module.extract_result_text(json_result_no_block), "plain-json-result")

stream_no_block = "\n".join([
    json.dumps({"type": "assistant", "message": "ignored"}),
    json.dumps({"type": "result", "result": "plain-stream-result"}),
])
assert_equal(module.extract_result_text(stream_no_block), "plain-stream-result")

assert_equal(module.extract_result_text('{"type":"assistant","message":"no result"}'), '{"type":"assistant","message":"no result"}')

assert_equal(module.terminal_exit_code("succeeded"), 0)
assert_equal(module.terminal_exit_code("idle_timeout"), 124)
assert_equal(module.terminal_exit_code("timed_out"), 125)
assert_equal(module.terminal_exit_code("cancelled"), 130)

print("async result tests ok")
