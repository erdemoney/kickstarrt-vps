---
title: Hardening
nav_order: 3
---

# Hardening extras

The mandatory hardening — the Tailscale join, the ufw deny-incoming ruleset, closing the
public SSH door — is part of the walkthrough and lives in
[Quickstart §4](quickstart#4-lock-the-box-down-ufw). This page is the optional depth on top
of that baseline.

The baseline you already have by the end of quickstart §4:

- **Public surface = Traefik on `443`, plus `80` as a pure `http → https` redirect** — both
  opened deliberately as the [last setup step](quickstart#10-go-public-last) — **plus the
  tailnet**. sshd is reachable only from `100.64.0.0/10`.
- [CrowdSec](security) blocks scanner IPs at the Traefik layer; each app guards itself with
  its own login. Together the layers cover everything that can reach the box.

## SSH keys, no password auth

Even with sshd only on the tailnet, authenticate by key — this matters if your provider's
image allows password logins (Oracle's Ubuntu images don't: no password exists to
brute-force):

```bash
ssh-copy-id user@<tailnet-address>
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

Test login in a second terminal before closing the first. Root login over SSH should be off
too — if you use a root user, create a normal user first and `sudo` from it.

## Non-root Docker

The [bootstrap script](quickstart#2-get-in-join-the-tailnet) already put your user in the
`docker` group (new session required). If you built Docker by hand instead, do the official
[post-install steps](https://docs.docker.com/engine/install/linux-postinstall/):

```bash
sudo usermod -aG docker $USER
# re-login, then: docker run hello-world
```

Membership in the `docker` group is root-equivalent — make sure only your own account is in
it.

## fail2ban (optional)

With sshd reachable only from your tailnet, brute-force traffic never reaches it to begin
with — this is defense-in-depth, not load-bearing. Cheap to keep:

```bash
sudo apt install fail2ban
```

Defaults are fine: it watches sshd and bans repeated bad logins. Check it after a while with
`sudo fail2ban-client status sshd`.

## Principles

- Don't run random scripts as root; `just` and `docker` are the only privileged entry points
  you interact with.
- Keep the public surface at two hostnames and two ports. A new public app gets an A record,
  auth of its own, and a CrowdSec-guarded router like the rest.
- The provider console is the break-glass door — it exists precisely so a tailnet problem
  can't lock you out.
