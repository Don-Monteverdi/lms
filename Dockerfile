# Frappe LMS — Railway-ready Dockerfile
# Base: official frappe/bench image (has bench CLI, Python, Node, wkhtmltopdf)
# Builds a frappe-bench with the LMS app installed, ready for Railway.
#
# Runtime dependencies (add as Railway services, NOT in this image):
#   - MariaDB 10.6+   (Railway MySQL plugin works — it's MariaDB-compatible)
#   - Redis 6+        (Railway Redis plugin — shared for cache/queue/socketio)
#
# Env vars required at runtime (set in Railway dashboard):
#   MARIADB_HOST, MARIADB_ROOT_PASSWORD, MARIADB_PORT (default 3306)
#   REDIS_URL                (e.g. redis://default:pass@host:6379)
#   SITE_NAME                (e.g. lms.up.railway.app)
#   ADMIN_PASSWORD           (first-boot admin password)

FROM frappe/bench:latest

USER frappe
WORKDIR /home/frappe

# Initialize frappe-bench with Frappe v15 (LMS target)
# --skip-redis-config-generation: we'll configure Redis via env vars at runtime
# --skip-assets: assets built after app install
RUN bench init \
      --skip-redis-config-generation \
      --frappe-branch version-15 \
      --python python3 \
      frappe-bench

WORKDIR /home/frappe/frappe-bench

# Install LMS app dependencies (payments is required by LMS)
RUN bench get-app --branch version-15 https://github.com/frappe/payments \
 && bench get-app https://github.com/frappe/lms

# Build frontend assets for LMS
RUN bench build --app lms

# Copy entrypoint script
COPY --chown=frappe:frappe railway-entrypoint.sh /home/frappe/railway-entrypoint.sh
USER root
RUN chmod +x /home/frappe/railway-entrypoint.sh
USER frappe

# Frappe web port
EXPOSE 8000
# Socketio port
EXPOSE 9000

WORKDIR /home/frappe/frappe-bench

CMD ["/home/frappe/railway-entrypoint.sh"]
