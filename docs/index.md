---
title: Overview
nav_order: 1
---

# kickstArrt (VPS edition)

A public-IP media stack run through Docker on a VPS, with a single GitHub repo as the source
of truth for compose files, configs that live in code, and all setup/ops documentation. This
is the **VPS edition** — direct Traefik `:443` ingress (Cloudflare is DNS-only), no GPU. For
a home box behind NAT with hardware transcoding, use the
[self-hosted edition](https://github.com/erdemoney/kickstarrt) instead.

```text
                      Internet
                          |
                          v
          Cloudflare DNS (grey-cloud A records + DNS-01 certs; no video traffic)
                          |
                          v
             VPS public IP :443  (ufw: 443 opened last; 80 = https-redirect only; 22 = tailnet only)
                          |
                          v
      Traefik :443 ----> CrowdSec (WAF / IP blocking)      Tailscale (join after first SSH -> daily ops)
                          |
                          v
              Docker "internal" network
              +-------------------------+
              | jellyfin     seerr      |
              | radarr       sonarr     |
              | prowlarr     bazarr     |
              | recyclarr    decypharr  |
              +-------------------------+
```

Media flow: Prowlarr finds releases (incl. the Torrentio debrid indexer) → Sonarr/Radarr grab
them → Decypharr resolves them into instant files on a FUSE mount → the \*arrs symlink them
into the library → Jellyfin streams to any client; Seerr handles user requests.

## The access model

The one fact to hold onto throughout setup, stated once here: the box answers the public
internet from **exactly one serving port — `443` (Traefik)**, plus `80` as a pure
`http → https` redirect, and both are opened deliberately as the
[last setup step](quickstart#10-go-public-last). **Everything else is tailnet-only**: sshd,
the DNS resolver, and all the admin panels, reached by name via [Tailnet DNS](tailnet). The
whole setup runs inside that private window — the reasoning behind these choices is
collected in the [FAQ](faq).

**HTTPS comes out of the box.** Traefik's ACME provider issues a **Let's Encrypt wildcard
certificate for `*.DOMAIN`** via the Cloudflare DNS-01 challenge (`CLOUDFLARE_DNS_TOKEN`),
renewed automatically — every service's UI ships on HTTPS from the public internet the moment
you point its [A record](ingress) at the VPS, and on the tailnet before that. No per-app TLS
configuration is involved.

## VPS sizing

A streaming-only setup like this doesn't need much. **2 vCPU / 4 GB RAM** handles a small
house; **4 vCPU / 8 GB** is comfortable if Jellyfin has to transcode to clients. The stack
streams from debrid and never stores a media library on the host, so disk is just the OS +
config — 10–20 GB is plenty (container images plus a bit of headroom).

There is **no GPU passthrough here** — VPS hosts are CPU-only, so Jellyfin transcodes in
software. Keep your library direct-play friendly (same codec/container as your clients) and
you'll rarely transcode at all ([FAQ](faq#why-does-jellyfin-transcode-in-software-no-gpu)).

## Operating system

**Debian** (stable) is the safe default — minimal, long support cycles, and every Docker
guide assumes it. Most providers offer a Debian 12 image out of the box; Oracle Cloud
doesn't, so use **Ubuntu 26.04 Minimal aarch64** there instead (every `apt`/`ufw`/`fail2ban`
command in this wiki is identical). The full Oracle walkthrough is the
[OCI appendix](oci).

## Repository layout

```text
stacks/                  compose files (one folder per stack) + .env per stack
  traefik/               edge router on :443, CrowdSec container, CoreDNS, plugin + ACME
  media-server/          jellyfin, seerr, radarr, sonarr, prowlarr,
                         recyclarr, bazarr, decypharr
data/                    runtime config that lives in code
  traefik/               traefik.yml, dynamic.yml, crowdsec-acquis.yaml
  recyclarr/             shipped Direct Play quality profiles + bootstrap (synced by recyclarr)
.github/                 CI checks (workflow) + Renovate pipeline (workflow + global config)
docs/                    this wiki (GitHub Pages)
justfile                 ops recipes (just up, just update-all, ...)
```

## Page map

Read the pages in order for a first deploy; after that they're reference.

| Page                         | What it covers                                                        |
| ---------------------------- | --------------------------------------------------------------------- |
| [Quickstart](quickstart)     | the ordered walkthrough: get in via Tailscale, harden, init, first boot, app setup, go public |
| [Hardening](hardening)       | optional extras: SSH key-only auth, fail2ban, non-root Docker         |
| [Tailnet DNS](tailnet)       | admin panels by name over the tailnet: CoreDNS + split DNS mechanics |
| [Decypharr](decypharr)       | debrid gateway: wizard, mounts, its side of the arr wiring            |
| [The \*arrs](arrs)           | app wiring: internal DNS names, API keys, download clients, mounts; the Recyclarr-synced quality profiles |
| [Jellyfin](jellyfin)         | playback setup: libraries on the Decypharr mount, no-video-transcode policy |
| [Indexers](indexers)         | Prowlarr, the Torrentio debrid indexer, AltHub                        |
| [Security](security)         | CrowdSec WAF: components and behavior defaults                        |
| [Ingress](ingress)           | direct `:443`: the security gate, DNS records, certificates, dashboard |
| [Services](services)         | recommended debrid/Usenet subscriptions                               |
| [Updates](updates)           | Renovate PR pipeline + CI checks end to end                           |
| [Maintenance](maintenance)   | ops recipes, backups, troubleshooting                                 |
| [FAQ](faq)                   | the design decisions, answered                                        |
| [Oracle Cloud (free tier)](oci) | appendix: free VPS from zero to a running box                        |

All absolute host paths in this wiki are written as the compose env vars they map to —
`$CONFIG_DIR` (app configs) is the repo's own `data/` dir, written into
`stacks/traefik/.env` and `stacks/media-server/.env` by `just init`. Media is served from
the debrid FUSE mount, so there is no local media directory to configure.

## Additional services

The core stack covers media acquisition, management, and streaming. A few extras pair well if
you want them — drop a compose file into `stacks/` and they'll join the same `internal`
network automatically once you add the folder to `stack_list` in the justfile (and to the
stack loop in `.github/workflows/ci.yml`):

- **Homarr** (`ghcr.io/homarr-labs/homarr`) — lightweight dashboard with widgets for each app.
  Point it at the internal service URLs (`http://sonarr:8989`, ...) and it just works.
- **qBittorrent** — if you prefer local torrents over debrid, add it as an alternative
  download client alongside Decypharr.
- **SABnzbd** — same idea for Usenet: add it as a **Sabnzbd** download client in the \*arrs
  (Decypharr already exposes a compatible API, but a local SABnzbd gives you real Usenet
  downloads to the filesystem).

For managing Radarr/Sonarr from your phone, see [Ruddarr](arrs#managing-from-your-phone).

## External references

- Decypharr docs: <https://decypharr.com/guides>
- Torrentio indexer definition: <https://github.com/dreulavelle/Prowlarr-Indexers>
- Servarr wiki (Prowlarr quick start): <https://wiki.servarr.com/prowlarr/quick-start-guide>
- CrowdSec documentation: <https://docs.crowdsec.net>
