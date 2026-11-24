#!/usr/bin/env bash
# Installs ops/schedule.cron as the server's scheduled jobs. The deploy runs it after every deploy
# (ops/gha_vps_deploy.sh), so the jobs on the server are always exactly the list in the deployed commit.
#
#   bash ops/install_schedule.sh [APP_DIR]     APP_DIR defaults to $SOURCEBD_APP_DIR, then /opt/sourcebd
#
# The jobs go in the crontab of the user running it, between two marker lines. Everything else in that
# crontab is kept, except a line that runs one of the ops/*_cron.sh scripts outside the markers (put there
# by hand or by an older deploy): left in, it would run that job twice. It prints what is installed.
set -euo pipefail

APP_DIR="${1:-${SOURCEBD_APP_DIR:-/opt/sourcebd}}"
SCHEDULE="$APP_DIR/ops/schedule.cron"
# The markers are found by these prefixes, so the wording after them can change without stranding an old block.
BEGIN_MARK="# >>> SourceBD schedule"
END_MARK="# <<< SourceBD schedule"
BEGIN="$BEGIN_MARK: installed by each deploy from ops/schedule.cron. Change that file, not these lines."
END="$END_MARK"

[ -f "$SCHEDULE" ] || { echo "install_schedule: $SCHEDULE not found" >&2; exit 1; }

kept="$( (crontab -l 2>/dev/null || true) | awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) == 1 { inside = 1; next }
  index($0, e) == 1 { inside = 0; next }
  inside { next }
  /ops\/[a-z_]+_cron\.sh/ { next }
  { print }
')"

mkdir -p "$APP_DIR/etl/logs"

{
  [ -n "$kept" ] && printf '%s\n' "$kept"
  printf '%s\n' "$BEGIN" "SOURCEBD_APP_DIR=$APP_DIR"
  grep -vE '^[[:space:]]*(#|$)' "$SCHEDULE"
  printf '%s\n' "$END"
} | crontab -

echo "Scheduled jobs installed for $(id -un):"
crontab -l | awk -v b="$BEGIN_MARK" -v e="$END_MARK" 'index($0, b) == 1 { inside = 1; next } index($0, e) == 1 { inside = 0 } inside'
