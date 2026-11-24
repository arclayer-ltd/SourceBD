"""The server's scheduled jobs: one file lists them, and the deploy installs exactly that list (#661)."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEDULE = ROOT / "ops" / "schedule.cron"
INSTALL = ROOT / "ops" / "install_schedule.sh"
BEGIN = "# >>> SourceBD schedule"
END = "# <<< SourceBD schedule"


def _jobs() -> list[str]:
    return [
        ln.strip()
        for ln in SCHEDULE.read_text(encoding="utf-8").splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]


def _fake_crontab(tmp: Path, existing: str | None) -> tuple[dict[str, str], Path]:
    """A `crontab` on PATH that keeps the table in a file, so no real crontab is read or written."""
    store = tmp / "table"
    if existing is not None:
        store.write_text(existing, encoding="utf-8")
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "crontab"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        f'store="{store}"\n'
        'if [ "$1" = "-l" ]; then [ -f "$store" ] || { echo "no crontab for $(id -un)" >&2; exit 1; }; cat "$store"; exit 0; fi\n'
        'if [ "$1" = "-" ]; then cat > "$store"; exit 0; fi\n'
        'echo "fake crontab: unexpected $*" >&2; exit 2\n',
        encoding="utf-8",
    )
    fake.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}
    return env, store


def _install(app_dir: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(INSTALL), str(app_dir)], env=env, capture_output=True, text=True, check=False
    )


def _app_dir(tmp: Path) -> Path:
    app = tmp / "app"
    (app / "ops").mkdir(parents=True)
    (app / "ops" / "schedule.cron").write_text(SCHEDULE.read_text(encoding="utf-8"), encoding="utf-8")
    return app


def test_the_schedule_lists_every_job_script_and_only_scripts_that_exist() -> None:
    listed = {m.group(1) for job in _jobs() for m in re.finditer(r"/ops/([a-z_]+_cron\.sh)", job)}
    on_disk = {p.name for p in (ROOT / "ops").glob("*_cron.sh")}
    assert listed == on_disk

    for job in _jobs():
        fields = job.split(None, 5)
        assert len(fields) == 6, job
        command = fields[5]
        # Run through bash so a script without its executable bit still runs, and log into etl/logs.
        assert command.startswith('bash "$SOURCEBD_APP_DIR/ops/'), job
        assert re.search(r'>> "\$SOURCEBD_APP_DIR/etl/logs/[a-z_]+\.log" 2>&1$', command), job
        assert "%" not in command, job  # cron would cut the command at an unescaped %


def test_the_ledger_job_is_scheduled_for_both_seal_and_stamp() -> None:
    ledger = [job for job in _jobs() if "ledger_cron.sh" in job]
    assert sorted(re.search(r'ledger_cron\.sh" (\w+) ', job).group(1) for job in ledger) == ["seal", "stamp"]


def test_install_puts_exactly_the_list_in_place_and_keeps_what_is_not_ours(tmp_path: Path) -> None:
    app = _app_dir(tmp_path)
    existing = (
        "MAILTO=ops@example.invalid\n"
        "30 2 * * * /usr/local/bin/backup.sh\n"
        # Installed by hand or by an older deploy: would run the job a second time if kept.
        "* * * * * /opt/sourcebd/ops/scraper_queue_cron.sh >> /opt/sourcebd/etl/logs/scraper_queue_cron.log 2>&1\n"
        f"{BEGIN}: installed by an earlier deploy\n"
        "0 * * * * bash /old/ops/retired_job_cron.sh\n"
        f"{END}\n"
    )
    env, store = _fake_crontab(tmp_path, existing)

    result = _install(app, env)
    assert result.returncode == 0, result.stderr

    lines = store.read_text(encoding="utf-8").splitlines()
    assert lines[:2] == ["MAILTO=ops@example.invalid", "30 2 * * * /usr/local/bin/backup.sh"]
    block = lines[2:]
    assert block[0].startswith(BEGIN) and block[-1] == END
    assert block[1] == f"SOURCEBD_APP_DIR={app}"
    assert block[2:-1] == _jobs()
    assert sum(1 for ln in lines if ln.startswith(BEGIN)) == 1
    assert "retired_job_cron.sh" not in store.read_text(encoding="utf-8")
    assert (app / "etl" / "logs").is_dir()
    for job in _jobs():
        assert job in result.stdout


def test_install_twice_changes_nothing(tmp_path: Path) -> None:
    app = _app_dir(tmp_path)
    env, store = _fake_crontab(tmp_path, None)  # a user with no crontab yet

    assert _install(app, env).returncode == 0
    first = store.read_text(encoding="utf-8")
    assert _install(app, env).returncode == 0
    assert store.read_text(encoding="utf-8") == first
    assert first.splitlines()[0].startswith(BEGIN)


def test_install_fails_loudly_without_the_list(tmp_path: Path) -> None:
    app = tmp_path / "app"
    app.mkdir()
    env, store = _fake_crontab(tmp_path, "30 2 * * * /usr/local/bin/backup.sh\n")

    result = _install(app, env)
    assert result.returncode != 0
    assert "schedule.cron not found" in result.stderr
    assert store.read_text(encoding="utf-8") == "30 2 * * * /usr/local/bin/backup.sh\n"


def test_the_deploy_installs_the_schedule_after_checking_out_the_commit() -> None:
    remote = (ROOT / "ops" / "gha_vps_deploy.sh").read_text(encoding="utf-8")
    deploy_at = remote.index('bash "$_deploy" --ref="${DEPLOY_REF}"')
    install = 'if [ -f ops/install_schedule.sh ]; then bash ops/install_schedule.sh "$REPO_DIR"; fi'
    assert install in remote
    assert remote.index(install) > deploy_at
