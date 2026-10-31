"""Offline source-whitelist and fail-closed checks; does not import the gateway."""
import ast
import hashlib
from pathlib import Path
from types import SimpleNamespace

source = Path(__file__).with_name("compat.py").read_text()
compile(source, "compat.py", "exec")
namespace = {"hashlib": hashlib, "inspect": SimpleNamespace(
    getsource=lambda obj: "previous reload wrapper", unwrap=lambda obj: obj)}
for node in ast.parse(source).body:
    if (isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id.endswith(
                ("_TARGET_FINGERPRINTS", "_V022_FINGERPRINTS")) for t in node.targets)
            or isinstance(node, ast.FunctionDef) and node.name in (
                "_cron_fingerprint", "_wake_fingerprint", "_steer_fingerprint")):
        exec(compile(ast.Module(body=[node], type_ignores=[]), "compat.py", "exec"), namespace)
root = Path("/Users/zaber/.hermes/hermes-agent")
digests = {}
for path in ("cron/scheduler_delivery.py", "hermes_state_messages.py", "hermes_state.py",
             "hermes_state_compression.py", "agent/tool_executor.py",
             "agent/session_persistence.py", "agent/agent_runtime_helpers.py"):
    text = (root / path).read_text()
    lines = text.splitlines(keepends=True)
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            digests[node.name] = hashlib.sha256(
                "".join(lines[node.lineno - 1:node.end_lineno]).encode()).hexdigest()
count = 0
for prefix in ("CRON", "WAKE", "STEER"):
    table = namespace[prefix + "_V022_FINGERPRINTS"]
    for name, expected in table.items():
        assert digests[name] == expected, name
        count += 1
    name = next(iter(table))
    target = SimpleNamespace(**{name: lambda: None})
    gate = namespace["_" + prefix.lower() + "_fingerprint"]
    namespace["_BACKEND"] = "v022"
    namespace["_disk_digest"] = lambda *args: table[name]
    gate(target, name)
    namespace["_disk_digest"] = lambda *args: "unreviewed"
    for backend in ("v022", "unknown"):
        namespace["_BACKEND"] = backend
        try:
            gate(target, name)
        except RuntimeError:
            pass
        else:
            raise AssertionError("accepted unreviewed source/backend")
print(f"PASS syntax; {count} v022 digests; 3 disk fallbacks; 6 fail-closed checks")
