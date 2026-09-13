---
title: Hardening
nav_order: 3
---

# Hardening (do this before anything is public)

A fresh VPS is reachable by scanners within minutes of booting. Do all of this **before** `just up`
and before anything is public.

## 1. Keep packages up to date

```bash
sudo apt update && sudo apt upgrade -y
```

## 2. Firewall — ufw (allow SSH, deny everything else — permanently)

This stack is exposed over a Cloudflare tunnel, which dials **out** to Cloudflare — it needs no
inbound rules. So deny-all is not a bootstrap posture, it's the permanent one: only `22` is ever
open on this box.

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw enable
```

**Never add `80` or `443`.** The tunnel connects to Cloudflare outbound; Traefik's published
`:80`/`:443` stay behind ufw and are never reachable from the internet. If a hostname stops
working, the fix is on the tunnel/dashboard side, not a ufw rule.

## 3. SSH keys, no password auth

Copy your public key over, then lock password login:

```bash
ssh-copy-id user@<VPS_IP>
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

(Test login in a second terminal before closing the first.) Root login over SSH should be off too
— if you use a root user, create a normal user first and `sudo` from it.

## 4. Non-root Docker

The [quickstart](quickstart#fork-first) runs Docker as a normal user. Do the official
[post-install steps](https://docs.docker.com/engine/install/linux-postinstall/):

```bash
sudo usermod -aG docker $USER
# re-login, then: docker run hello-world
```

Membership in the `docker` group is root-equivalent, so make sure only your own account is in it.

## 5. fail2ban (the one thing CrowdSec can't see: SSH)

With the stack behind a tunnel, **SSH is your only inbound attack surface** — and it's exposed
directly on `:22`, where the stack's CrowdSec (which guards the Traefik/HTTP layer only) never
sees the traffic. That's what fail2ban is for:

```bash
sudo apt install fail2ban
```

Defaults are fine: it watches sshd and bans repeated bad logins. Check it after a while with
`sudo fail2ban-client status sshd`.

## 6. Keep-a-lid-it-on principles

- CrowdSec inside the stack ([Security](security)) blocks scanner IPs at the Traefik layer;
  fail2ban covers SSH — together they cover everything that can reach this box.
- Only `22` is ever open. The tunnel is the only other way into the stack, and it's
  controlled entirely from your Cloudflare dashboard.
- Don't run random scripts as root; `just` and `docker` are the only privileged entry points
  you interact with.