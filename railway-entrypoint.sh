#!/bin/bash
# Railway entrypoint for Frappe LMS
# Runs on every container start. Idempotent — safe to re-run.
#
# Two-stage:
#   Stage 1 (root): chown the Railway-mounted volume so frappe can write to it,
#                   then re-exec this same script as the frappe user.
#   Stage 2 (frappe): do the actual bench work.

set -ex
export PYTHONUNBUFFERED=1

# --- Stage 1: root-only work ---
if [ "$(id -u)" = "0" ]; then
    echo "[entrypoint-root] $(date) — fixing volume permissions..."
    # Railway mounts volumes root-owned. Hand /sites to the frappe user so the
    # cp/seed step and bench commands can write to it.
    chown -R frappe:frappe /home/frappe/frappe-bench/sites
    echo "[entrypoint-root] dropping privileges to frappe user..."
    # Re-exec as frappe. su -s /bin/bash is available in every frappe/bench image.
    exec su -s /bin/bash frappe -c "exec $0"
fi

# --- Stage 2: runs as frappe ---
echo "[entrypoint] $(date) — starting"
echo "[entrypoint] user=$(whoami) pwd=$(pwd)"

cd /home/frappe/frappe-bench
echo "[entrypoint] cd frappe-bench OK"

# --- Volume seeding (first boot after mounting Railway volume) ---
# Railway mounts volumes EMPTY on first attach, masking whatever was baked into
# the image at that path. If apps.txt is missing, the volume is fresh — restore
# sites/ from the /home/frappe/sites-seed snapshot created at build time.
if [ ! -f /home/frappe/frappe-bench/sites/apps.txt ]; then
    if [ -d /home/frappe/sites-seed ]; then
        echo "[entrypoint] sites/ is empty (fresh Railway volume) — seeding from image snapshot..."
        cp -a /home/frappe/sites-seed/. /home/frappe/frappe-bench/sites/
        echo "[entrypoint] seed complete, contents:"
        ls -la /home/frappe/frappe-bench/sites/
    else
        echo "[entrypoint] WARN: sites/ empty AND no seed snapshot — bench may fail"
    fi
else
    echo "[entrypoint] sites/ already populated (existing volume) — skipping seed"
fi

# --- Required env vars ---
: "${MARIADB_HOST:?MARIADB_HOST is required (link Railway MySQL plugin)}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD is required}"
: "${REDIS_URL:?REDIS_URL is required (link Railway Redis plugin)}"
: "${SITE_NAME:?SITE_NAME is required (Railway public domain)}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"

MARIADB_PORT="${MARIADB_PORT:-3306}"
echo "[entrypoint] env vars OK — MARIADB_HOST=$MARIADB_HOST:$MARIADB_PORT SITE=$SITE_NAME"

# --- Wait for MariaDB to be reachable (Railway internal DNS sometimes needs a moment) ---
echo "[entrypoint] waiting for MariaDB at $MARIADB_HOST:$MARIADB_PORT..."
for i in $(seq 1 60); do
    if (echo > /dev/tcp/$MARIADB_HOST/$MARIADB_PORT) 2>/dev/null; then
        echo "[entrypoint] MariaDB reachable after ${i}s"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "[entrypoint] ERROR: MariaDB unreachable after 60s — aborting"
        exit 1
    fi
    sleep 1
done

# --- Wait for Redis (parse host from REDIS_URL) ---
REDIS_HOST=$(echo "$REDIS_URL" | sed -E 's|redis://(.*@)?([^:/]+).*|\2|')
REDIS_PORT=$(echo "$REDIS_URL" | sed -E 's|.*:([0-9]+).*|\1|')
echo "[entrypoint] waiting for Redis at $REDIS_HOST:$REDIS_PORT..."
for i in $(seq 1 30); do
    if (echo > /dev/tcp/$REDIS_HOST/$REDIS_PORT) 2>/dev/null; then
        echo "[entrypoint] Redis reachable after ${i}s"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "[entrypoint] ERROR: Redis unreachable after 30s — aborting"
        exit 1
    fi
    sleep 1
done

# --- Configure bench against Railway services ---
echo "[entrypoint] configuring bench hosts..."
bench set-mariadb-host "$MARIADB_HOST"
bench set-config -g db_port "$MARIADB_PORT"
bench set-redis-cache-host "$REDIS_URL"
bench set-redis-queue-host "$REDIS_URL"
bench set-redis-socketio-host "$REDIS_URL"

# Strip local redis processes from Procfile (Railway Redis is external)
sed -i '/redis/d' ./Procfile || true
sed -i '/watch/d' ./Procfile || true

# --- Force bench serve to bind to 0.0.0.0 (not 127.0.0.1) ---
# Railway's proxy reaches the container over its internal network, not loopback.
sed -i 's|^web: bench serve --port|web: bench serve --noreload --nothreading --host 0.0.0.0 --port|' ./Procfile || true
echo "[entrypoint] Procfile after edits:"
cat ./Procfile

# --- Detect site health: directory exists AND can list apps ---
# A stale/partial site directory from a failed previous deploy will have a folder
# but fail `bench --site X list-apps`. In that case we drop and recreate.
SITE_HEALTHY=0
if [ -d "sites/${SITE_NAME}" ]; then
    if bench --site "$SITE_NAME" list-apps > /dev/null 2>&1; then
        SITE_HEALTHY=1
    else
        echo "[entrypoint] WARN: sites/${SITE_NAME} exists but list-apps failed — treating as corrupt, will recreate"
        rm -rf "sites/${SITE_NAME}"
    fi
fi

if [ $SITE_HEALTHY -eq 0 ]; then
    echo "[entrypoint] creating site ${SITE_NAME} (this takes ~2-3 min)..."
    # --force drops any existing DB with the same name (left over from a failed attempt)
    bench new-site "$SITE_NAME" \
        --force \
        --db-host "$MARIADB_HOST" \
        --db-port "$MARIADB_PORT" \
        --mariadb-root-password "$MARIADB_ROOT_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --no-mariadb-socket

    echo "[entrypoint] installing payments app..."
    bench --site "$SITE_NAME" install-app payments

    echo "[entrypoint] installing lms app..."
    bench --site "$SITE_NAME" install-app lms

    echo "[entrypoint] running migrate to ensure schema is up to date..."
    bench --site "$SITE_NAME" migrate

    bench use "$SITE_NAME"
    bench --site "$SITE_NAME" clear-cache
    echo "[entrypoint] site created successfully."
else
    echo "[entrypoint] site ${SITE_NAME} is healthy — skipping creation."
    bench use "$SITE_NAME"
    # Still run migrate in case the image has newer migrations
    bench --site "$SITE_NAME" migrate || true
fi

# Allow Railway proxy to hit us by hostname
bench config dns_multitenant off
bench set-config -g host_name "https://${SITE_NAME}"
bench --site "$SITE_NAME" set-config host_name "https://${SITE_NAME}"

# Disable ALLOW_HOSTS restriction (Railway proxies via up.railway.app)
bench --site "$SITE_NAME" set-config allow_tests 1 || true

echo "[entrypoint] $(date) — starting bench (honcho)..."
echo "[entrypoint] final Procfile:"
cat ./Procfile

# Disable trace mode before exec so bench start output isn't cluttered
set +x
exec bench start
