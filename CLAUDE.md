# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A docker-compose stack of self-hosted services running inside an LXC container on a Proxmox home server. The base domain is `feignman.online`. There is no application code, build step, lint, or test suite here — the "code" is the compose file, service configs, and helper scripts. Iteration is done with `docker compose` commands against the live stack.

## Common commands

```bash
docker compose up -d                 # start/recreate changed services
docker compose up -d <service>       # target a single service
docker compose down                  # stop the stack (keeps volumes)
docker compose pull && docker compose up -d   # update images
docker compose logs -f <service>     # follow logs
docker compose restart <service>
docker compose config                # render the compose file with env var substitution (good for checking secret wiring)
```

`provision.sh` installs Docker on a fresh Ubuntu 24.04 LXC template — run once when bootstrapping a new container, not as part of day-to-day work.

Helper scripts (run from repo root or their dir as noted):
- `lldap/generate_secrets.sh` — prints random `LLDAP_JWT_SECRET` / `LLDAP_KEY_SEED` values to paste into the Bitwarden `Secrets` item.
- `authelia/scripts/generate_pwd.sh` — generates an Argon2 hash for an Authelia password via the authelia container.
- `duckdns/duck.sh` — updates DuckDNS; meant to be run from cron (see `duckdns/README.md`), not docker.

## Secrets

Secrets are **not** committed. They are loaded from Bitwarden via `rbw` (the Bitwarden CLI) using `direnv` — `.envrc` calls `rbw_export_secret Secrets <NAME>` for each required variable, which exports them into the shell environment. `docker compose` then substitutes `${...}` references in `docker-compose.yml` and the templated configs.

- To work on this repo, `direnv allow` must have been run so the env vars are present in your shell. `docker compose config` will show `WARNING: variable is not set` for anything missing.
- The `Secrets` Bitwarden **item** holds all stack secrets as individual fields (`LLDAP_JWT_SECRET`, `CF_DNS_API_TOKEN`, `VAULT_ADMIN_TOKEN`, `KARAKEEP_*`, etc.). Add a new field there and a matching `rbw_export_secret` line in `.envrc` when introducing a new secret.
- The README mentions a `./secrets/` path — that is the older mechanism and is largely superseded by the rbw/direnv flow; `authelia/secrets/` is still bind-mounted into the authelia container, but most secrets now arrive via env vars.
- `.envrc` also overrides the Claude Code model endpoints to route through OpenRouter. This is personal environment config, not part of the stack — leave it alone unless the user asks.

## Architecture

### Edge: Traefik + Authelia + lldap
- **Traefik** (`traefik/`) is the single TLS-terminating reverse proxy. Entrypoints `web` (:80) redirects to `websecure` (:443). Certificates come from a Let's Encrypt **DNS-01 challenge via Cloudflare** (`dns-cloudflare` resolver), so port 80/443 are the only public ports and no HTTP challenge is needed. `traefik/acme.json` holds the certs and **must be `chmod 600`** or Traefik will refuse to start.
- Routers are declared two ways:
  1. **Docker provider** (`exposedByDefault = false`) — each service adds `traefik.enable=true` and `traefik.http.routers.<name>.*` labels in `docker-compose.yml`. This is the normal path for in-stack services.
  2. **File provider** (`traefik/rules.toml`) — manually-defined routers/services for things running **outside** this container/stack (e.g. `hass`, `grafana`, `nextcloud` on other LAN IPs). Add entries here when pointing Traefik at a non-docker host.
- **Authelia** (`authelia/`) is the auth layer, wired as a Traefik forward-auth middleware (`authelia@docker`). Services that need auth add `traefik.http.routers.<name>.middlewares=authelia@docker`. `configuration.yml` is a Go template (`X_AUTHELIA_CONFIG_FILTERS=template`) that pulls secrets from env vars via `mustEnv`. Authelia authenticates against…
- **lldap** (`lldap/`) — the LDAP user directory (`dc=feignman,dc=online`). `lldap_config.toml` is the runtime config; `lldap_config.docker_template.toml` is the upstream default reference. Both JWT and key-seed secrets are required (generate with `lldap/generate_secrets.sh`).

So a request flow is: Cloudflare → Traefik (:443) → (optional) Authelia forward-auth → the backing container on its internal port.

### Adding a new service
The pattern, mirroring existing services:
1. Add a service block in `docker-compose.yml`.
2. Add `traefik.*` labels with a `Host(`<sub>.feignman.online`)` rule, `entrypoints=websecure`, `tls.certresolver=dns-cloudflare`, and `authelia@docker` in `middlewares` if it should be gated.
3. Add a Cloudflare `A` record for the subdomain pointing at this host's public IP (manual, per README) — Traefik's DNS challenge handles the cert.
4. Bind any new container ports only on the internal network; prefer `expose:` over `ports:` for anything routed through Traefik so it isn't publicly reachable directly. Services that intentionally bypass Traefik (e.g. `plex`, `deluge` use `network_mode: host`, nzbget/deluge have `traefik.enable=false`) are exceptions.

