---
title: Quickstart
nav_order: 3
---

# Quickstart

No VPS yet? [Oracle Cloud (free tier)](oci) gets you a free one in about ten minutes — VCN,
subnet, instance, console access, all with zero publicly open ports.

Otherwise: bring the stack up on a fresh VPS running Docker, from a git checkout of this repo
(clone it
into whatever directory will run the stack — e.g. `~/docker/kickstarrt-vps`). Edit on a dev box,
commit, and `git pull` on the server.

The steps below are the whole setup, in the order they have to happen. A box in this guide is
reachable from **exactly one place: your Tailscale tailnet**. Every other door is closed by
design ([Hardening](hardening)) and stays closed until you deliberately open `:443` at the very
end. So the first thing that happens on a brand-new box is its **join to the tailnet** — an
[Oracle Cloud](oci) box does it *at creation* (a cloud-init seed), any other box does it the
moment you bootstrap it. Only then can you log in at all.

## 1. Get in: set up Tailscale

Do this the moment the instance is up; nothing else works until it does. How depends on the
provider's first-boot automation:

- **On an [Oracle Cloud](oci) box the join already happened** — the Initialization script you
  pasted at creation did it, with your SSH key pasted right next to it. There was no console login
  involved (Ubuntu's console can't log in anyway — no password is configured). Find the
  `kickstarrt` node in the Tailscale admin console, note its tailnet address, and SSH in; skip
  ahead to [§3 Finish hardening](#3-finish-hardening-the-box). If the node doesn't show up within
  a few minutes, a bounded **rescue window** is still open: the provider's `22` ingress rule isn't
  removed until §3, so `ssh ubuntu@<PUBLIC-IP>` with your key gets you in to fix the join
  ([OCI → After creation](oci#after-creation)).
- **On any other provider**, open its **out-of-band console** and run the bootstrap one-liner
  below. It's **idempotent** (safe to re-run — anything present is skipped), **cross-distro**
  (Debian/Ubuntu, Fedora/RHEL, openSUSE, Arch, Alpine), and installs Tailscale **plus** everything
  later steps need — `git`, `just`, Docker with the compose plugin, and your user in the `docker`
  group:
  [`scripts/prerequisites.sh`](https://github.com/erdemoney/kickstarrt-vps/blob/main/scripts/prerequisites.sh)

```bash
curl -fsSL https://raw.githubusercontent.com/erdemoney/kickstarrt-vps/main/scripts/prerequisites.sh | sudo bash
```

(The URL points at the public upstream repo, so it runs before you've cloned anything.) The
script installs Tailscale **and joins the box to your tailnet**: it prints an **auth URL**, waits
up to two minutes for you to approve the node in your browser, then prints the box's tailnet
address. Approval is always yours — if the window passes before you approve, join it yourself:

```bash
sudo tailscale up
tailscale ip -4        # e.g. 100.64.0.3 — a 100.x.y.z from Tailscale's CGNAT range
```

`tailscale up` prints an **auth URL** — open it in your browser and approve the node.

That tailnet address is the **only place SSH ever answers** — and how you get in from your
workstation:

```bash
ssh ubuntu@100.64.0.3    # OCI's default user; your provider may differ
```

Notes:

- The first `ssh` needs your key on the box — a cloud-init seed (OCI) has it from creation; on a
  box you bootstrapped by hand, add your workstation's public key to `~/.ssh/authorized_keys`
  while you're still in the console (it rides the console shell, which isn't limited by sshd;
  details in [Hardening §4](hardening#4-ssh-keys-no-password-auth)).
- If you enabled **MagicDNS** (Tailscale admin console → DNS, on by default), the box also
  answers at `vps.<tailnet>.ts.net` — fine for SSH, though the stack routes on `.DOMAIN` host
  names, so the `TAILNET_IP` [env value](#4-copy-and-fill-the-env-files) is the address that
  matters.
- Replacing the box later? The address changes — re-run the bootstrap script (it rejoins with a
  fresh wait), or `sudo tailscale up` on the new box, then point `TAILNET_IP` at the new address
  via `just init` ([Tailnet DNS](tailnet)).
- The provider console stays available as the **break-glass** door for the box's whole life: it
  rides the provider's network, not yours, so a tailnet hiccup can never lock you out. One
  caveat: on [OCI](oci), Canonical Ubuntu images configure no console password, so the console
  can't log you in by design — recovery there is the volume-attach rescue, which is why access is
  seeded at creation.

Everything from here on happens over SSH — the console isn't needed again.

## 2. Fork and clone

This repo is meant to be **forked**. Fork it to your own GitHub account, then clone your fork —
that gives you a personal copy to customize while still being able to pull upstream improvements.
**Make the fork `Private`** (Settings → change visibility) — it
deploys this stack from your fork, and a misstep that commits a secret to a public fork leaks it
to the world:

```bash
git clone git@github.com:<you>/kickstarrt-vps.git ~/docker/kickstarrt-vps
cd ~/docker/kickstarrt-vps
git remote add upstream git@github.com:erdemoney/kickstarrt-vps.git   # optional
```

## 3. Finish hardening the box

`git`, `just`, Docker and Tailscale all came from the bootstrap script in
[§1](#1-get-in-set-up-tailscale). `git` works straight away; the `docker` group from that script
only takes effect in a **new SSH session** — log out and back in (or `newgrp docker`), then
verify:

```bash
docker run --rm hello-world     # no sudo needed once the group is active
just --version
```

Update the OS and lock the firewall down while the box is still reachable only from your
tailnet. SSH — and the tailnet DNS resolver, [Tailnet DNS](tailnet) — get in from **only** the
tailnet; `80`/`443` stay closed until [Going public](#going-public-last):

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 53 proto udp
sudo ufw allow from 100.64.0.0/10 to any port 53 proto tcp
sudo ufw enable
```

Also close the setup-time SSH window at the provider: on **Oracle Cloud**, delete the wizard's
default `22` ingress rule (VCN → Default Security List → the `TCP 22 / 0.0.0.0/0` rule → Delete —
[OCI §1](oci#1-virtual-cloud-network-vcn--via-the-vcn-wizard)). It was a rescue door for the
first login only; from here SSH has exactly one way in, your tailnet.

Then, over at [Hardening](hardening): switch SSH to key-only auth (§4) and add fail2ban (§6,
optional belt-and-suspenders). After that it's safe to run `just init` and `just up` as yourself.

## 4. Copy and fill the env files

Run `just init` — it creates each stack's `.env` and walks you through **every** variable:

- `CONFIG_DIR` isn't asked: it's automatically set to a full path to this repo's `data/` dir,
  where app configs, `acme.json`, and Traefik's rendered config live (and what the restic
  backup covers). It isn't user-configurable — the `just` recipes expect the repo-defined place
- `DOMAIN` is prompted once and synced to every stack that defines it (traefik, media-server)
- Subdomains default to the example values — Enter to keep, type to change;
  `ENV_PUID`/`ENV_PGID` instead propose the uid/gid of the user running `just` (Enter to
  use), so container files match your user — they fall back to `1000` if you run as root
- `ACME_EMAIL` defaults to `admin@<DOMAIN>` — Enter accepts it. There is **no Let's Encrypt
  account to register** (Traefik creates one over ACME on first start) and the address needn't
  receive mail, but it can't be a fake domain like `example.com` — their API rejects those.
  See [Ingress](ingress#there-is-no-lets-encrypt-account-to-create)
- `TAILNET_IP` is auto-filled from `tailscale ip -4` (the box's tailnet address) — the CoreDNS
  resolver in the traefik stack answers `*.DOMAIN` with it, so admin panels resolve by name on
  the tailnet ([Tailnet DNS](tailnet)); accept it unless Tailscale reports a different address
- `CROWDSEC_BOUNCER_API_KEY` is generated automatically (random 32-byte key)
- Prompts for a username/password and writes `TRAEFIK_DASHBOARD_CREDENTIALS`
- Explains each Cloudflare secret, then **confirms before opening the page in your
  browser** (and just shows the URL on a headless box) — `CLOUDFLARE_DNS_TOKEN` (TLS, below) —
  leave empty to do it later. There is no tunnel token: this edition serves on its own public
  IP and uses Cloudflare only for **DNS + DNS-01 certificates**
- You can skip anything; empty answers fall back to the current/default value
- Finishes by asking whether to set up **restic repo backups to Cloudflare R2** — answer
  `y` to be prompted for the R2 account ID, bucket, API token, and encryption password
  (see [Maintenance](maintenance)), or skip (Enter) and fill `.env.restic` later

```bash
just init
```

Safe to re-run — it shows the current values and never overwrites without your say-so.

Set each variable (see `stacks/*/.env.example`):

| Variable                        | Where it lives | What it's for                                                    |
| ------------------------------- | -------------- | ---------------------------------------------------------------- |
| `DOMAIN`                        | traefik + media-server | apex domain; every `SUB_DOMAIN_*` entry extends it       |
| `SUB_DOMAIN_*`                  | per stack      | public subdomain per app, e.g. `jellyfin.<DOMAIN>`               |
| `CONFIG_DIR`                    | traefik + media-server | app config dir — derived, always the repo's `data/` dir  |
| `ACME_EMAIL`                    | traefik        | Let's Encrypt account address (rendered into `traefik.yml`)      |
| `ENV_PUID` / `ENV_PGID`         | media-server   | user/group owning the config dirs (init proposes the running user's ids) |
| `CLOUDFLARE_DNS_TOKEN`              | traefik        | DNS-01 ACME for wildcard certs (see below)                       |
| `TRAEFIK_DASHBOARD_CREDENTIALS` | traefik        | dashboard basic-auth blob (see below)                            |
| `CROWDSEC_BOUNCER_API_KEY`      | traefik        | CrowdSec ↔ Traefik shared key (see below)                       |

## 5. Where the secrets come from

### `CLOUDFLARE_DNS_TOKEN` — Cloudflare (wildcard TLS)

This token *is* the entire Let's Encrypt prerequisite — DNS-01 is how Traefik proves it owns
`*.DOMAIN`. Nothing has to be set up at Let's Encrypt itself; see
[Ingress → Certificates](ingress#certificates-automatic).

1. dash.cloudflare.com → **My Profile** → **API Tokens** → **Create Token**.
2. **Create custom token** with two permissions, both on `DOMAIN`:
   - **Zone → Read** — Traefik must resolve the domain to a **zone ID** before it can edit
     records; that lookup needs `Zone:Read` even though the token will only ever create
     `_acme-challenge` TXT records.
   - **Zone → DNS → Edit** — *the* DNS-01 permission: create and delete those TXT records.
3. **Zone Resources** → **Include** → **Specific zone** → your `DOMAIN` (least privilege; not
   "All zones"). **Client IP Address Filtering is optional** — on a VPS the public IP is stable,
   so locking it to the server's public IP is a fine belt-and-braces move, but skipping it is
   equally correct. **TTL is optional** (notBefore/notAfter dates; default: no expiry) — treat it
   as unset: nothing in this stack rotates the token, so an expired one kills renewals until you
   replace it in `stacks/traefik/.env`.
4. Traefik uses it to create and delete `_acme-challenge` TXT records for `*.DOMAIN` — nothing
   else; those records are short-lived (~120s TTL) and fully automatic.

`just init` verifies the token against Cloudflare's `/user/tokens/verify` right after you enter
it, so a bad paste or a revoked token fails before you ever start the stack. (This only checks the
token is **valid** — its `Zone:Read`/`DNS:Edit` scope surfaces at first cert issuance, not here.)
To re-check an already-configured token:

```bash
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer <token>"   # expect "status": "active"
```

### `TRAEFIK_DASHBOARD_CREDENTIALS` — htpasswd blob for `traefik.<DOMAIN>`

Not a token — a `user:hash` pair produced by `htpasswd`:

```bash
docker run --rm httpd:2.4-alpine htpasswd -nbB user 'ChangeMe-strong-password'
```

(No docker? `htpasswd -nbB` from `apache2-utils`, or `openssl passwd -apr1 'pass'` — Traefik
accepts both.)

`.env` gotcha: the `$2y$...` hash breaks compose interpolation, so **quote the whole value in
single quotes**:

```
TRAEFIK_DASHBOARD_CREDENTIALS='user:$2y$05$abcdefghijklmnopqrstuvwxyz0123456789'
```

Regenerate and recreate the traefik container if you ever lose it.

### `CROWDSEC_BOUNCER_API_KEY` — local random key

No dashboard to sign up for. Any random string works; both CrowdSec and Traefik use it to
authenticate over LAPI:

```bash
openssl rand -hex 32     # 64 hex chars
```

Paste into `stacks/traefik/.env`. It must be set **before** `just up`; after changing it,
recreate the `crowdsec` and `traefik` containers (`just update-all`). Details in
[Security](security).

## 6. First boot

By now Tailscale is up and [Hardening](hardening) has run: ufw is deny-incoming with SSH allowed
only from the tailnet. Ports `443` and `80` are still closed, so the stack answers only inside the
tailnet:

```bash
just up          # creates networks, config dirs, acme.json + traefik.yml, then brings up every stack
just ps          # confirm everything is running
```

`just up` handles ordering for you — it creates the shared networks and the per-service config
dirs (both idempotent), then brings every stack up. Why the networks and dirs matter is covered
in [The \*arrs](arrs).

App UIs live at `https://<subdomain>.<DOMAIN>`: `jellyfin`, `seerr`, `radarr`, `sonarr`,
`prowlarr`, `profilarr`, `bazarr`, `decypharr`, `traefik`. The certs are issued by DNS-01, so
they exist even before any DNS record points at the box.

> **The stack is private until you open the door — use that window.** Nothing here is public yet,
> and nothing becomes public until you add the A records *and* open `:443`
> ([Ingress](ingress)); until then, the only way in is the tailnet. That's intentional: an app
> that's live on the internet *before* its setup is done is an app with no login, claimable by
> anyone. Do all first-run
> setup through an **SSH port-forward over the tailnet** — every app's URL works with nothing
> exposed, no DNS records, no open ports:

```bash
just hosts 127.0.0.1        # on the VPS: prints the app URLs mapped to 127.0.0.1
ssh -N -L 8443:127.0.0.1:443 <you>@<tailnet-host>   # on your workstation, keep running
```

Copy the block from `just hosts 127.0.0.1` into `/etc/hosts` (macOS/Linux, admin) or
`C:\Windows\System32\drivers\etc\hosts` (Windows), and the apps answer at
`https://<subdomain>.<DOMAIN>:8443` — over the real wildcard cert, because the forward lands on
Traefik's `:443`. The vault of every app is created during this stage, so no app ever exists on
the public internet without a login. **Exposing the stack is the last, deliberate step** —
see the [security gate](ingress#security-gate--finish-setup-before-going-public) in Ingress.

## 7. What to check right after boot

- Traefik downloaded the CrowdSec plugin on first start (needs outbound internet); a
  `Certificate` appears in the ACME panel for `*.DOMAIN`.
- Every app answers on its internal hostname over the tailnet; nothing answers from the
  internet yet (ufw closed, no DNS records).
- CrowdSec seeded its config under `$CONFIG_DIR/crowdsec/config` — see [Security](security).
- Jellyfin's admin account is created on first login (feed its key to Seerr later).

Reach the stack through the tailnet SSH port-forward, verify the cert once, then run
`just wiring` on the
server (it probes the internal network and prints every URL + API key you need to paste) and
continue to [The \*arrs](arrs) for the full walkthrough.

### Going public (last)

When every app is set up:

1. Add **A records** in Cloudflare DNS for `seerr.<DOMAIN>` and `jellyfin.<DOMAIN>`, **Proxy
   status: DNS only** (grey cloud — never proxied), pointing at the VPS's public IP — full
   steps in [Ingress → Adding a public hostname](ingress#adding-a-public-hostname-dns-record).
2. Open the public ports — the last thing you do:

   ```bash
   sudo ufw allow 443/tcp
   sudo ufw allow 80/tcp
   ```

   `443` is the real way in; `80` exists only for the `http → https` redirect (Traefik's
   entrypoint-level rule — nothing is served on it), and the HSTS header means browsers skip `:80`
   after their first https visit. The matching provider-side ingress rules (`443` **and** `80`) are
   part of [instance creation](oci) in the free-tier guide. SSH stays tailnet-only.

From then on the stack is public on those hostnames only: Cloudflare DNS → VPS `:443` → Traefik,
with CrowdSec in front of all of it. (Typing `http://` in a browser bounces to https; every other
request already speaks https.) Reversible either way — delete the records, or `sudo ufw delete
allow 443/tcp` (and `allow 80/tcp`). Admin panels stay out of the public DNS and are reached
over the tailnet **by name** — once `:443` is open, set up [Tailnet DNS](tailnet) and they resolve
as `https://<app>.<DOMAIN>` on every tailnet device. [Ingress](ingress) covers the details.