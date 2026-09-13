---
title: Overview
nav_order: 1
---

# kickstArrt (VPS edition)

A public-IP media stack run through Docker on a VPS, with a single GitHub repo as the source of
truth for compose files, configs that live in code, and all setup/ops documentation. This is the
**VPS edition** — Cloudflare tunnel ingress (zero inbound ports), no GPU passthrough. If you're
hosting on a home box behind NAT instead (LAN stage, hardware transcoding), use the
[self-hosted edition](https://github.com/erdemoney/kickstarrt). Everything here stays
host-agnostic.

```text
                     Internet
                        |
                        v
              Cloudflare edge (TLS, WAF, geolock)
                        |
                        v
    cloudflared tunnel (dial-out, no inbound ports) ----+   ufw: deny-all; 22 = tailnet only
                        |                               |
                        v                               v
     Traefik :443 ----> CrowdSec (WAF / IP blocking)   Tailscale (console bootstrap → daily ops)
                        |
                        v
            Docker "internal" network
            +-------------------------+
            | jellyfin     seerr      |
            | radarr       sonarr     |
            | prowlarr     bazarr     |
            | profilarr    decypharr  |
            +-------------------------+
```

Media flow: Prowlarr finds releases (incl. the Torrentio debrid indexer) → Sonarr/Radarr grab
them → Decypharr resolves debrid/Usenet into instant files on a FUSE mount → \*arrs import into
the library on the debrid mount → Jellyfin streams to clients; Seerr handles requests from users.

**HTTPS comes out of the box.** Traefik's ACME provider creates the DNS-01 challenge through
Cloudflare (`CLOUDFLARE_DNS_TOKEN`) and issues a **Let's Encrypt wildcard certificate for
`*.DOMAIN`**, automatically renewed — so every service's UI is served over TLS from the public
internet (once you add its [tunnel hostname](ingress)). No per-app TLS configuration is involved.

## VPS sizing

A streaming-only setup like this doesn't need much. **2 vCPU / 4 GB RAM** handles a small house;
**4 vCPU / 8 GB** is comfortable if Jellyfin has to transcode to clients. This stack streams
from debrid and never stores a media library on the host, so disk is just the OS + config —
10–20 GB is plenty (container images plus a bit of headroom).

There is **no GPU passthrough here** — VPS hosts are CPU-only, so Jellyfin transcodes in
software (the `/dev/dri` blocks are deliberately not part of this edition's compose). Keep your
library direct-play friendly (same codec/container as your clients, see [Services](services)) and
you'll rarely transcode at all.

## Operating system

**Debian** (stable) is the safe default — minimal, long support cycles, and every Docker guide
assumes it. Most providers offer a Debian 12 image out of the box. Oracle Cloud doesn't — use
**Ubuntu 24.04 LTS** there (every `apt`/`ufw`/`fail2ban` command in this wiki is identical); the
[Oracle Cloud (free tier)](oci) page walks the full creation. Get the basics right first;
see [Hardening](hardening) for Tailscale (console bootstrap), ufw deny-all, fail2ban, and
non-root Docker before anything goes public.

## Repository layout

```text
stacks/                  compose files (one folder per stack) + .env per stack
  cloudflared/           Cloudflare tunnel edge (dial-out; zero inbound ports)
  traefik/               edge router, CrowdSec container, plugin + ACME
  media-server/          jellyfin, seerr, radarr, sonarr, prowlarr,
                         profilarr, bazarr, decypharr
data/                    runtime config that lives in code
  traefik/               traefik.yml, dynamic.yml, crowdsec-acquis.yaml
.github/                 CI checks (workflow) + Renovate pipeline (workflow + global config)
docs/                    this wiki (GitHub Pages)
justfile                 ops recipes (just up, just update-all, ...)
```

## Page map

| Page                         | What it covers                                                        |
| ---------------------------- | --------------------------------------------------------------------- |
| [Oracle Cloud (free tier)](oci) | free VPS: VCN, subnet, instance, console bootstrap  |
| [Quickstart](quickstart)     | env files, where every secret comes from, tailnet SSH gate, first `just up` |
| [Hardening](hardening)       | Tailscale, ufw deny-all (tailnet-only 22), fail2ban, non-root Docker, SSH keys |
| [The \*arrs](arrs)           | shared networks, internal DNS names, API-key wiring between all apps  |
| [Indexers](indexers)         | Prowlarr, the Torrentio debrid indexer, AltHub                        |
| [Decypharr](decypharr)       | debrid gateway: wizard, arr integration, mounts                       |
| [Ingress](ingress)           | tunnel hostnames: certificates, geolock, Access auth, caching        |
| [Security](security)         | CrowdSec WAF and IP blocking, fail-open/bypass behavior               |
| [Services](services)         | recommended debrid/Usenet subscriptions                               |
| [Updates](updates)           | Renovate PR pipeline + CI checks end to end                           |
| [Maintenance](maintenance)   | day-to-day ops, backups, post-deploy checks                           |

All absolute host paths in this wiki are written as the compose env vars they map to —
`$CONFIG_DIR` (app configs) is the repo's own `data/` dir, written into `stacks/traefik/.env`
and `stacks/media-server/.env` by `just init`. Media is served from the debrid FUSE mount, so
there is no local media directory to configure.

## Additional services

The core stack covers media acquisition, management, and streaming. A few extras pair well if you
want them — drop a compose file into `stacks/` and they'll join the same `internal` network
automatically once you add the folder to `stack_list` in the justfile (and to the stack loop
in `.github/workflows/ci.yml`):

- **Homarr** (`ghcr.io/homarr-labs/homarr`) — lightweight dashboard with widgets for each app.
  Point it at the internal service URLs (`http://sonarr:8989`, ...) and it just works.
- **qBittorrent** — if you prefer local torrents over debrid, add it as an alternative download
  client alongside Decypharr.
- **SABnzbd** — same idea for Usenet: add it as a **Sabnzbd** download client in the \*arrs
  (Decypharr already exposes a compatible API, but a local SABnzbd gives you real Usenet
  downloads to the filesystem).

Client-side extras (nothing to run on the server): **Ruddarr** ([ruddarr.com](https://ruddarr.com)) —
a free, open-source **iOS companion app** for managing Radarr and Sonarr from your phone. It
connects straight to your \*arrs' public URLs, so the admin panels stay admin-only — the app is
just another client, not a published service (see [The \*arrs](arrs)).

## External references

- Decypharr docs: <https://decypharr.com/guides>
- Torrentio indexer definition: <https://github.com/dreulavelle/Prowlarr-Indexers>
- Servarr wiki (Prowlarr quick start): <https://wiki.servarr.com/prowlarr/quick-start-guide>
- CrowdSec documentation: <https://docs.crowdsec.net>