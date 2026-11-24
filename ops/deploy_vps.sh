#!/usr/bin/env bash
# SourceBD production deploy, run on the server. The deploy workflow calls it through
# ops/gha_vps_deploy.sh; docs/ENTERPRISE_DEPLOYMENT.md is the guide.
#
# Usage on the server:
#   cd /opt/sourcebd && bash ops/deploy_vps.sh --ref=<commit, tag or branch>
#
# --ref is required. There is no default: a deploy that guessed would put whatever it guessed on the
# live site. Database migrations are not part of a deploy; the releaser applies them first.

# IMPORTANT — this script is self-modifying: `main()` performs a `git
# checkout` on this very repo, which can overwrite ops/deploy_vps.sh on disk
# mid-run. Bash reads script files incrementally as it executes them, so a
# self-modifying script can desync bash's read offset and silently execute
# stale bytes from the OLD file version after the checkout point (observed
# 2 Jul 2026: `systemctl restart caddy` silently executed as a stale
# `systemctl reload caddy` from the previous file version, failing because
# `admin off` disables the endpoint reload needs). Fix: every line that
# matters is inside `main()`, and bash fully parses a function body into
# memory before it starts calling it — only the final `main "$@"` line at
# EOF, invoked after the whole file (including the function) has already
# been read, is safe to keep outside the function. Never add top-level
# logic after this point again.

set -Eeuo pipefail

