---
title: Hardening
nav_order: 4
---

# Hardening (do this before anything is public)

A fresh VPS is reachable by scanners within minutes of booting. Do all of this **before** `just up`
and before anything is public.

This edition opens **exactly one port to the public internet: TCP `443` (Traefik)** — and not even
that at first: it stays closed behind ufw until you deliberately open it as the last step of
setup ([Going public](quickstart#going-public-last)). Everything else — including `80` and `22` —
is closed from the internet. The **Tailscale tailnet** is how you reach the box itself. Until
then, the only way in is the provider's out-of-band console.

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

## 3. Firewall — ufw (deny-incoming; `443` opens only at the end)

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw enable
```

The `allow from 100.64.0.0/10` rule lets nothing but your tailnet (`100.64.0.0/10` is the CGNAT
range Tailscale uses) reach sshd. There is **no `22` rule from the internet and no `80`/`443`
rule yet**. The public surface of this stack is Traefik on `443` plus a `80` rule that exists only
for the `http → https` redirect — and it all stays **closed** through setup; the last step of
[Going public](quickstart#going-public-last) is `sudo ufw allow 443/tcp` and `sudo ufw allow
80/tcp`. Until those run, nothing on the box answers from the internet, DNS records or not (Traefik
listens on `:443` the whole time; the firewall just doesn't let traffic in).

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

- **Public surface = Traefik on `443`, plus `80` as a pure `http → https` redirect**
  (both opened last — see [Going public](quickstart#going-public-last)) **plus the tailnet**.
  `22` is reachable only from your tailnet.
- CrowdSec inside the stack ([Security](security)) blocks scanner IPs at the Traefik layer;
  fail2ban backs up sshd — together they cover everything that can reach this box.
- Don't run random scripts as root; `just` and `docker` are the only privileged entry points
  you interact with.