---
title: Hardening
nav_order: 3
---

# Hardening extras

The mandatory hardening — the Tailscale join, the ufw deny-incoming ruleset, closing the
public SSH door — is part of the walkthrough and lives in
[Quickstart §6](quickstart#6-lock-the-box-down-ufw). This page is the optional depth on top
of that baseline.

The baseline you already have by the end of quickstart §6:

- **Public surface = Traefik on `443`, plus `80` as a pure `http → https` redirect** — both
  opened deliberately as the [last setup step](quickstart#11-go-public-last) — **plus the
  tailnet**. sshd is reachable only from `100.64.0.0/10`.
- **The firewall actually reaches the containers** — the [ufw-docker](https://github.com/chaifeng/ufw-docker)
  gate (installed by [`just lockdown`](quickstart#6-lock-the-box-down-ufw)) routes
  Docker's forwarded traffic through UFW, so "deny incoming" really is
  deny-everything-except-what-a `ufw allow` opens
  ([the forward gate](#docker-and-ufw-the-forward-gate) below).
- [CrowdSec](security) blocks scanner IPs at the Traefik layer; each app guards itself with
  its own login. Together the layers cover everything that can reach the box.

## Docker and UFW: the forward gate

The one place the deny-incoming model above silently falls short is **Docker published
ports**. `ports:` entries are DNAT'd and filtered in the `FORWARD` chain, which UFW's rules
(INPUT) never inspect — so by themselves, `ufw allow/deny` do not constrain the containers.
An internet peer with the box's IP could reach Traefik's `:80`/`:443` and CoreDNS's `:53`
the moment the stack boots, firewall rules or not. On Oracle the VCN security list happens
to be an outer door; on providers without a separate cloud firewall, nothing else is.

This repo closes it with the [ufw-docker](https://github.com/chaifeng/ufw-docker) project
(used as-is, no forks) — the community's battle-tested fix. Its `install` fills Docker's
`DOCKER-USER` chain — Docker's documented
[extension point for user firewall rules](https://docs.docker.com/engine/network/firewall-iptables/):
"a placeholder for user-defined rules that will be processed before rules in the DOCKER-FORWARD
and DOCKER chains". Nothing else needs touching: Docker's own chains keep working, and
`iptables` is never disabled. The installed block (in `/etc/ufw/after.rules`, idempotently):

```text
-A DOCKER-USER -j ufw-user-forward                      # the ufw allow rules decide first
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -j RETURN -s 10.0.0.0/8                  # RFC1918 sources are trusted
-A DOCKER-USER -j RETURN -s 172.16.0.0/12               # (incl. the internal 172.30.0.0/16)
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d <RFC1918>  # drop NEW
-A DOCKER-USER -j RETURN                                 # everything else returns to DOCKER-FORWARD
```

UFW mirrors every `ufw allow` rule into `ufw-user-forward`, so the §6 tailnet rules
(`allow from 100.64.0.0/10 to any port 53/443/22`) and the §11 public rules (`allow 80`,
`allow 443`) are exactly what opens the forward path — same commands, same reversibility.
Before §11, an internet peer's NEW connection to a container drops; traffic from
RFC1918/LAN sources (or established sessions) passes. That RFC1918 trust is ufw-docker's
default stance — a LAN device is trusted by default — and it's the one deliberate trade-off
this setup inherits from upstream. (The tailnet's `100.64.0.0/10` is *not* RFC1918, so
tailnet peers still need the explicit `allow from 100.64.0.0/10` rule — which §6 applies.)

**Installed and kept applied by [`just lockdown`](quickstart#6-lock-the-box-down-ufw):** the
recipe runs `ufw-docker install --system` — which writes the block above, installs the man
page, and installs `ufw-docker.service` (`WantedBy=multi-user.target`, tied to
`docker.service`) so the rules re-apply after every Docker start and reboot, then restarts
UFW to load them. The bootstrap script ([Quickstart §2](quickstart#2-get-in-join-the-tailnet))
doesn't touch the firewall at all — `just lockdown` installs ufw (if missing) *and* enables it
in the same command, so the boxes stay open until then. Verify any time:

```bash
sudo ufw-docker check        # diffs after.rules/after6.rules against the intended block
sudo iptables -nL DOCKER-USER
sudo ip6tables -nL DOCKER-USER
sudo iptables -L ufw-user-forward -n   # the ufw rules being mirrored
```

To reapply by hand after a change (e.g. a new Docker network):
`just lockdown` re-runs the whole lockdown and refuses unless the box is on the tailnet; or
step by step: `sudo ufw-docker install --system` then `sudo systemctl restart ufw`. Upstream
notes the rules can occasionally not take effect after a UFW restart — a reboot restores
them; `ufw-docker.service` is what makes reboots and docker restarts self-healing.

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

### Recovery door

Key-only SSH is a strong door and a single point of failure: if the box ever drops off the
tailnet, there's no SSH path left. Give the provider console a way in — a long random
`sudo passwd user` (console-only: it does not turn on sshd password auth), and use that VNC /
serial console to re-join the tailnet on a lockout ([OCI walkthrough](oci#3-recovery-the-console-break-glass);
other providers' consoles work the same way).

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
