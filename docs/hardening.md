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
is closed from the internet. The **Tailscale tailnet** is how you reach the box itself. Joining
the tailnet is always the first thing that happens on a brand-new box — either a cloud-init seed
at creation ([Oracle Cloud](oci)) or a manual join from the provider console
([Quickstart §1](quickstart#1-get-in-set-up-tailscale)).

## 1. Tailscale — your only way in (no public port)

This is the **first** thing that happens on a brand-new box — the walkthrough lives in
[Quickstart §1](quickstart#1-get-in-set-up-tailscale). An [Oracle Cloud](oci) box joins during
first boot (the Initialization script seeds it with an ephemeral auth key, so no console login is
involved). Everywhere else, bootstrap it from the provider's **out-of-band console** — the
hypervisor-level shell that rides the provider's network (no port on it, so not even `22` is
exposed while bootstrap happens):

```bash
curl -fsSL https://raw.githubusercontent.com/erdemoney/kickstarrt-vps/main/scripts/prerequisites.sh | sudo bash
```

The script installs everything (Tailscale, `git`, `just`, Docker) and joins the tailnet: it
prints an **auth URL**, waits up to two minutes for you to approve the node, then prints the box's
tailnet address. Authenticate with the printed URL in your browser, then note the node's address
(`tailscale ip -4` — or enable **MagicDNS** in the admin console and use its hostname). That
address, a `100.x.y.z` from Tailscale's CGNAT range, is the only place SSH is ever reachable.

Keep the provider console in mind as the **break-glass** path: if the tailnet node ever needs
fixing from outside, the console is still there — it's port-free and always available. One
caveat: Canonical Ubuntu images on [OCI](oci) configure **no console password**, so the console
there can't log you in by design — the reason access is seeded at creation rather than delivered
over the console. Recovering a tailnet-locked Ubuntu box happens from a rescue: detach the boot
volume, mount it on a second instance, and fix (or re-seed) the node.

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
sudo ufw allow from 100.64.0.0/10 to any port 53 proto udp
sudo ufw allow from 100.64.0.0/10 to any port 53 proto tcp
sudo ufw enable
```

The `allow from 100.64.0.0/10` rules let nothing but your tailnet (`100.64.0.0/10` is the CGNAT
range Tailscale uses) reach sshd **and the tailnet DNS resolver** (the CoreDNS container in the
traefik stack — see [Tailnet DNS](tailnet)): `22` for SSH, `53` so tailnet devices can resolve
`*.DOMAIN` to the box's tailnet address. There is **no `22` rule from the internet and no
`80`/`443` rule yet**. The public surface of this stack is Traefik on `443` plus a `80` rule that
exists only for the `http → https` redirect — and it all stays **closed** through setup; the last
step of [Going public](quickstart#going-public-last) is `sudo ufw allow 443/tcp` and `sudo ufw
allow 80/tcp`. Until those run, nothing on the box answers from the internet, DNS records or not
(Traefik listens on `:443` the whole time; the firewall just doesn't let traffic in).

Now that the tailnet is your door, also close the provider-side `22` ingress rule that was left
open as the first-boot rescue window — on **Oracle Cloud**, VCN → Default Security List →
delete the `TCP 22 / 0.0.0.0/0` rule ([OCI §1](oci#1-virtual-cloud-network-vcn--via-the-vcn-wizard)).
SSH has exactly one way in from here: your tailnet.

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

The [quickstart](quickstart#2-fork-and-clone) runs Docker as a normal user. Do the official
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