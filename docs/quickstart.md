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
- **Cloudflare account** with the domain (and an API token made during configuration; **Cloudflare
  R2** for the optional restic backups).
- **Tailscale account** — you'll approve the box into your tailnet in the next section and
  register the DNS resolver in [§7](quickstart#7-register-the-tailnet-dns-resolver).
- **GitHub account** — the repo is meant to be forked ([§4](quickstart#4-fork-and-clone-the-repository)).
- **A workstation** on the tailnet with a browser — this is where the admin panels are set up.

## 1. Create the VPS

Any provider, any box with ≥ 2 vCPU / 4 GB RAM (sizing notes in the [overview](index)). Use a
**Debian 12** or **Ubuntu LTS** image — every command in this wiki is written for them. On
Oracle Cloud, use **Ubuntu 26.04 Minimal** instead (no Debian image there);
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
with the compose plugin, and your user in the `docker` group — **and joins the box to
your tailnet**:

```bash
curl -fsSL https://raw.githubusercontent.com/erdemoney/kickstarrt-vps/main/scripts/prerequisites.sh | sudo bash
```

The script prints an **auth URL** and waits up to two minutes — open it in a browser and
approve the node. (Missed the window? `sudo tailscale up` prints it again.) It ends by
printing the box's **tailnet address** — a `100.x.y.z` from Tailscale's CGNAT range. That
address is your SSH address from now on.

The firewall remains open until the deliberate lockdown step in [§6](#6-lock-the-box-down-ufw).

## 3. Verify SSH over the tailnet

From your workstation:

```bash
ssh <user>@100.64.0.3     # the address the script printed
```

Once this works, the public SSH door has done its job — the provider-side `22` rule gets
closed during [§6](#6-lock-the-box-down-ufw). If you use **MagicDNS**, the box also answers at
`<node>.<tailnet>.ts.net`; fine for SSH, but the stack itself routes on `.DOMAIN` names, so
the `100.x.y.z` address is the one that matters later.

> The provider's web console stays available as the **break-glass** door for the box's whole
> life — it rides the provider's network, not yours, so a tailnet hiccup can never lock you
> out. On Oracle Cloud, Ubuntu images configure no console password by default — set one
> (`sudo passwd ubuntu`) so the console can actually log you in when nothing else can; the
> full recovery walkthrough is in the [OCI appendix](oci#3-recovery-the-console-break-glass).

## 4. Fork and clone the repository

Install and authenticate the GitHub CLI. It can create or upload the SSH key used to clone the
private fork:

```bash
sudo apt install gh        # other installers: https://cli.github.com
gh auth login              # choose GitHub.com → SSH; generate or upload a key when offered
```

This repo is meant to be **forked**. Create the fork, then clone it into the standard checkout
directory:

```bash
mkdir -p ~/docker
gh repo fork erdemoney/kickstarrt-vps
gh repo clone <you>/kickstarrt-vps ~/docker/kickstarrt-vps
gh repo edit <you>/kickstarrt-vps --visibility private     # public forks leak any secret you commit
# --- or fork it in the browser ---
```

If you fork in the browser instead, make the fork **private** (Settings → change visibility — a
secret committed to a public fork leaks it to the world), then clone it on the box:

```bash
git clone git@github.com:<you>/kickstarrt-vps.git ~/docker/kickstarrt-vps
cd ~/docker/kickstarrt-vps
```

One housekeeping item first: the `docker` group the bootstrap script put you in only takes
effect in a **new SSH session** — reconnect, then `docker run --rm hello-world` should work
without sudo.

## 5. Configure the stack

Now run `just init` — it creates each stack's private `.env`, detects safe defaults, validates
the values it writes, and prompts only for the settings that need a decision. At any value prompt,
type `?` for a short explanation, an example, and the relevant documentation reference.

- `CONFIG_DIR` isn't asked: always the repo's own `data/` dir — app configs, `acme.json`, and
  Traefik's rendered config live there, and it's exactly what the backups cover.
- `TAILNET_IP` is auto-filled from `tailscale ip -4`; if the configured address later differs,
  init detects the drift and asks before updating it. Update the Tailscale DNS nameserver too.
- `PUBLIC_BIND` is detected from the default route; if it later differs, init asks before
  changing it. On Oracle Cloud this can be the private VCN/VNIC address, not the public address.
- `CROWDSEC_BOUNCER_API_KEY` is generated for you (random 32-byte key).
- `DOMAIN` is prompted once and synced to every stack; each `SUB_DOMAIN_*` is filled with
  the app name as its default and can be edited in the `.env` files later.
- `ENV_PUID`/`ENV_PGID` use the running user's uid/gid, so container files match your user
  (fallback `1000` if you run as root). If an existing installation uses different IDs, init
  reports the mismatch and keeps them; `just init force` can explicitly replace them.
- `ACME_EMAIL` defaults to `admin@<DOMAIN>` — any address on a domain you control; it
  needn't receive mail ([why](faq#why-is-there-no-lets-encrypt-account-to-create)).
- An optional username/password prompt writes `TRAEFIK_DASHBOARD_CREDENTIALS` for the
  [Traefik dashboard](ingress#traefik-dashboard).
- `CLOUDFLARE_DNS_TOKEN` — enter it when ready; `just init` verifies it against Cloudflare.
  Leave it empty to do it later.
- Optionally sets up **restic backups to Cloudflare R2** — answer `y` to be prompted, or skip
  and fill `.env.restic` later ([Maintenance](maintenance)).

It's safe to re-run: values that are already set are kept, so a re-run only asks for what's
missing (e.g. a restic step you deferred) or detects machine values that changed. To re-prompt
optional credentials, run `just init force`. The full variable list, with comments, is in
`stacks/traefik/.env.example` and `stacks/media-server/.env.example`. The main secrets worth
understanding are:

### `CLOUDFLARE_DNS_TOKEN` — Cloudflare (wildcard TLS)

This token is the entire Let's Encrypt prerequisite: DNS-01 is how Traefik proves ownership of
`*.DOMAIN` ([Ingress → Certificates](ingress#certificates)).

1. Open [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) → **Create Token** →
   **Create custom token**, with two permissions on `DOMAIN`:
    - **Zone → Zone → Read** — resolves the domain to a zone ID before any record can be edited.
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

## 6. Lock the box down (ufw)

The tailnet is now your door — this is the conscious step that makes it your **only** door.
`just lockdown` installs and enables ufw, applies the tailnet-only rules, and installs the
ufw-docker forwarding gate in one confirmed operation.

> **Before running this command:** verify that you can access the provider's web, VNC, or
> serial console and that its break-glass credentials work. If the tailnet or SSH session fails,
> that console is the recovery path.

Run the lockdown deliberately:

```bash
just lockdown
```

The command refuses to run unless the box is on the tailnet, asks before changing the firewall,
and verifies UFW plus the **ufw-docker** gate before it reports success. There is deliberately
**no public `22`/`80`/`443` rule**: the public surface opens only at [§12](#12-go-public-last)
with `just go-public`.

Then close the delivery door at the provider: on **Oracle Cloud**, delete the wizard's default
`22` ingress rule (VCN → Default Security List → the `TCP 22 / 0.0.0.0/0` rule → Delete). SSH
now has exactly one way in: your tailnet.

Optional extras — SSH key-only auth (if your provider's image allows passwords) and fail2ban —
are in [Hardening](hardening).

## 7. Register the tailnet DNS resolver

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

## 8. First boot

```bash
just up
```

### Verify the first boot

`just up` runs preparation, creates the networks and config directories, renders the static
configuration, and starts both stacks. Use the read-only health panel for the routine checks:

```bash
just health
just dnscheck
```

From a tailnet device, the expected result is that each configured hostname opens over HTTPS and
the wildcard certificate is valid. Continue with app setup even if Recyclarr is waiting for
`just wire`; that is expected before its secrets exist.

## 9. Set up the apps

Everything is reachable by name over the tailnet and **nothing is public yet** — that's the
window to do first-run setup, while no app can be reached by strangers. The order matters:
Decypharr first, because the \*arrs need its live mount (root folders) and the wiring assumes
it's configured.

1. **Decypharr** — run the wizard: admin account, debrid provider + API key, mount at
   `/mnt/decypharr` → [Decypharr](decypharr#first-run-setup-wizard).
2. **\*arrs** — run `just wire` on the box. It provisions download clients, root folders,
   Arr integrations, Prowlarr sync, Bazarr connections, and Recyclarr's API secrets. Finish
   language profiles and indexer choices in the GUI → [The \*arrs](arrs).
3. **Jellyfin** — create the admin account, add libraries under `/mnt/shows` and `/mnt/movies`,
   and set the transcode path → [Jellyfin](jellyfin).
4. **Seerr** — connect Jellyfin at `http://jellyfin:8096`, then connect Radarr and Sonarr with
   their internal URLs and API keys → [Seerr setup](jellyfin#seerr).
5. **Indexers** — Prowlarr needs at least one before grabs work; Torrentio (debrid) and
   AltHub (Usenet) → [Indexers](indexers).

`just wire --dry-run` previews the changes, and `just wire` applies each confirmed checkpoint.
Minimum before going public: every app has its admin account and auth on — [the security
gate](ingress#the-security-gate).

## 10. Verify the security services

CrowdSec, Traefik, Tailscale, UFW, and the Docker forwarding gate are checked by the same
read-only panel:

```bash
just health
```

## 11. Backups and updates

Set up encrypted offsite backups before exposing the service publicly:

```bash
just init              # answer yes to the Cloudflare R2 backup step
just backup-init
just backup
just backup-schedule   # optional daily systemd timer
```

See [Maintenance](maintenance) for R2 credentials, alternate backends, restores, and retention.

Enable the Renovate workflow once on GitHub:

```bash
gh secret set RENOVATE_TOKEN
```

Then run the **Renovate** workflow once from GitHub Actions. Review its pull requests normally;
after merging one, update the server with `git pull && just update-all`. See [Updates & CI](updates).

## 12. Go public (last)

When every app is set up and has auth on: add the two hostnames users actually need, then open
the serving ports — in that order.

1. In Cloudflare DNS, add **A records** for `seerr.<DOMAIN>` and `jellyfin.<DOMAIN>` pointing
   at the VPS's **public IP**, **Proxy status: DNS only** (grey cloud — never proxied,
   [why](faq#why-cant-i-proxy-media-through-cloudflare)). Detailed steps in
   [Ingress → Adding a public hostname](ingress#adding-a-public-hostname-dns-record).
2. Open the public ports:

```bash
just go-public
```

This runs `ufw allow 443/tcp` (the real way in) and `ufw allow 80/tcp` (an http → https
redirect only — nothing is served on it), after reminding you the A records above are the
other half of the door. Fully reversible with `just go-public close`.

Because the ufw-docker gate routes container traffic through UFW, these two rules are exactly
what lets Docker-forwarded `:443`/`:80` through — the same syntax that opened the tailnet
doors in §6.

That's it — the stack is public on those two hostnames: Cloudflare DNS → VPS `:443` →
Traefik → CrowdSec → the apps. Admin panels stay off the public DNS and are reached over the
tailnet by name ([Tailnet DNS](tailnet)). Fully reversible: delete the records, or
`just go-public close` — the tailnet doors stay intact either way.

From here: [Indexers](indexers) and [Services](services) can be set up any time after the
stack is up; [Updates & CI](updates) and [Maintenance](maintenance) are the ongoing-ops pages.
