"""Only migrations may set the message key.

Every message body is encrypted with one key. Migration 0078 creates it; migration 0151's
_messages_rotate_key() replaces it and re-encrypts every message in the same transaction. Any other
writer swaps the key without re-encrypting, and every earlier message becomes unreadable. An ops
script that did exactly that (ops/configure_messages_key.py) sat in this repository with a guard that
looked only at app.messages_key, while production keeps its key in app_private_settings.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Where the key may legitimately be written: the migrations, and the CI checks that prove them.
ALLOWED = {REPO / "supabase" / "migrations", REPO / "supabase" / "ci"}
SKIP_DIRS = {".git", "node_modules", ".next", "context", ".venv", "__pycache__"}
CODE = {".py", ".sh", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".ps1", ".sql"}

WRITES_KEY = re.compile(
    r"set\s+app\.messages_key"
    r"|set_config\s*\(\s*'app\.messages_key'"
    r"|(insert\s+into|update|delete\s+from)\s+(public\.)?app_private_settings",
    re.IGNORECASE,
)


def _code_files(root: Path):
    for path in root.iterdir():
        if path.is_dir():
            if path.name in SKIP_DIRS or path in ALLOWED:
                continue
            yield from _code_files(path)
        elif path.suffix in CODE and path != Path(__file__).resolve():
            yield path


def test_nothing_outside_migrations_writes_the_message_key() -> None:
    offenders = [
        f"{path.relative_to(REPO)}: {match.group(0)!r}"
        for path in _code_files(REPO)
        for match in [WRITES_KEY.search(path.read_text(encoding="utf-8", errors="ignore"))]
        if match
    ]
    assert offenders == [], (
        "Only a migration may set the message key (rotate with public._messages_rotate_key):\n"
        + "\n".join(offenders)
    )
