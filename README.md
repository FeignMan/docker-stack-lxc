# Docker Stack (LXC)
A stack of services orchestrated with docker compose, running inside of a LXC container of my Proxmox home server.

# Provisioning
Provisioning required utilities/tools/packages is supposed to be done with the provision.sh script. Running it inside a fresh LXC container running a Ubuntu 24.04 template, is _supposed_ to get the LXC container ready for starting the stack with `docker compose up -d`

# Requirements
## acme.json
The `./traefik/acme.json` file is supposed to be created with file permissions set to _600_.

## Secrets
Secrets are supposed to exist at the ./secrets/ path. List of required secrets below:
| Secret File | Description |
|-------------|-------------|
| `cf_dns_api_token` | Cloudflare DNS API Token |
| `email` | Personal email address: Used for Cloudflare |

# How To...
## Start Services
```bash
docker compose up -d
```

## Add a Sub-Domain in Cloudflare
- Go to the [cloudflare dashboard](https://dash.cloudflare.com/d82fc935eaa0d4e230c219d03417590f/feignman.online/dns/records)
- Add a DNS record of type `A`, with Name being the prefix of the subdomain, and the public IPv4 address. 