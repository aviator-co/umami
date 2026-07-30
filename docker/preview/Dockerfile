# ---------------------------------------------------------------------------
# Aviator Verify — preview-environment image for umami
# ---------------------------------------------------------------------------
#
# This is NOT a container that runs the app. It is a PRE-WARMED MACHINE.
# Aviator boots an e2b microVM from this image, fetches the runbook branch into
# /code, then runs .aviator/scripts/preview-setup.sh inside it to start the
# server. A headless browser on Aviator's own infrastructure drives the app over
# the public internet.
#
# Consequences:
#   * No CMD / ENTRYPOINT — Aviator never runs this container normally.
#   * No COPY / ADD — this file is pasted into Aviator's "Add Custom Template"
#     screen, which has no build context and rejects them.
#   * No Chrome / Playwright — the browser lives on Aviator's side.
#
# This file is documentation. Aviator does not read it from the repo; the built
# template lives on e2b. Editing it here changes nothing until it is re-pasted
# and rebuilt.
#
# HOW THE CACHING WORKS
#
# At launch Aviator cleans the tree with `git reset --hard` + `git clean -fd`.
# There is no `-x`, so GITIGNORED PATHS SURVIVE. umami is a good fit — every
# expensive artifact is already gitignored (see .gitignore):
#
#   node_modules      pnpm dependencies (incl. the prisma engines)
#   /.next            the Next.js build output and its build cache
#   /generated        the esbuild-bundled prisma client
#   /src/generated    prisma generate output
#   /geo              the GeoLite2-City database
#   /public/script.js the rollup-built tracker
#   /public/recorder.js the rollup-built session recorder
#
# The PostgreSQL cluster lives at /var/lib/postgresql, entirely OUTSIDE /code,
# so git never touches it at all — the migrated schema and the seeded demo
# analytics survive every launch for free.
# ---------------------------------------------------------------------------

# Debian, not alpine (the repo's own runtime Dockerfile uses node:22-alpine).
# We need apt for PostgreSQL, and node:22-bookworm puts node/npm/npx in
# /usr/local/bin, which IS on e2b's forced PATH. Node 22 matches CI
# (.github/workflows -> node-version: 22).
FROM node:22-bookworm

ARG DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
#   git / git-lfs   Aviator checks out the runbook branch in /code
#   postgresql      umami has no sqlite path — @prisma/adapter-pg only speaks
#                   postgres, and scripts/check-db.js hard-fails below server
#                   version 9.4. Debian bookworm ships PostgreSQL 15, matching
#                   the repo's own docker-compose.yml (postgres:15-alpine).
#   postgresql-client  psql, used by the setup script to set the admin password
#
# npm is already present (node base image) — Aviator appends
# `npm install -g @anthropic-ai/claude-code` when it builds a Dockerfile-sourced
# template, and that step dies on a base image with no Node.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git git-lfs ca-certificates curl \
        postgresql postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# The repo is a pnpm workspace (pnpm-workspace.yaml + pnpm-lock.yaml). Pinned to
# the same version the repo's own Dockerfile pins, so the lockfile is read by
# the resolver it was written for. `npm install -g` lands it in /usr/local/bin,
# which is on e2b's forced PATH.
RUN npm install -g pnpm@10.15.1

# The sandbox may run git as a different user than built this image; without
# this every git command in /code aborts with "detected dubious ownership".
RUN git config --system --add safe.directory /code

# ---------------------------------------------------------------------------
# Clone the repo Aviator is connected to
# ---------------------------------------------------------------------------
# The URL must match the connected repo (aviator-co/umami). Aviator compares
# /code's origin against the repo name; on a mismatch it does NOT error — it
# deletes /code and re-clones, discarding everything baked below and making
# every preview permanently slow, with nothing in the logs to explain it.
#
# --filter=blob:none keeps the clone small while preserving the full ref
# namespace. Deliberately NOT --depth 1 / --single-branch: those rewrite
# remote.origin.fetch to track only the default branch, so Aviator's later
# `git fetch origin <runbook-branch>` never creates origin/<branch> and the
# checkout fails with "invalid reference".
RUN git clone --filter=blob:none https://github.com/aviator-co/umami.git /code

WORKDIR /code

# Record the baked commit OUTSIDE /code — a marker inside would be untracked,
# not gitignored, and deleted by the launch's `git clean -fd`. The setup script
# diffs the runbook branch against this to decide what actually needs redoing.
RUN git -C /code rev-parse HEAD > /preview-image-sha

