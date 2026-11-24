"""Every test run gets its own POINT_TAKEN_HOME and POINT_TAKEN_WORKSPACE before any test module is imported.

_common.py (and transcribe.py, which copies it) reads $POINT_TAKEN_HOME once, at import: a module collected early that
imported a script without the variable set left the whole session pointed at the real ~/.point-taken — the full suite was
writing jobs/*.events.jsonl, config.json and run/ files there (seen in the v0.7 end-to-end run). Tests that need a
fresh home still make their own; this is only the floor.
"""
import os
import tempfile

_root = tempfile.mkdtemp(prefix="point-taken-tests-")
os.environ["POINT_TAKEN_HOME"] = os.path.join(_root, "home")
os.environ["POINT_TAKEN_WORKSPACE"] = os.path.join(_root, "ws")
os.makedirs(os.environ["POINT_TAKEN_HOME"], exist_ok=True)
os.makedirs(os.environ["POINT_TAKEN_WORKSPACE"], exist_ok=True)

# The scripts' child processes in UTF-8 mode, as the Windows app runs them (ScriptRunner.cs: PYTHONUTF8=1): without it a
# child on a Chinese Windows reads and writes files and pipes in the code page (GBK). Tests open files as UTF-8 themselves.
os.environ.setdefault("PYTHONUTF8", "1")

# Cloud keys from the developer's own shell (DASHSCOPE_API_KEY, OPENAI_API_KEY, the Volcengine pair …): with one set,
# model choice offered and picked that cloud service (qwen3-asr-flash instead of macOS's recogniser) and a slip could
# send a request on the developer's account. Tests that need a key set their own.
for _name in [n for n in os.environ if n.upper().endswith("_API_KEY") or n.upper().startswith("VOLC_")]:
    del os.environ[_name]


def pytest_configure(config):
    # opt-in GUI tests (they open the app's windows on screen): POINT_TAKEN_GUI_TESTS=1, see tests/test_gui_layout.py
    config.addinivalue_line("markers", "gui: opens the app's windows on screen; skipped unless POINT_TAKEN_GUI_TESTS=1")
