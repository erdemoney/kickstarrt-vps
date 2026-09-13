---
title: Hardening
nav_order: 3
---

# Hardening (do this before anything is public)

A fresh VPS is reachable by scanners within minutes of booting. Do all of this **before** `just up`
and before opening ports 80/443.

## 1. Keep packages up to date

```bash
sudo apt update && sudo apt upgrade -y
```

## 2. Firewall — ufw (allow SSH, deny everything else)

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw enable
```

Ports 80/443 stay closed until you're ready to expose the stack
([Quickstart → Going public](quickstart#going-public-last)):

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

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

## 5. fail2ban (SSH brute force)

```bash
sudo apt install fail2ban
```

Defaults are fine: it watches sshd and bans repeated bad logins. Check it after a while with
`sudo fail2ban-client status sshd`.

## 6. Keep-a-lid-it-on principles

- CrowdSec inside the stack ([Security](security)) blocks scanner IPs at the Traefik layer —
  it complements, not replaces, the firewall.
- Only open what's needed: 22, and later 80/443 for the stack.
- Don't run random scripts as root; `just` and `docker` are the only privileged entry points
  you interact with.