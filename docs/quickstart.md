---
title: Quickstart
nav_order: 2
---

# Quickstart

The whole setup, in the order it has to happen. Every command you need is on this page; each
step links to a deeper page for the how-it-works and troubleshooting.

The flow: bring up a fresh VPS, walk in over public SSH **once**, join the box to your
Tailscale tailnet, close every other door, then build the stack and set it up privately over
the tailnet. The box is reachable from exactly one place — your tailnet — until the last step
deliberately opens `:443`.

Before you start, have:

- **A VPS** — any provider, ≥ 2 vCPU / 4 GB RAM ([sizing](index)), with SSH access you can
  reach. Bring it up in the next section.
- **A domain you control** — used for every panel URL (`radarr.<DOMAIN>`, …) and the wildcard
  TLS cert, so pick something you can keep. It should be **served by Cloudflare** (DNS records,
  the DNS-01 cert challenge, and R2 backups all live there): move the domain's nameservers to
  Cloudflare first if it isn't already.
- **Cloudflare account** with the domain (and an API token made during section 5; **Cloudflare
  R2** for the optional restic backups).
- **Tailscale account** — you'll approve the box into your tailnet in the next section and
  register the DNS resolver in [§6](quickstart#6-register-the-tailnet-dns-resolver).
- **GitHub account** — the repo is meant to be forked ([§5](quickstart#5-fork-clone-and-fill-the-secrets)).
- **A workstation** on the tailnet with a browser — this is where the admin panels are set up.

## 1. Create the VPS

Any provider, any box with ≥ 2 vCPU / 4 GB RAM (sizing notes in the [overview](index)). Use a
**Debian 12** or **Ubuntu LTS** image — every command in this wiki is written for them. On
Oracle Cloud, use **Canonical Ubuntu 26.04 Minimal aarch64** instead (no Debian image there);
the [OCI appendix](oci) walks the whole creation, including the `443`/`80` ingress rules
you'll need much later.

The one thing you need from the provider: SSH access to the fresh box (a key you injected at
creation, or however the provider does first login).

## 2. Get in: join the tailnet

SSH in over the **public IP** — the one and only time you use it:

```bash
ssh <user>@<PUBLIC-IP>
```

Then bootstrap the box with this repo's setup script. It is **idempotent** (safe to re-run)
and cross-distro, and installs everything the rest of this guide needs — `git`, `just`, Docker
with the compose plugin, your user in the `docker` group — **and joins the box to your
tailnet**:

```bash
curl -fsSL https://raw.githubusercontent.com/erdemoney/kickstarrt-vps/main/scripts/prerequisites.sh | sudo bash
```

The script prints an **auth URL** and waits up to two minutes — open it in a browser and
approve the node. (Missed the window? `sudo tailscale up` prints it again.) It ends by
printing the box's **tailnet address** — a `100.x.y.z` from Tailscale's CGNAT range. That
address is your SSH address from now on.

## 3. Verify SSH over the tailnet

From your workstation:

```bash
ssh <user>@100.64.0.3     # the address the script printed
```

Once this works, the public SSH door has done its job — the provider-side `22` rule gets
closed in the next step. If you use **MagicDNS**, the box also answers at
`<node>.<tailnet>.ts.net`; fine for SSH, but the stack itself routes on `.DOMAIN` names, so
the `100.x.y.z` address is the one that matters later.

> The provider's web console stays available as the **break-glass** door for the box's whole
> life — it rides the provider's network, not yours, so a tailnet hiccup can never lock you
> out. Caveat on Oracle Cloud: Ubuntu images there configure no console password, so your SSH
> key is the only way in ([details](oci#after-creation)).

## 4. Lock the box down (ufw)

The tailnet is now your only door — enforce it. While the box is reachable only from your
tailnet, update the OS and switch the firewall to deny-incoming, with sshd, DNS, and Traefik
reachable **from the tailnet only**:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 53 proto udp
sudo ufw allow from 100.64.0.0/10 to any port 53 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 443 proto tcp
sudo ufw enable
```

`100.64.0.0/10` is the CGNAT range Tailscale uses — nothing but your tailnet can reach `22`
(sshd), `53` (the [tailnet DNS](tailnet) resolver), and `443` (Traefik). There is deliberately
**no public `22`/`80`/`443` rule**: the public surface opens only at
[§10](#10-go-public-last).

Then close the delivery door at the provider: on **Oracle Cloud**, delete the wizard's default
`22` ingress rule (VCN → Default Security List → the `TCP 22 / 0.0.0.0/0` rule → Delete). SSH
now has exactly one way in: your tailnet.

Optional extras — SSH key-only auth (if your provider's image allows passwords) and fail2ban —
are in [Hardening](hardening).

## 5. Fork, clone, and fill the secrets

First give git an identity and an authentication path on the box. The GitHub CLI (`gh`) is the
easiest way — it generates the SSH key and uploads it to GitHub for you, no keypairs to manage:

```bash
sudo apt install gh        # not in your distro's repos? follow https://cli.github.com
git config --global user.name  "<you>"
git config --global user.email "you@example.com"
gh auth login              # GitHub.com > SSH > "Generate a new key", upload it
```

This repo is meant to be **forked**, and `gh` can fork + clone in one command:

```bash
cd ~/docker
gh repo fork erdemoney/kickstarrt-vps --clone --remote
gh repo edit --visibility private     # public forks leak any secret you commit
# --- or fork it in the browser ---
```

If you fork in the browser instead, make the fork **private** (Settings → change visibility — a
secret committed to a public fork leaks it to the world), then clone it on the box:

```bash
git clone git@github.com:<you>/kickstarrt-vps.git ~/docker/kickstarrt-vps
cd ~/docker/kickstarrt-vps
git remote add upstream git@github.com:erdemoney/kickstarrt-vps.git   # optional
```

One housekeeping item first: the `docker` group the bootstrap script put you in only takes
effect in a **new SSH session** — reconnect, then `docker run --rm hello-world` should work
without sudo.

Now run `just init` — it creates each stack's `.env`, prints the values it generates itself
up front, then walks you through the rest:

- `CONFIG_DIR` isn't asked: always the repo's own `data/` dir — app configs, `acme.json`, and
  Traefik's rendered config live there, and it's exactly what the backups cover.
- `TAILNET_IP` is auto-filled from `tailscale ip -4` — you're only prompted when the CLI
  can't answer (e.g. Tailscale isn't up yet).
- `CROWDSEC_BOUNCER_API_KEY` is generated for you (random 32-byte key).
- `DOMAIN` is prompted once and synced to every stack; each `SUB_DOMAIN_*` is offered with
  the app name as its default (Enter accepts, type to change).
- `ENV_PUID`/`ENV_PGID` propose the running user's uid/gid, so container files match your
  user (fallback `1000` if you run as root).
- `ACME_EMAIL` defaults to `admin@<DOMAIN>` — any address on a domain you control; it
  needn't receive mail ([why](faq#why-is-there-no-lets-encrypt-account-to-create)).
- A username/password prompt writes `TRAEFIK_DASHBOARD_CREDENTIALS`.
- `CLOUDFLARE_DNS_TOKEN` — `just init` explains each permission, then **confirms before
  opening the Cloudflare page in your browser** (on a headless box it just prints the URL).
  Leave it empty to do it later.
- Optionally sets up **restic backups to Cloudflare R2** — answer `y` to be prompted, or skip
  and fill `.env.restic` later ([Maintenance](maintenance)).

Empty answers accept the offered default, and it's safe to re-run: values that are already
set are skipped, so a re-run only asks for what's missing (e.g. a restic step you deferred).
To change a set value, run `just init force` — everything is re-prompted, and Enter keeps
the current value. The full variable list, with comments, is in `stacks/*/.env.example`. The
three secrets worth understanding:

### `CLOUDFLARE_DNS_TOKEN` — Cloudflare (wildcard TLS)

This token is the entire Let's Encrypt prerequisite: DNS-01 is how Traefik proves ownership of
`*.DOMAIN` ([Ingress → Certificates](ingress#certificates)).

1. dash.cloudflare.com → **My Profile** → **API Tokens** → **Create Token** →
   **Create custom token**, with two permissions on `DOMAIN`:
   - **Zone → Read** — resolves the domain to a zone ID before any record can be edited.
   - **Zone → DNS → Edit** — creates and deletes the `_acme-challenge` TXT records.
2. **Zone Resources** → **Include** → **Specific zone** → your `DOMAIN` (least privilege —
   not "All zones").
3. Create — `just init` verifies the token against Cloudflare's API right after you enter it,
   so a bad paste or revoked token fails immediately. To re-check an existing token:

```bash
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer <token>"   # expect "status": "active"
```

### `TRAEFIK_DASHBOARD_CREDENTIALS` — htpasswd blob

A `user:hash` pair for `https://traefik.<DOMAIN>`, not a token:

```bash
docker run --rm httpd:2.4-alpine htpasswd -nbB user 'ChangeMe-strong-password'
```

`.env` gotcha: the `$2y$...` hash breaks compose interpolation — **quote the whole value in
single quotes**:

```
TRAEFIK_DASHBOARD_CREDENTIALS='user:$2y$05$abcdefghijklmnopqrstuvwxyz0123456789'
```

### `CROWDSEC_BOUNCER_API_KEY` — local random key

Already generated by `just init`; by hand it's `openssl rand -hex 32`. No dashboard to sign up
for — CrowdSec and Traefik use it to authenticate with each other. It must be set **before**
`just up`; after changing it, recreate the `crowdsec` and `traefik` containers
(`just update-all`). Details in [Security](security).

## 6. Register the tailnet DNS resolver

One-time step in the Tailscale admin console, done **before** first boot so every app answers
by name the moment the stack is up. The resolver is the CoreDNS container in the traefik
stack, answering `*.DOMAIN` with the box's tailnet address — mechanics and assumptions in
[Tailnet DNS](tailnet).

```bash
just dns     # prints the nameserver value to paste (your TAILNET_IP)
```

1. [Tailscale Admin → DNS](https://login.tailscale.com/admin/dns) → **Nameservers** →
   **Add nameserver** → **Custom**.
2. Enter the value `just dns` printed (a `100.x.y.z`).
3. Constrain it: **"Only send names in these domains"** → add your `DOMAIN` (*not* the
   `.ts.net` name).
4. Leave **MagicDNS** on and **"Override local DNS"** off. Save, then refresh DNS on your
   devices — rejoin the tailnet, or flush: `sudo dscacheutil -flushcache` (macOS),
   `sudo systemctl restart systemd-resolved` (Linux), `ipconfig /flushdns` (Windows).

Until the stack boots (next step), `*.DOMAIN` lookups won't answer: split DNS intercepts the
domain with no fallback, and nothing is listening yet. Expected — it heals at first boot.

## 7. First boot

```bash
just up          # creates networks, config dirs, acme.json + rendered traefik.yml, then brings up every stack
just ps          # confirm everything is running
just dnscheck    # confirm the resolver answers: radarr.<DOMAIN> -> your tailnet IP
```

What to check right after boot:

- Every app answers at `https://<subdomain>.<DOMAIN>` **from any tailnet device** —
  `jellyfin`, `seerr`, `radarr`, `sonarr`, `prowlarr`, `bazarr`, `decypharr`, `traefik` —
  with the real wildcard cert, issued by DNS-01 before any DNS record exists.
- A `Certificate` for `*.DOMAIN` appears in the Traefik dashboard's ACME panel (the first
  Traefik start also downloads the CrowdSec plugin — both need outbound internet).
- CrowdSec seeded its config under `$CONFIG_DIR/crowdsec/config` ([Security](security)).
- Recyclarr applies the shipped **Direct Play** quality profile to Radarr/Sonarr within a
  minute of the arrs being up (`docker logs recyclarr`) — see
  [The \*arrs](arrs#quality-profiles-recyclarr--automatic).
- Jellyfin's admin account is created on first login (its API key feeds Seerr in §8).

## 8. Set up the apps

Everything is reachable by name over the tailnet and **nothing is public yet** — that's the
window to do first-run setup, while no app can be reached by strangers. The order matters:
Decypharr first, because the \*arrs need its live mount (root folders) and the wiring assumes
it's configured.

1. **Decypharr** — run the wizard: admin account, debrid provider + API key, mount at
   `/mnt/decypharr` → [Decypharr](decypharr#first-run-setup-wizard).
2. **\*arrs** — one pass through each app: download clients pointing at Decypharr, root
   folders on the mount, Prowlarr app sync, Seerr → Jellyfin/Radarr/Sonarr, Bazarr language
   profiles → [The \*arrs](arrs). Quality profiles need no step: Recyclarr applies the
   shipped **Direct Play** profile automatically (§7) — just pick it where an app asks.
3. **Indexers** — Prowlarr needs at least one before grabs work; Torrentio (debrid) and
   AltHub (Usenet) → [Indexers](indexers).
4. **Jellyfin** — libraries pointing at subpaths of `/mnt/decypharr`, transcode path and the
   per-user no-video-transcode policy → [Jellyfin](jellyfin).

`just wiring` (run on the box) probes the internal network and prints every URL + API key you
need to paste, including the full Decypharr client spec. Minimum before going public: every
app has its admin account and auth on — [the security gate](ingress#the-security-gate).

## 9. Verify the WAF (CrowdSec)

CrowdSec is already running in the traefik stack, guarding every https router
([Security](security)). Confirm the bouncer authenticated and that blocking actually works:

```bash
docker exec crowdsec cscli bouncers list                     # expect the traefik bouncer
docker exec crowdsec cscli decisions add --ip <your-public-ip> -d 10m   # then expect 403
docker exec crowdsec cscli decisions delete --ip <your-public-ip>       # unban
```

## 10. Go public (last)

When every app is set up and has auth on: add the two hostnames users actually need, then open
the serving ports — in that order.

1. In Cloudflare DNS, add **A records** for `seerr.<DOMAIN>` and `jellyfin.<DOMAIN>` pointing
   at the VPS's **public IP**, **Proxy status: DNS only** (grey cloud — never proxied,
   [why](faq#why-cant-i-proxy-media-through-cloudflare)). Detailed steps in
   [Ingress → Adding a public hostname](ingress#adding-a-public-hostname-dns-record).
2. Open the public ports:

```bash
sudo ufw allow 443/tcp     # the real way in
sudo ufw allow 80/tcp      # http -> https redirect only; nothing is served on it
```

That's it — the stack is public on those two hostnames: Cloudflare DNS → VPS `:443` →
Traefik → CrowdSec → the apps. Admin panels stay off the public DNS and are reached over the
tailnet by name ([Tailnet DNS](tailnet)). Fully reversible: delete the records, or
`sudo ufw delete allow 443/tcp` and `allow 80/tcp` — the tailnet doors stay intact either way.

From here: [Indexers](indexers) and [Services](services) can be set up any time after the
stack is up; [Updates & CI](updates) and [Maintenance](maintenance) are the ongoing-ops pages.