# ---------------------------------------------------------------------------
# Build-time environment
# ---------------------------------------------------------------------------
# e2b passes ENV vars through to RUN steps here, but does NOT carry them into
# the sandbox at RUN TIME — the setup script re-exports every one of these.
# (PATH is the one exception in the other direction: e2b forces its own and
# ignores any ENV PATH set here.)
#
# DATABASE_URL is needed by prisma.config.ts at generate time. It is a real URL
# rather than the dummy the repo's Dockerfile uses, because the same value drives
# the migrate + seed step further down.
ENV DATABASE_URL="postgresql://umami:umami@127.0.0.1:5432/umami"
ENV APP_SECRET="aviator-preview"
ENV NEXT_TELEMETRY_DISABLED=1
ENV DISABLE_TELEMETRY=1
# e2b builds templates at 4 CPU / 4 GB, and boots the preview sandbox with the
# same shape. On a 4 GB box Node sizes its default old-space at roughly 2 GB,
# which a Next.js build of this size can run into. Raise the ceiling while
# staying under total RAM — the repo's own Dockerfile exposes NODE_OPTIONS as a
# build arg for the same reason.
ENV NODE_OPTIONS="--max-old-space-size=3584"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# node_modules is gitignored, so this survives the launch clean. pnpm-workspace's
# `allowBuilds` lets the @prisma/engines postinstall run, which downloads the
# query engine — so this step needs network.
RUN pnpm install --frozen-lockfile

# ---------------------------------------------------------------------------
# Build the artifacts a preview should not have to rebuild
# ---------------------------------------------------------------------------
# Each of these writes to a gitignored path, so it survives the launch clean and
# the setup script only redoes the ones the branch actually touched.
#
#   build-db       prisma generate -> src/generated, then esbuild-bundled to
#                  generated/prisma/client.js
#   build-tracker  rollup src/tracker/index.js  -> public/script.js
#   build-recorder rollup src/recorder/index.js -> public/recorder.js
#   build-geo      downloads GeoLite2-City.mmdb -> geo/ (network; the setup
#                  script never repeats it while geo/ exists)
RUN pnpm build-db
RUN pnpm build-tracker
RUN pnpm build-recorder
RUN pnpm build-geo

# The Next.js production build. This is the expensive one and the reason the
# image exists. No database is required — the repo's own Dockerfile builds
# against a dummy DATABASE_URL — so this can run before postgres is up.
# It writes .next/ (gitignored), including .next/cache, which is what makes the
# per-preview rebuild incremental.
RUN pnpm build-app

# ---------------------------------------------------------------------------
# PostgreSQL: create the cluster, migrate, and seed demo analytics
# ---------------------------------------------------------------------------
# One RUN layer, because the server has to be up for the middle of it.
#
# Everything here lands under /var/lib/postgresql — outside /code, so the launch
# clean cannot reach it. That is what lets a preview boot with a migrated schema
# and 30 days of realistic traffic already in place.
#
# An empty umami is close to unverifiable: every dashboard, chart, funnel and
# report renders "no data". scripts/seed-data.ts creates two websites,
# "Demo Blog" (blog.example.com) and "Demo SaaS" (app.example.com), with
# sessions, events, revenue and geography.
#
# The cluster version is discovered rather than hardcoded so a base-image bump
# to a newer Debian does not silently break the start path.
RUN set -eux; \
    mkdir -p /var/run/postgresql; \
    chown postgres:postgres /var/run/postgresql; \
    PGVER="$(ls /etc/postgresql | sort -V | tail -1)"; \
    if [ ! -d "/etc/postgresql/${PGVER}/main" ]; then pg_createcluster "${PGVER}" main; fi; \
    pg_ctlcluster "${PGVER}" main start; \
    echo "CREATE ROLE umami LOGIN PASSWORD 'umami' SUPERUSER;" | su postgres -c "psql -v ON_ERROR_STOP=1"; \
    su postgres -c "createdb -O umami umami"; \
    pnpm exec prisma migrate deploy; \
    (pnpm exec tsx scripts/seed-data.ts --days 30 || echo "WARN: seed-data failed; the setup script will retry at launch"); \
    pg_ctlcluster "${PGVER}" main stop
# ^ The explicit stop matters: a cluster still running when the layer is
#   snapshotted leaves a postmaster.pid whose recorded PID may be reused in the
#   booted sandbox, which makes pg_ctlcluster refuse to start. The setup script
#   clears a stale pid file defensively, but a clean shutdown here means it
#   never has to.

# Where the setup script writes the app log. Created here so a failure to write
# it is not the first thing that goes wrong at launch.
RUN mkdir -p /var/log/app
