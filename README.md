# Docker Stack (LXC)

A stack of self-hosted services orchestrated with Docker Compose, running inside an LXC container on a Proxmox home server. The base domain is `feignman.online`.

This is an infrastructure repo — there's no application code, build step, or test suite. The "code" is the compose file, per-service configs, and a handful of helper scripts. You work on it with `docker compose`.

## Provisioning a fresh container

Run `provision.sh` inside a fresh Ubuntu 24.04 LXC template to install Docker. Run it once when bootstrapping a new container, not as part of day-to-day work. After it finishes, log out and back in so the `docker` group takes effect, then start the stack.

### Requirements

- **`traefik/acme.json`** must exist with file permissions `600` — Traefik refuses to start otherwise. Create it with `touch traefik/acme.json && chmod 600 traefik/acme.json`.
- **Secrets** — see below.

## Secrets

Secrets are not committed. They're loaded from [Bitwarden](https://bitwarden.com) via `rbw` (the Bitwarden CLI) and `direnv`:

- `.envrc` calls `rbw_export_secret Secrets <NAME>` for each required variable, which exports it into your shell environment.
- `direnv allow` must have been run in the repo so the variables are present. `docker compose config` will warn about anything missing.
- All stack secrets live as individual fields on a single Bitwarden item named `Secrets` (`LLDAP_JWT_SECRET`, `CF_DNS_API_TOKEN`, `VAULT_ADMIN_TOKEN`, `KARAKEEP_*`, `IMMICH_DB_PASSWORD`, etc.). To introduce a new secret, add a field to that item and a matching `rbw_export_secret` line in `.envrc`.

Helper scripts for generating secret values:

- `lldap/generate_secrets.sh` — prints random `LLDAP_JWT_SECRET` / `LLDAP_KEY_SEED` values.
- `authelia/scripts/generate_pwd.sh` — generates an Argon2 hash for an Authelia password using the authelia container.

## Starting services

```bash
docker compose up -d
```

## Architecture

### Edge: Traefik + Authelia + lldap

- **Traefik** is the single TLS-terminating reverse proxy. Port 80 redirects to 443. Certificates are issued via a Let's Encrypt **DNS-01 challenge through Cloudflare** (the `dns-cloudflare` resolver), so only ports 80/443 are public and no HTTP challenge is needed. `traefik/acme.json` stores the certs and must be `chmod 600`.
- Routers are defined two ways:
  1. **Docker provider** (`exposedByDefault = false`) — each service adds `traefik.enable=true` and `traefik.http.routers.<name>.*` labels in `docker-compose.yml`. This is the normal path for in-stack services.
  2. **File provider** (`traefik/rules.toml`) — manually-defined routers/services for things running outside this container/stack (e.g. `hass`, `grafana`, `nextcloud` on other LAN IPs). Add entries here when pointing Traefik at a non-docker host.
- **Authelia** is the auth layer, wired as a Traefik forward-auth middleware (`authelia@docker`). Services that require login add `traefik.http.routers.<name>.middlewares=authelia@docker`. Its `configuration.yml` is a Go template (`X_AUTHELIA_CONFIG_FILTERS=template`) that pulls secrets from env vars.
- **lldap** is the LDAP user directory (`dc=feignman,dc=online`) that Authelia authenticates against.

Request flow: Cloudflare → Traefik (:443) → (optional) Authelia forward-auth → backing container.

### Adding a new service

1. Add a service block in `docker-compose.yml`.
2. Add `traefik.*` labels with a `Host(`<sub>.feignman.online`)` rule, `entrypoints=websecure`, `tls.certresolver=dns-cloudflare`, and `authelia@docker` in `middlewares` if it should be gated.
3. Add a Cloudflare `A` record for the subdomain pointing at this host's public IPv4 (manual — see the [Cloudflare dashboard](https://dash.cloudflare.com/d82fc935eaa0d4e230c219d03417590f/feignman.online/dns/records)). Traefik's DNS challenge handles the cert automatically.
4. Prefer `expose:` over `ports:` for anything routed through Traefik so it isn't directly publicly reachable. Services that intentionally bypass Traefik (`plex`, `deluge` with `network_mode: host`; `nzbget`/`deluge` with `traefik.enable=false`) are deliberate exceptions.

