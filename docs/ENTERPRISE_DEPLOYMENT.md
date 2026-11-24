# Deploying SourceBD

How code reaches the live site, how to tell it worked, and how to put the previous release back.
The server's address is never written in this repository: it is the `VPS_HOST` secret, and the
deploy workflow targets that one server and no other.

## Branch and release model

```
branch → pull request → development        (the checks land it)
development → pull request → main          (a merge commit, never a squash)
CI green on main → Deploy Production       (called by CI)
```

Nothing is pushed to `main` or `development` directly. Database migrations are not part of a
deploy: the releaser applies a release's migrations to the live database before it opens the
release pull request (`factory/roles/releaser.md`).

The checks required on both branches are `verify`, `unit-tests`, `unit-tests-slow`,
`http-boundary`, `migrations` and `python-tests`. Only the founder can change branch protection:

```bash
for b in development main; do printf '%s' '{"required_status_checks":{"strict":false,"contexts":["verify","unit-tests","unit-tests-slow","http-boundary","migrations","python-tests"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' | gh api -X PUT repos/arclayer-ltd/SourceBD/branches/$b/protection --input -; done
```

## What a deploy does

`.github/workflows/deploy-production.yml`, called by CI on `main` (or run by hand with a ref):

1. Resolves the ref to one commit.
2. Connects to `VPS_HOST` over SSH and runs `ops/gha_vps_deploy.sh`, which runs
   `ops/deploy_vps.sh --ref=<that commit>` in `/opt/sourcebd`. The script checks out the commit,
   pulls the images CI built for it (or builds them on the server), restarts the web container,
   and waits until `http://127.0.0.1/api/health/db` answers 200. It then installs the commit's
   `ops/schedule.cron`.
3. From GitHub, waits until `http://VPS_HOST/api/health/db` answers 200 with that commit.

`/api/health/db` is 200 only when the site can read its database. `/api/health` is the liveness
probe Docker uses and does not touch the database, so it proves nothing about a release.

`ops/deploy_vps.sh` refuses to run without `--ref`. On the server, by hand:

```bash
cd /opt/sourcebd && bash ops/deploy_vps.sh --ref=<commit or tag>
```

## Secrets and settings

GitHub (Settings → Secrets and variables → Actions): `VPS_HOST`, `VPS_USER`,
`VPS_SSH_PRIVATE_KEY`, optional `VPS_APP_DIR` (default `/opt/sourcebd`). One plain variable,
`PROD_PUBLIC_BUILD_ENV`, holds the `NEXT_PUBLIC_*` lines of the server's `.env` so CI can build the
browser bundle; if it drifts from the server's `.env`, the server builds the images itself.

The server's `/opt/sourcebd/.env` holds the runtime secrets and is never overwritten by a deploy.
The deploy refuses to start without `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`SUPABASE_SERVICE_ROLE_KEY`, `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` and
`NEXT_PUBLIC_APP_URL`. `.env.example` lists the rest.

Never delete on the server: `.env`, `etl/raw/`, `etl/parsed/`, `etl/logs/`, `.deploy/`.

## Checking a release

- `curl -s https://sourcebd.net/api/health/db` → 200, `"db":"ok"`, and the commit you released.
- Then each merged issue's "done when", on the live site.

## Rollback

The deploy records the commit it replaced in `/opt/sourcebd/.deploy/previous-sha`. Preferred: run
**Deploy Production** by hand with that commit as the ref. On the server:

```bash
cd /opt/sourcebd && bash ops/deploy_vps.sh --ref="$(cat .deploy/previous-sha)"
```

Rolling the code back does not undo a migration. If a migration caused the harm, restoring the
database is `docs/runbooks/backup-restore.md`.