main() {
	DEPLOY_START_S="$(date +%s)"

	REPO_DIR="${REPO_DIR:-/opt/sourcebd}"
	REF=""
	COMPOSE_FILE="docker-compose.yml"
	SKIP_BACKUP=0
	DEPLOY_META_DIR=".deploy"

	for arg in "$@"; do
		case "$arg" in
			--ref=*) REF="${arg#*=}" ;;
			--skip-backup) SKIP_BACKUP=1 ;;
			--help|-h)
				sed -n '2,10s/^# \{0,1\}//p' "$0"
				exit 0
				;;
			*) echo "Unknown flag: $arg" >&2; exit 2 ;;
		esac
	done

	[ -n "$REF" ] || die "No release named. Pass --ref=<commit, tag or branch>; nothing was changed."
	CHECKOUT_TARGET="$REF"

	cd "$REPO_DIR" || die "REPO_DIR $REPO_DIR not found"
	[ -d .git ] || [ -f .git ] || die "$REPO_DIR is not a git checkout; this script deploys only from git"

	PREVIOUS_SHA=""
	COMMIT_SHA=""
	CADDYFILE_CHANGED=1

	unset GIT_CONFIG_PARAMETERS
	PREVIOUS_SHA="$(git rev-parse HEAD 2>/dev/null || true)"

	# Drop an expired HTTPS PAT from origin and fetch with GITHUB_TOKEN
	# via http extraheader (never written into the remote URL).
	if [ -f "$REPO_DIR/ops/github_https_fetch_auth.sh" ]; then
		# shellcheck disable=SC1091
		. "$REPO_DIR/ops/github_https_fetch_auth.sh"
		sourcebd_prepare_github_https_fetch
	fi

	step "Fetching origin and checking out $CHECKOUT_TARGET"
	git fetch --quiet origin --tags
	git checkout "$CHECKOUT_TARGET" || die "Could not checkout $CHECKOUT_TARGET"

	# Fast-forward only when target resolves to a remote branch
	if git show-ref --verify --quiet "refs/remotes/origin/${CHECKOUT_TARGET}"; then
		git pull --ff-only origin "$CHECKOUT_TARGET" || die "Non-fast-forward pull for $CHECKOUT_TARGET — resolve manually"
	fi

	COMMIT_SHA="$(git rev-parse HEAD)"

	if [ -n "$PREVIOUS_SHA" ] && [ "$PREVIOUS_SHA" != "$COMMIT_SHA" ]; then
		if git diff --quiet "$PREVIOUS_SHA" "$COMMIT_SHA" -- ops/Caddyfile 2>/dev/null; then
			CADDYFILE_CHANGED=0
		fi
	elif [ -n "$PREVIOUS_SHA" ]; then
		CADDYFILE_CHANGED=0
	fi

	mkdir -p "$DEPLOY_META_DIR"
	if [ -n "$PREVIOUS_SHA" ] && [ "$PREVIOUS_SHA" != "$COMMIT_SHA" ]; then
		echo "$PREVIOUS_SHA" > "$DEPLOY_META_DIR/previous-sha"
	fi
	echo "$COMMIT_SHA" > "$DEPLOY_META_DIR/current-sha"
	date -u +%Y-%m-%dT%H:%M:%SZ > "$DEPLOY_META_DIR/deployed-at"
	# Write a sidecar env file loaded by docker-compose so the web container's
	# /api/health can report the deployed commit at runtime. .env is never
	# overwritten by this script; this sidecar is the only deploy-managed file.
	printf 'COMMIT_SHA=%s\n' "$COMMIT_SHA" > "$DEPLOY_META_DIR/deploy.env"
	export COMMIT_SHA
	echo "  previous = ${PREVIOUS_SHA:-none}"
	echo "  head     = $COMMIT_SHA"

	step "Validating .env (never overwritten by this script)"
	[ -f .env ] || die ".env missing — copy .env.example and fill it in (docs/ENTERPRISE_DEPLOYMENT.md)"
	required=(SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY NEXT_PUBLIC_APP_URL)
	missing=0
	for key in "${required[@]}"; do
		if ! grep -qE "^${key}=.+" .env; then
			warn "Missing or empty: $key"
			missing=$((missing+1))
		fi
	done
	[ "$missing" -eq 0 ] || die "Fix .env and re-run."

	if [ "$SKIP_BACKUP" -eq 0 ] && docker image inspect sourcebd-web:latest >/dev/null 2>&1; then
		step "Tagging current Docker image for rollback"
		rollback_tag="sourcebd-web:rollback-${PREVIOUS_SHA:-unknown}"
		docker tag sourcebd-web:latest "$rollback_tag" 2>/dev/null || warn "Could not tag rollback image"
		echo "$rollback_tag" > "$DEPLOY_META_DIR/previous-docker-tag"
	fi

	# CI on main builds both images next to its checks and pushes them to
	# GitHub's registry, tagged with the commit. Pulling them takes seconds
	# where building here took ~6 minutes. Anything short of both pulls
	# succeeding (no WEB_IMAGE/ETL_IMAGE, a manual deploy of an older ref, the
	# image job skipped) falls through to the builds below, as before.
	#
	# The web image bakes in the NEXT_PUBLIC_* lines CI was given. It is used
	# only when its fingerprint matches this server's .env, computed by the
	# same recipe as the image job in .github/workflows/ci.yml.
	PULLED=0
	if [ -n "${WEB_IMAGE:-}" ] && [ -n "${ETL_IMAGE:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
		step "Pulling images built by CI"
		want_fp="$(grep -E '^NEXT_PUBLIC_' .env | sed 's/\r$//' | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"
		if printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u x-access-token --password-stdin >/dev/null && docker pull --quiet "$WEB_IMAGE" && docker pull --quiet "$ETL_IMAGE"; then
			got_fp="$(docker image inspect -f '{{ index .Config.Labels "sourcebd.public-env-sha" }}' "$WEB_IMAGE" 2>/dev/null || true)"
		fi
		if [ -n "${got_fp:-}" ] && [ "$got_fp" = "$want_fp" ]; then
			docker tag "$WEB_IMAGE" sourcebd-web:latest
			docker tag "$ETL_IMAGE" sourcebd-etl:latest
			PULLED=1
			echo "  ✓ $WEB_IMAGE"
			echo "  ✓ $ETL_IMAGE"
		else
			warn "CI images missing, or built with NEXT_PUBLIC_ settings that differ from this .env; building on this server instead"
		fi
		docker logout ghcr.io >/dev/null 2>&1 || true
	fi

	if [ "$PULLED" -eq 0 ]; then
	step "Building web image (Dockerfile.web)"
	# Single build via `docker compose build` — a prior version of this script
	# also ran a standalone `docker build` first, building the same image twice
	# and roughly doubling deploy time for no benefit (both commands produced
	# the identical `sourcebd-web:latest` tag). BuildKit cache mounts in
	# Dockerfile.web (pnpm store + .next/cache) make this one build fast for
	# code-only changes.
	export DOCKER_BUILDKIT=1
	export COMPOSE_DOCKER_CLI_BUILD=1
	docker compose -f "$COMPOSE_FILE" build web

	step "Building etl image (Dockerfile)"
	# The etl service bakes the pipeline source into the image — only
	# etl/raw, etl/parsed and etl/logs are bind-mounted — and cron invokes it
	# as `docker compose run --rm etl`, which reuses the existing tag rather
	# than rebuilding. So skipping this build leaves the scrapers running
	# whatever code was current at the last etl build, silently, while
	# /api/health reports the new commit and the deploy looks clean.
	#
	# That is not hypothetical: on 31 Jul 2026 the supplier-identity guards in
	# etl/core/upsert.py were deployed and the minutely scraper queue kept
	# running the old matcher, which would have re-merged the 40 supplier
	# profiles that had just been split apart. Web and etl are one commit and
	# must be built as one.
	docker compose -f "$COMPOSE_FILE" build etl
	fi

	step "Restarting web container only (etl volumes untouched)"
	# `--no-build`: the image was just built explicitly above. Without this
	# flag, `up` re-evaluates the service's `build:` block and reruns the
	# ENTIRE Dockerfile a second time (observed 2 Jul 2026: doubled a ~3 min
	# deploy to ~8 min for zero benefit — both builds produce the same tag).
	docker compose -f "$COMPOSE_FILE" up -d --no-deps --no-build web

	step "Waiting for /api/health"
	attempt=0
	until curl --silent --fail --max-time 3 http://127.0.0.1:3000/api/health >/dev/null; do
		attempt=$((attempt+1))
		if [ "$attempt" -gt 20 ]; then
			docker compose -f "$COMPOSE_FILE" logs --tail=80 web >&2
			die "Web container did not become healthy in 60s — rollback: bash ops/deploy_vps.sh --ref=$(cat "$DEPLOY_META_DIR/previous-sha" 2>/dev/null || echo UNKNOWN)"
		fi
		sleep 3
	done
	echo "  ✓ web container healthy"

	step "Trimming old images and build leftovers"
	# Every deploy tags the outgoing image rollback-<sha>, and nothing removed
	# them: by 27 Oct 2026 there were 146 (~40 GB) plus 25 GB of build cache,
	# and the disk was 86% full (ops/plans/vps-health-2026-10-28.md). Keep the
	# newest 5 rollback tags, drop CI image tags other than this deploy's,
	# untagged layers, and build cache older than a week (a fallback build on
	# this server still starts warm). Runs only after the new container is
	# healthy, and never fails the deploy: inside `{ } ||` a failing step does
	# not stop the script, and the last line prints the disk use either way.
	{
		docker images --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' sourcebd-web | grep ':rollback-' | sort -r | tail -n +6 | cut -f2 | xargs -r docker rmi >/dev/null
		docker images --format '{{.Repository}}:{{.Tag}}' | grep '^ghcr\.io/' | grep -vxF -e "${WEB_IMAGE:-none}" -e "${ETL_IMAGE:-none}" | xargs -r docker rmi >/dev/null
		docker image prune -f >/dev/null
		docker builder prune -f --filter until=168h >/dev/null
		df -h / | tail -1
	} || warn "Image trim did not finish; the deploy itself is fine"

	if [ "$CADDYFILE_CHANGED" -eq 1 ] && command -v caddy >/dev/null 2>&1; then
		step "Restarting Caddy (ops/Caddyfile changed)"
		caddy validate --config /etc/caddy/Caddyfile >/dev/null
		# This Caddyfile ships with `admin off` (hardening — no local admin
		# API), so `caddy reload` / `systemctl reload caddy` can never work:
		# both talk to the admin API over localhost:2019, which doesn't
		# exist. `restart` re-execs Caddy fresh from the config on disk
		# instead — the correct (and only reliable) way to apply Caddyfile
		# changes with admin off. Only runs when the Caddyfile actually
		# changed: the running Caddy process already proxies to the same
		# upstream port regardless of which app version is behind it, so
		# app-only deploys (the common case) skip this step entirely for a
		# faster, zero-risk deploy.
		systemctl restart caddy
		echo "  ✓ caddy restarted"
	else
		step "Skipping Caddy restart (ops/Caddyfile unchanged)"
	fi

	DEPLOY_ELAPSED_S="$(( $(date +%s) - DEPLOY_START_S ))"

	step "Public health check (the site reads its database)"
	# Through Caddy (127.0.0.1:80 on this box), and /api/health/db, not /api/health: the
	# second answers without touching the database, so a site that cannot reach Supabase
	# passed. Do not return after localhost is up either: GitHub's public smoke runs the
	# moment SSH exits (run 31855403484, 15 Aug 2026).
	# A rollback to a commit from before /api/health/db existed can only be checked the old
	# way; asking it for /api/health/db would fail a rollback that worked.
	HEALTH_PATH=/api/health/db
	HEALTH_SAYS="is live and reads its database"
	if ! git cat-file -e "$COMMIT_SHA:app/api/health/db/route.ts" 2>/dev/null; then
		HEALTH_PATH=/api/health
		HEALTH_SAYS="is live (it predates /api/health/db, so its database was not checked)"
	fi
	attempt=0
	until curl --silent --fail --max-time 10 "http://127.0.0.1$HEALTH_PATH" >/dev/null; do
		attempt=$((attempt+1))
		if [ "$attempt" -gt 20 ]; then
			docker compose -f "$COMPOSE_FILE" logs --tail=40 web >&2
			die "The site did not answer $HEALTH_PATH within a minute — rollback: bash ops/deploy_vps.sh --ref=$(cat "$DEPLOY_META_DIR/previous-sha" 2>/dev/null || echo UNKNOWN)"
		fi
		sleep 3
	done
	echo
	echo "  ✓ deploy OK — commit $COMMIT_SHA $HEALTH_SAYS"
	echo "  elapsed: ${DEPLOY_ELAPSED_S}s"
	if [ -f "$DEPLOY_META_DIR/previous-sha" ]; then
		echo "  rollback ref: $(cat "$DEPLOY_META_DIR/previous-sha")"
	fi
}

step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

main "$@"
