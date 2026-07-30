# Aviator Verify — preview-environment image for umami
#
# A pre-warmed machine, not a container that runs the app: Aviator boots an e2b
# microVM from this, fetches the runbook branch into /code, then runs
# .aviator/scripts/preview-setup.sh to start the server. Playwright runs on
# Aviator's side, so no browser is needed here.
#
# No CMD/ENTRYPOINT (never run as a container), no COPY/ADD (pasted into the UI,
# which has no build context and rejects them).
#
# Caching: the launch cleans with `git clean -fd` and no -x, so gitignored paths
# survive — node_modules, /.next, /generated, /geo, /public/script.js,
# /public/recorder.js. The PostgreSQL cluster lives at /var/lib/postgresql,
# outside /code, so git never touches it at all.

FROM node:22-bookworm

ARG DEBIAN_FRONTEND=noninteractive

# postgresql: umami has no sqlite path (@prisma/adapter-pg only speaks postgres).
# git/git-lfs: Aviator checks out the runbook branch in /code.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git git-lfs ca-certificates curl \
        postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Pinned to the version the repo's own Dockerfile pins, so the lockfile is read
# by the resolver it was written for.
RUN npm install -g pnpm@10.15.1

RUN git config --system --add safe.directory /code

# The URL must match the connected repo. On a mismatch Aviator does not error —
# it deletes /code and re-clones, silently discarding everything baked below.
# --filter=blob:none, never --depth 1 / --single-branch: those track only the
# default branch, so fetching the runbook branch later fails.
RUN git clone --filter=blob:none https://github.com/aviator-co/umami.git /code

WORKDIR /code

# Outside /code — a marker inside would be untracked and deleted by the clean.
RUN git -C /code rev-parse HEAD > /preview-image-sha

# e2b passes these to build steps but does NOT carry them into the sandbox at run
# time, so the setup script re-exports them. (PATH is the exception: e2b forces
# its own and ignores any ENV PATH here.)
ENV DATABASE_URL="postgresql://umami:umami@127.0.0.1:5432/umami"
ENV APP_SECRET="aviator-preview"
ENV NEXT_TELEMETRY_DISABLED=1
ENV DISABLE_TELEMETRY=1
# 4 GB box; Node's default old-space (~2 GB) can be tight for this build.
ENV NODE_OPTIONS="--max-old-space-size=3584"

RUN pnpm install --frozen-lockfile

# Each writes to a gitignored path, so the setup script only redoes what the
# branch actually changed. build-geo downloads GeoLite2-City.mmdb (needs network).
RUN pnpm build-db
RUN pnpm build-tracker
RUN pnpm build-recorder
RUN pnpm build-geo

# The expensive one, and the reason this image exists. Needs no database.
RUN pnpm build-app

# PostgreSQL: create the cluster, migrate, seed demo analytics. One RUN layer,
# because the server has to be up for the middle of it. An empty umami renders
# "no data" everywhere; seed-data.ts creates "Demo Blog" and "Demo SaaS" with
# sessions, events and revenue.
#
# --skip-systemctl-redirect is required on BOTH calls. Debian's pg_ctlcluster
# hands the action to `systemctl start postgresql@<ver>-main` when
# /run/systemd/system exists and it was not run from init
# (/usr/bin/pg_ctlcluster:376), and that unit cannot come up in e2b's builder.
# Older e2b builders lacked systemd so this used to pass; `docker build` never
# hits it either, because each RUN is PID 1 there and getppid()==1 suppresses
# the redirect on its own. The flag makes the behaviour the same everywhere.
RUN set -eux; \
    mkdir -p /var/run/postgresql; \
    chown postgres:postgres /var/run/postgresql; \
    PGVER="$(ls /etc/postgresql | sort -V | tail -1)"; \
    if [ ! -d "/etc/postgresql/${PGVER}/main" ]; then pg_createcluster "${PGVER}" main; fi; \
    pg_ctlcluster --skip-systemctl-redirect "${PGVER}" main start; \
    echo "CREATE ROLE umami LOGIN PASSWORD 'umami' SUPERUSER;" | su postgres -c "psql -v ON_ERROR_STOP=1"; \
    su postgres -c "createdb -O umami umami"; \
    pnpm exec prisma migrate deploy; \
    (pnpm exec tsx scripts/seed-data.ts --days 30 || echo "WARN: seed-data failed; the setup script will retry at launch"); \
    pg_ctlcluster --skip-systemctl-redirect "${PGVER}" main stop
# The explicit stop matters: a cluster still running when the layer is
# snapshotted leaves a postmaster.pid whose PID may be live in the booted
# sandbox, which makes the next start refuse.

RUN mkdir -p /var/log/app
