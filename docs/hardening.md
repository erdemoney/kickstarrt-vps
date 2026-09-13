---
title: Hardening
nav_order: 4
---

# Hardening (do this before anything is public)

A fresh VPS is reachable by scanners within minutes of booting. Do all of this **before** `just up`
and before anything is public.

This edition **never opens a port to the public internet**. Two outbound-and-authenticated paths
carry everything: the Cloudflare tunnel serves the apps (see [Ingress](ingress)), and the
**Tailscale tailnet** is how you reach the box itself. Until both exist, the only way in is the
provider's out-of-band console.

## 1. Tailscale — your only way in (no public port)

Install and authenticate from the provider's **web console** (the hypervisor-level console in your
provider's panel, unaffected by the firewall — no port on it, so not even `22` is exposed while
bootstrap happens; [Oracle Cloud](oci) is the worked example):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Authenticate with the printed URL in your browser, then note the node's address (`tailscale ip -4`
— or enable **MagicDNS** in the admin console and use its hostname). That address, a `100.x.y.z`
from Tailscale's CGNAT range, is the only place SSH is ever reachable.

Keep the provider console in mind as the **break-glass** path: if the tailnet node ever needs
fixing from outside, the console is still there — it's port-free and always works.

## 2. Keep packages up to date

```bash
sudo apt update && sudo apt upgrade -y
```

## 3. Firewall — ufw (deny-all; SSH only inside the tailnet)

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw enable
```

The `allow from 100.64.0.0/10` rule lets nothing but your tailnet (`100.64.0.0/10` is the CGNAT
range Tailscale uses) reach sshd. There is **no `22` rule from the internet, and no `80`/`443`
ever** — the apps come in through the Cloudflare tunnel, which dials **out**, so it needs no
inbound rules at all. If a hostname stops working, the fix is on the tunnel/dashboard side, not a
ufw rule.

## 4. SSH keys, no password auth

Even with sshd only on the tailnet, authenticate by key:

```bash
ssh-copy-id user@<tailnet-address>
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

(Test login in a second terminal before closing the first.) Root login over SSH should be off too
— if you use a root user, create a normal user first and `sudo` from it.

## 5. Non-root Docker

The [quickstart](quickstart#fork-first) runs Docker as a normal user. Do the official
[post-install steps](https://docs.docker.com/engine/install/linux-postinstall/):

```bash
sudo usermod -aG docker $USER
# re-login, then: docker run hello-world
```

Membership in the `docker` group is root-equivalent, so make sure only your own account is in it.

## 6. fail2ban (belt-and-suspenders)

With sshd reachable only from your tailnet, brute-force traffic never reaches it to begin with,
so this is optional defense-in-depth rather than load-bearing. Cheap to keep:

```bash
sudo apt install fail2ban
```

Defaults are fine: it watches sshd and bans repeated bad logins. Check it after a while with
`sudo fail2ban-client status sshd`.

## 7. Keep-a-lid-it-on principles

- **Public surface = the tunnel + the tailnet**, both authenticated and both outbound. Only `22`
  exists as a reachable port, and only from your tailnet.
- CrowdSec inside the stack ([Security](security)) blocks scanner IPs at the Traefik layer;
  fail2ban backs up sshd — together they cover everything that can reach this box.
- Don't run random scripts as root; `just` and `docker` are the only privileged entry points
  you interact with.