### Host integration details
- **NAS media** lives on a separate TrueNAS box and is bind-mounted at `/truenas/...` (`/truenas/Movies`, `/truenas/Series`, `/truenas/downloads`, `/truenas/Photos`, `/truenas/immich-library`). These paths are host-specific and won't exist outside this LXC.
- **GPU/transcoding**: `plex` and `immich-server` mount `/dev/dri`. `plex` sets `PGID=993` to match the host `render` group for GPU access.
- **PUID/PGID 3002** is the shared media user/group for the `linuxserver/*` images so container-written files match NAS ownership.
- The compose project defines a bridge network `docker-stack-net` at `172.18.0.0/16`. `IMMICH_TRUSTED_PROXIES=172.18.0.0/16` and the Traefik→container hops rely on this subnet — don't renumber it casually.
- `telegraf` runs privileged and bind-mounts `/` to `/rootfs` to scrape host metrics from inside the LXC (config in `telegraf/docker-lxc-host.conf`).
- Immich is a multi-container sub-stack (`immich-server`, `immich-postgres` pinned to a vector-chord image, `immich-redis`/valkey, `immich-machine-learning`); its ML cache lives in the named `model-cache` volume. Karakeep similarly fans out into `karakeep-web`, `karakeep-chrome`, `karakeep-meilisearch`.

### Volumes
Per-service persistent data lives under `./volumes/<service>/` (gitignored). The `volumes/` directory also contains dirs for services no longer in the compose file (e.g. `nextcloud`, `grafana`, `portainer`) — leftovers from prior setups; don't assume a `volumes/` subdir means the service is currently deployed.

## Operational chores

### Updating images
```bash
docker compose pull                    # pull new tags for the whole stack
docker compose pull <service>          # just one service
docker compose up -d                   # recreate anything whose image changed
```
Pinned tags move when `pull` finds a new digest; `latest`/`release` tags move too. After updating, `docker compose logs -f <service>` to confirm it came up healthy. For `immich`, the postgres image is pinned by digest (`@sha256:...`) and immich-server to `v2` — bump those deliberately, not accidentally.

To see which services are behind before pulling, run `./ops/image-status.sh` — it prints a table of current tag, creation date, latest upstream tag, and status (up to date / behind / update available) per running container. Channel tags (`latest`/`stable`/`release`) are checked by digest; version tags by highest `sort -V`. Read its header comment for caveats (best-effort "latest", digest-pinned immich-postgres).

### Cleaning up old images and cruft
```bash
docker image prune -a                  # remove every image not referenced by a running/stopped container (frees the most space)
docker image prune                     # safer: dangling/untagged images only
docker container prune                 # remove stopped containers
docker volume prune                    # remove volumes not used by any container — WARNING: check `docker volume ls` first; named volumes like model-cache hold immich ML models
docker system prune -a --volumes       # NUCLEAR: everything above combined. Only run when you mean it.
```
`docker image prune -a` is the usual lever — it's safe here because images still referenced by a defined-but-stopped service are kept. Don't run `--volumes` variants casually; this stack's data lives in bind mounts under `./volumes/` and in the `model-cache` named volume.

### Backups
Persistent state is in `./volumes/<service>/` (bind mounts) plus the `model-cache` named volume and `traefik/acme.json`. The genuinely hard-to-rebuild bits: `authelia/config/db.sqlite3` (sessions/MFA), `lldap` users, `immich-postgres` (`./volumes/immich/postgres`), and the NAS-mounted `/truenas/immich-library` + `/truenas/Photos`. Back up the `./volumes` tree and `acme.json`; the `model-cache` volume is just a download cache and can be regenerated.

### Certs / Cloudflare
Certs auto-renew via the Traefik `dns-cloudflare` resolver using `CF_DNS_API_TOKEN` — no cron needed. If a subdomain isn't getting a cert, check `docker compose logs traefik` for ACME errors and confirm the Cloudflare `A` record exists and points at this host. The Traefik dashboard is at `https://traefik.feignman.online` behind Authelia.

### Disk / host health
`telegraf` is already scraping host metrics from `/rootfs`. For a quick manual check: `df -h` on the host, and `docker system df` to see how much space images/containers/volumes are using.

## Conventions
- Commit messages follow `[<scope>][<type>] <subject>` (e.g. `[immich][new] ...`, `[fix][secrets] ...`). Match this style when committing.
- `TZ=Europe/Paris` is set throughout; keep new services consistent.
- Keep secrets out of commits — `.gitignore` covers `/secrets/*`, `acme.json`, `duck.log`, and authelia's db/logs. The rbw/direnv env-var flow is the source of truth, not committed files.
