#!/bin/bash
# Run preview-setup.sh locally against the preview image, in a container made to
# behave like an e2b sandbox.
#
#   ./.aviator/scripts/preview-test-local.sh [image-tag]
#
# Build the image first:
#   docker build -f docker/preview/Dockerfile -t umami-preview:test .
#
# WHY THIS EXISTS
#
# A plain `docker run` does NOT behave like the sandbox, and every difference so
# far has been one that hides a real bug rather than causing a false alarm. Two
# have already reached production this way:
#
#   1. systemd. Debian's pg_ctlcluster redirects to
#      `systemctl start postgresql@<ver>-main` when /run/systemd/system exists
#      AND getppid() != 1. A container has no such directory, and `docker run
#      ... bash -c` makes bash PID 1 — either one alone suppresses the redirect,
#      so the container silently took the working path.
#
#   2. The snakeoil certificate. postgresql.conf ships `ssl = on` pointing at
#      /etc/ssl/certs/ssl-cert-snakeoil.pem. It is present in the image but
#      absent in the booted sandbox, so postgres refused to start there and
#      nowhere else.
#
# Both are simulated below. Anything else that later turns out to differ belongs
# here too — that is the whole point of the file.
set -euo pipefail

IMAGE="${1:-umami-preview:test}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Testing $IMAGE"

docker run --rm \
  `# e2b forces its own PATH and ignores any ENV PATH from the image.` \
  -e PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e PREVIEW_URL=https://3000-fakesandbox.e2b.app \
  -e UMAMI_ADMIN_USERNAME=admin \
  -e UMAMI_ADMIN_PASSWORD=umami \
  `# Mount the scripts from disk so edits need no image rebuild.` \
  -v "$SCRIPTS_DIR:/mnt/scripts:ro" \
  "$IMAGE" \
  `# e2b does not carry the base image's environment into the sandbox, so unset` \
  `# everything the Dockerfile set — the script must export it all itself.` \
  env -u DATABASE_URL -u APP_SECRET -u NEXT_TELEMETRY_DISABLED \
      -u DISABLE_TELEMETRY -u NODE_OPTIONS \
  bash -c '
    set -u

    # (1) Make pg_ctlcluster believe systemd is supervising services.
    mkdir -p /run/systemd/system

    # (2) Remove the snakeoil certificate, as the sandbox does.
    rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/ssl-cert-snakeoil.key

    # Run one shell deeper so getppid() != 1, the other half of the systemd
    # redirect condition. Running it directly here would hide it.
    bash /mnt/scripts/preview-setup.sh
    echo "SCRIPT_EXIT=$?"

    echo "--- probes ---"
    for p in /api/heartbeat /login /websites /script.js /recorder.js; do
      printf "  %-16s " "$p"
      curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:3000$p"
    done

    echo "--- auth ---"
    printf "  injected creds   "
    curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" \
      -d "{\"username\":\"admin\",\"password\":\"umami\"}" \
      http://127.0.0.1:3000/api/auth/login

    echo "--- seeded data ---"
    export PGPASSWORD=umami
    for tb in website session website_event link pixel board report; do
      printf "  %-16s " "$tb"
      psql -h 127.0.0.1 -U umami -d umami -tAc "SELECT count(*) FROM $tb;" 2>/dev/null || echo "?"
    done

    echo "--- demo data is current? (default range is 24h) ---"
    printf "  events last 24h  "
    psql -h 127.0.0.1 -U umami -d umami -tAc \
      "SELECT count(*) FROM website_event WHERE created_at > now() - interval '"'"'24 hours'"'"';"
  '

echo "==> OK"
