#!/bin/bash
# Railway entrypoint for Frappe LMS
# Runs on every container start. Idempotent — safe to re-run.
set -e

cd /home/frappe/frappe-bench

# --- Required env vars ---
: "${MARIADB_HOST:?MARIADB_HOST is required (link Railway MySQL plugin and set this to MYSQLHOST)}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD is required (set to Railway MYSQL_ROOT_PASSWORD)}"
: "${REDIS_URL:?REDIS_URL is required (link Railway Redis plugin and set this)}"
: "${SITE_NAME:?SITE_NAME is required (e.g. lms.up.railway.app or your custom domain)}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required (first-boot Administrator password)}"

MARIADB_PORT="${MARIADB_PORT:-3306}"

echo "[entrypoint] Configuring bench for Railway services..."
bench set-mariadb-host "$MARIADB_HOST"
bench set-config -g db_port "$MARIADB_PORT"
bench set-redis-cache-host "$REDIS_URL"
bench set-redis-queue-host "$REDIS_URL"
bench set-redis-socketio-host "$REDIS_URL"

# Remove redis processes from Procfile (we use Railway Redis, not local)
sed -i '/redis/d' ./Procfile || true

# --- First-boot: create site if it doesn't exist ---
if [ ! -d "sites/${SITE_NAME}" ]; then
    echo "[entrypoint] Site ${SITE_NAME} not found — creating..."
    bench new-site "$SITE_NAME" \
        --force \
        --db-host "$MARIADB_HOST" \
        --db-port "$MARIADB_PORT" \
        --mariadb-root-password "$MARIADB_ROOT_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --no-mariadb-socket

    echo "[entrypoint] Installing payments + lms apps..."
    bench --site "$SITE_NAME" install-app payments
    bench --site "$SITE_NAME" install-app lms

    bench use "$SITE_NAME"
    bench --site "$SITE_NAME" clear-cache
    echo "[entrypoint] Site created successfully."
else
    echo "[entrypoint] Site ${SITE_NAME} already exists — skipping creation."
    bench use "$SITE_NAME"
fi

# Configure host header acceptance (Railway proxies via *.up.railway.app)
bench config dns_multitenant off
bench set-config -g host_name "https://${SITE_NAME}"

# Start Frappe (dev-style procfile via honcho — web + worker + scheduler + socketio)
# NOTE: For production you should migrate to supervisor + gunicorn + nginx.
# This works for Railway MVP but is not hardened for heavy traffic.
echo "[entrypoint] Starting bench..."
exec bench start
