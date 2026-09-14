<div align="center">

# kickst**Arr**t

**A public-IP media stack that runs itself.** Jellyfin + the \*arrs + a debrid gateway, served
directly on a `:443` edge, guarded by CrowdSec, terminated by Traefik — all defined in one repo
and brought up with a single command.

[![CI](https://img.shields.io/github/actions/workflow/status/erdemoney/kickstarrt-vps/ci.yml?logo=githubactions&logoColor=white&label=CI)](https://github.com/erdemoney/kickstarrt-vps/actions)
[![Docs](https://img.shields.io/badge/docs-wiki-blue?logo=readthedocs&logoColor=white)](https://erdemoney.github.io/kickstarrt-vps/)
[![Stack](https://img.shields.io/badge/stack-Docker%20Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![TLS](https://img.shields.io/badge/tls-Let%27s%20Encrypt-2E8B57?logo=letsencrypt&logoColor=white)](https://letsencrypt.org)
[![WAF](https://img.shields.io/badge/waf-CrowdSec-brightgreen)](https://www.crowdsec.net)
[![Tooling](https://img.shields.io/badge/tooling-just-66459B)](https://just.systems)

</div>

---

kickst**Arr**t wires together everything a media library needs — **instant, debrid-based streaming
that keeps nothing on disk**, automatic TLS, and edge security — as code, on a VPS. This is the
**VPS edition**: direct Traefik `:443` ingress (Cloudflare is DNS-only — no video crosses its
network), Tailscale + ufw/fail2ban hardening, no GPU.
Hosting at home instead (LAN stage, hardware transcoding)? Use the
[self-hosted edition](https://github.com/erdemoney/kickstarrt).

## Architecture

```
              Internet
                 │
                 ▼
 Cloudflare DNS (grey-cloud A records + DNS-01 certs; no video traffic)
                 │
                 ▼
  VPS public IP :443 (ufw: 443 opened last; 80 = https-redirect only; 22 tailnet-only)
                 │
                 ▼
  Traefik ────────► CrowdSec   edge WAF / IP blocking
                 │
                 └──────────────┐
                                ▼
                 Docker "internal" network
                 ┌─────────────────────────┐
                 │ jellyfin     seerr      │
                 │ radarr       sonarr     │
                 │ prowlarr     bazarr     │
                 │ profilarr    decypharr  │
                 └─────────────────────────┘
```

**The media loop:** Prowlarr finds releases → Sonarr/Radarr grab them → Decypharr resolves the
torrent against your debrid provider into instant FUSE files → the \*arrs symlink them into the
library → Jellyfin streams to any client. Zero local storage, immediately playable.

## Services

| Service     | Role |
| ----------- | ---- |
| `traefik`   | TLS edge & reverse proxy on `:443` — routes every hostname, issues the wildcard Let's Encrypt cert |
| `crowdsec`  | WAF / IP reputation — blocks scanners at the edge before they reach an app |
| `coredns`   | tailnet DNS — resolves `*.DOMAIN` to the box's tailnet address so admin panels work by name on the tailnet |
| `jellyfin`  | Media server & streaming to web, TV, and mobile clients |
| `seerr`     | User request manager — "want this movie" in one click |
| `radarr` / `sonarr` | Movies and TV automation — grabbing, renaming, library sync |
| `prowlarr`  | Indexer manager, synced to the \*arrs |
| `bazarr`    | Subtitle search & management |
| `profilarr` | Quality-profile sync (trash-guides) |
| `decypharr` | Debrid gateway — resolves grabs to instant FUSE streams |

## Key features

- **Nothing stored locally** — imports are symlinks into the debrid mount: instant, near-zero
  disk usage
- **Automatic TLS** — Traefik issues a `*.DOMAIN` Let's Encrypt wildcard via Cloudflare DNS-01;
  every app UI ships on HTTPS from the public internet
- **Edge security** — CrowdSec WAF inside Traefik, a **deny-incoming ufw** that opens exactly one
  *serving* port (`443`, the last step of setup; `80` is open only for the `http → https`
  redirect; SSH stays inside your tailnet), and the public hostnames are DNS-only records — media
  never rides a third-party edge
- **Private admin panels** — the \*arrs, Decypharr and the Traefik dashboard resolve by name
  *only on your tailnet* (CoreDNS + Tailscale split DNS): `https://radarr.<DOMAIN>` from any
  tailnet device — phone or laptop, browser or Ruddarr — no public records, no extra login (the
  tailnet is the gate); see [Tailnet DNS](https://erdemoney.github.io/kickstarrt-vps/tailnet)
- **Automated upkeep** — Renovate opens dependency PRs and CI validates every change (compose +
  pre-commit + a full secret-history scan)
- **One command to deploy** — `just init` fills the secrets, `just up` creates networks and
  config dirs and starts the stack; back it all up with the built-in restic recipes

## Quick start

> **Note:** this repo is meant to be **forked** — fork it (keep the fork **private**), then
> clone your fork onto the box. A box in this guide is reachable only over your tailnet, so get
> **in first**: [Quickstart → Get in](https://erdemoney.github.io/kickstarrt-vps/quickstart#1-get-in-set-up-tailscale).
> Your deployment secrets never touch the repo; they live in git-ignored
> `.env` files that `just init` creates. Set up every app over an SSH port-forward (nothing
> public yet), then add the A records and open `:443` **last**.

```bash
git clone git@github.com:<you>/kickstarrt-vps.git
cd kickstarrt-vps
just init             # walks every secret; Enter accepts sensible defaults
just up               # networks → config dirs → the whole stack
just hosts 127.0.0.1  # app URLs mapped to localhost (run on the VPS), then:
ssh -N -L 8443:127.0.0.1:443 <you>@<tailnet-host>   # browse https://<subdomain>.DOMAIN:8443
```

Requires [Docker](https://docs.docker.com/engine/install/) (check the
[post-install steps](https://docs.docker.com/engine/install/linux-postinstall/) to run it
non-root) and [just](https://just.systems/man/en/chapter_4.html) — your distro's package manager
or a [release binary](https://github.com/casey/just/releases).
The full walkthrough — hardening, env files, SSH port-forward gate, staging CA, first bring-up —
is in the [Quickstart](https://erdemoney.github.io/kickstarrt-vps/quickstart).

## Docs

- [**Quickstart**](https://erdemoney.github.io/kickstarrt-vps/quickstart) — get in via Tailscale, fork, hardening, env files, first bring-up
- [**Oracle Cloud (free tier)**](https://erdemoney.github.io/kickstarrt-vps/oci) — free VPS: VCN, subnet, instance, console bootstrap
- [**Hardening**](https://erdemoney.github.io/kickstarrt-vps/hardening) — Tailscale, ufw deny-incoming, fail2ban, non-root Docker
- [**Services**](https://erdemoney.github.io/kickstarrt-vps/services) · [**The \*arrs**](https://erdemoney.github.io/kickstarrt-vps/arrs) · [**Decypharr**](https://erdemoney.github.io/kickstarrt-vps/decypharr) · [**Indexers**](https://erdemoney.github.io/kickstarrt-vps/indexers)
- [**Ingress**](https://erdemoney.github.io/kickstarrt-vps/ingress) — direct `:443`: DNS records, TLS, security gate, dashboard
- [**Security**](https://erdemoney.github.io/kickstarrt-vps/security) — CrowdSec WAF
- [**Maintenance**](https://erdemoney.github.io/kickstarrt-vps/maintenance) — backups, restic, restores
- [**Updates & CI**](https://erdemoney.github.io/kickstarrt-vps/updates) — Renovate, validation, releases