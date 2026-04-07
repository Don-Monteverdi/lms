# Deploying Frappe LMS to Railway

This fork adds Railway deploy support via `Dockerfile`, `railway-entrypoint.sh`, and `railway.toml`. It is **not** a production-hardened deploy (no nginx/gunicorn/supervisor split) — it runs `bench start` inside a single container, which is fine for staging/demo but should be upgraded before heavy production use.

## Prerequisites

- [Railway account](https://railway.com) with a project
- [Railway CLI](https://docs.railway.com/guides/cli) (`npm i -g @railway/cli`)
- Authenticated: `railway login`

## Architecture

```
┌──────────────────────┐    ┌──────────────────────┐    ┌──────────────────┐
│  frappe-lms          │───▶│  Railway MySQL       │    │  Railway Redis   │
│  (this repo)         │    │  (MariaDB-compat)    │◀───│  (shared for 3)  │
│  port 8000 exposed   │    └──────────────────────┘    └──────────────────┘
└──────────────────────┘
```

## Step-by-step

### 1. Create the Railway project + link this repo

```bash
cd ~/Desktop/lms
railway init     # create new project, name it e.g. "frappe-lms"
railway link     # link this directory to the project
```

Or via the dashboard: New Project → Deploy from GitHub repo → select `Don-Monteverdi/lms`.

### 2. Add MySQL (MariaDB-compatible) plugin

In the Railway dashboard:
- **+ New** → **Database** → **Add MySQL**
- Wait for it to provision

Copy these values from the MySQL service's **Variables** tab — you'll need them in step 4:
- `MYSQLHOST`
- `MYSQLPORT`
- `MYSQL_ROOT_PASSWORD`

### 3. Add Redis plugin

In the Railway dashboard:
- **+ New** → **Database** → **Add Redis**
- Copy `REDIS_URL` from the Redis service's Variables tab

### 4. Set environment variables on the `frappe-lms` service

Go to your `frappe-lms` service → **Variables** tab → add:

| Variable                 | Value                                             |
| ------------------------ | ------------------------------------------------- |
| `MARIADB_HOST`           | `${{MySQL.MYSQLHOST}}` (reference syntax)         |
| `MARIADB_PORT`           | `${{MySQL.MYSQLPORT}}`                            |
| `MARIADB_ROOT_PASSWORD`  | `${{MySQL.MYSQL_ROOT_PASSWORD}}`                  |
| `REDIS_URL`              | `${{Redis.REDIS_URL}}`                            |
| `SITE_NAME`              | `lms.up.railway.app` (or your custom domain)      |
| `ADMIN_PASSWORD`         | *(choose a strong password)*                      |
| `PORT`                   | `8000`                                            |

The `${{ServiceName.VARIABLE}}` syntax lets Railway resolve inter-service refs automatically.

### 5. Expose the web port

- Service → **Settings** → **Networking** → **Generate Domain**
- Railway gives you `https://lms.up.railway.app` (or similar)
- Update the `SITE_NAME` env var to match this domain, then redeploy

### 6. Deploy

```bash
railway up           # push current dir and build
# or just `git push` — Railway auto-deploys on push to main
```

First build takes **10–20 minutes** (bench init downloads Frappe framework + builds frontend assets). Subsequent builds are faster if layers cache.

### 7. First-boot site creation

On the first container start, `railway-entrypoint.sh` will:
1. Point bench at Railway MySQL + Redis via env vars
2. Run `bench new-site` against the external MariaDB
3. Install `payments` + `lms` apps
4. Start `bench start`

Watch the deploy logs. On success you'll see:
```
[entrypoint] Site lms.up.railway.app not found — creating...
[entrypoint] Installing payments + lms apps...
[entrypoint] Starting bench...
```

### 8. Login

Open your Railway domain → you should see the Frappe setup wizard or LMS homepage.

- **Username:** `Administrator`
- **Password:** whatever you set as `ADMIN_PASSWORD`

## Troubleshooting

**Build fails at `bench init`** — Frappe needs ~2GB RAM during bench init. Railway's free tier may OOM. Upgrade to Hobby plan (512MB→8GB).

**`bench new-site` fails with "Access denied"** — Your `MARIADB_ROOT_PASSWORD` doesn't match Railway's MySQL root password. Double-check the Variables tab on the MySQL service.

**Site loads but assets 404** — Run `railway run bench build` after deploy. Assets sometimes don't persist across rebuilds if the volume isn't mounted.

**`bench start` crashes immediately** — Check that `Procfile` doesn't have `redis-*` processes (the entrypoint strips these). If it still fails, SSH in with `railway shell` and inspect.

**Frappe can't find the site (`SITE_NOT_FOUND`)** — `SITE_NAME` must exactly match the domain Railway assigns you. Update the env var and redeploy.

## Known limitations

- **No persistent volume for sites/** — site files, uploads, and backups live in the container filesystem and are lost on redeploy. For real production, mount a Railway volume at `/home/frappe/frappe-bench/sites`.
- **No background worker/scheduler isolation** — `bench start` runs everything in one process. Heavy async jobs will contend with web requests.
- **No nginx in front** — requests go straight to Gunicorn via Railway's proxy.

## Upgrading to production-hardened

For real production traffic, migrate to the official [`frappe_docker`](https://github.com/frappe/frappe_docker) production stack and deploy as separate Railway services: `backend`, `frontend-nginx`, `websocket`, `queue-short`, `queue-long`, `scheduler`. That's a multi-day project.