### Host integration notes

- **NAS media** lives on a separate TrueNAS box and is bind-mounted at `/truenas/...` (`Movies`, `Series`, `downloads`, `Photos`, `immich-library`). These paths are host-specific.
- **GPU/transcoding**: `plex` and `immich-server` mount `/dev/dri`. `plex` sets `PGID=993` to match the host `render` group for GPU access.
- **PUID/PGID 3002** is the shared media user/group for `linuxserver/*` images so container-written files match NAS ownership.
- The compose project defines a bridge network `docker-stack-net` at `172.18.0.0/16`. `IMMICH_TRUSTED_PROXIES` and Traefik→container hops rely on this subnet — don't renumber it casually.
- `telegraf` runs privileged and bind-mounts `/` to `/rootfs` to scrape host metrics from inside the LXC.
- **Immich** is a multi-container sub-stack (`immich-server`, `immich-postgres` pinned to a vector-chord image, `immich-redis`/valkey, `immich-machine-learning`); its ML cache lives in the named `model-cache` volume. **Karakeep** similarly fans out into `karakeep-web`, `karakeep-chrome`, `karakeep-meilisearch`.

### Volumes

Per-service persistent data lives under `./volumes/<service>/` (gitignored). The `volumes/` directory also contains leftover dirs from services no longer in the compose file (`nextcloud`, `grafana`, `portainer`, etc.) — a subdir's presence doesn't mean the service is currently deployed.

## Operational chores

### Updating container images

```bash
docker compose pull                 # pull new tags for the whole stack
docker compose pull <service>       # just one service
docker compose up -d                # recreate anything whose image changed
```

After updating, follow the logs to confirm the service came up healthy:

```bash
docker compose logs -f <service>
```

Note: `immich-postgres` is pinned by digest (`@sha256:...`) and `immich-server` to `v2`. Bump those deliberately — don't expect `pull` to move them silently.

### Cleaning up old images and cruft

```bash
docker image prune -a               # remove every image not referenced by a running/stopped container (frees the most space)
docker image prune                  # safer: dangling/untagged images only
docker container prune              # remove stopped containers
docker volume prune                 # remove unused volumes — check `docker volume ls` first
docker system prune -a --volumes    # NUCLEAR: everything combined. Only run when you mean it.
```

`docker image prune -a` is the usual lever and is safe here because images still referenced by a defined-but-stopped service are kept. Be careful with `--volumes` variants: this stack's data lives in bind mounts under `./volumes/` and in the `model-cache` named volume, which holds immich ML models.

### Backups

Persistent state lives in `./volumes/<service>/` (bind mounts), the `model-cache` named volume, and `traefik/acme.json`. The genuinely hard-to-rebuild bits are:

- `authelia/config/db.sqlite3` (sessions, MFA)
- `lldap` users
- `immich-postgres` (`./volumes/immich/postgres`)
- the NAS-mounted `/truenas/immich-library` and `/truenas/Photos`

Back up the `./volumes` tree and `acme.json`. The `model-cache` volume is just a download cache and can be regenerated.

### Certificates / Cloudflare

Certs auto-renew via the Traefik `dns-cloudflare` resolver using `CF_DNS_API_TOKEN` — no cron needed. If a subdomain isn't getting a cert, check `docker compose logs traefik` for ACME errors and confirm the Cloudflare `A` record exists and points at this host. The Traefik dashboard is at `https://traefik.feignman.online` behind Authelia.

### Disk / host health

`telegraf` is already scraping host metrics from `/rootfs`. For a quick manual check:

```bash
df -h                     # host disk usage
docker system df          # space used by images / containers / volumes
```

## Conventions

- Commit messages follow `[<scope>][<type>] <subject>` (e.g. `[immich][new] ...`, `[fix][secrets] ...`).
- `TZ=Europe/Paris` is set throughout; keep new services consistent.
- Keep secrets out of commits — `.gitignore` covers `/secrets/*`, `acme.json`, `duck.log`, and authelia's db/logs. The rbw/direnv env-var flow is the source of truth, not committed files.
