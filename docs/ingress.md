---
title: Ingress
nav_order: 9
---

# Ingress: Traefik on :443

Public traffic path: **Cloudflare DNS (DNS-only) → VPS public IP `:443` → Traefik → service on
`internal`**. Traefik routes purely by its own `Host()` labels. Cloudflare is used for exactly
two things — DNS records and the DNS-01 challenge that issues the wildcard cert — and neither
carries video (why not proxy through their edge: the [FAQ](faq#why-cant-i-proxy-media-through-cloudflare)).
There is no Cloudflare Tunnel; the box serves its own static public IP.

The VPS serves the internet from exactly one port: **TCP `443` (Traefik)**. `80` exists only
to bounce `http://` to `https://` — the entrypoint-level redirect in
`traefik.template.yml`, with nothing served on it — and the HSTS header (`secHeaders@file`,
sent on every https response) makes repeat browsers skip `:80` after their first visit. sshd
answers only from the tailnet ([Quickstart §4](quickstart#4-lock-the-box-down-ufw)).
Everything on `:443` is fronted by CrowdSec ([Security](security)).

## The security gate

The going-public actions live in the walkthrough ([Quickstart §10](quickstart#10-go-public-last));
the rule they enforce:

1. **Set up every app first over the tailnet** — the panels resolve by name there from first
   boot ([Tailnet DNS](tailnet)), and that's where the [app wiring](arrs) happens.
2. **Minimum before exposing each app: its setup is finished** — an admin account exists and
   auth is on: Jellyfin (admin on first login), Sonarr/Radarr/Prowlarr/Bazarr
   (Settings → General → Authentication), Seerr (admin on first login), Decypharr (wizard
   completed). An app that goes public before its login exists is claimable by anyone.
3. **Only then open the door** — A records for `seerr` + `jellyfin`, then
   `sudo ufw allow 443/tcp` + `sudo ufw allow 80/tcp`. Reversible either way: delete the
   records, or `sudo ufw delete allow 443/tcp` and `allow 80/tcp`.

One honest caveat: Traefik answers any hostname it has a router for, even with no DNS record —
a determined client can connect to the IP and send a `Host:` header directly, so the absence
of a DNS record is a de-facto boundary, not a hard one. Every panel is still behind its own
login (and the Traefik dashboard behind basic-auth *and* an IP allow-list). To *hard*-block
any panel from the internet, add an `ipAllowList` middleware (allow your tailnet/LAN ranges,
e.g. `100.64.0.0/10`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) to that service's
router labels in `stacks/media-server/compose.yaml`, then
`just update-svc media-server <svc>`.

## Adding a public hostname (DNS record)

Public exposure is controlled by **A records** in Cloudflare DNS — not by anything on the box.
Traefik already serves every app on its subdomain the moment `just up` runs; whether the world
can *reach* it depends on DNS and the firewall.

1. [DNS → Records](https://dash.cloudflare.com/?to=/:account/dns) → **Add record**.
2. **Type `A`**, **Name** the subdomain (e.g. `jellyfin`, `seerr`), **IPv4 address** = the
   VPS's public IP.
3. **Proxy status: DNS only** (grey cloud). Never orange-cloud a media hostname —
   [why](faq#why-cant-i-proxy-media-through-cloudflare).
4. Save; DNS propagates in minutes.

**Keep the public surface minimal.** The only hostnames anyone needs are
`seerr.<DOMAIN>` (so they can request) and `jellyfin.<DOMAIN>` (so they can watch). Nothing
else gets an A record — the admin panels stay off the public DNS and are reached over the
tailnet by name ([Tailnet DNS](tailnet)).

## Certificates

One-time setup, then automatic. Traefik's ACME provider creates the `_acme-challenge` TXT
record via the Cloudflare API (`CLOUDFLARE_DNS_TOKEN`, created in the
[Quickstart](quickstart#5-fork-clone-and-fill-the-secrets)) and issues a **Let's Encrypt
wildcard cert for `*.DOMAIN`** — one cert covering every hostname that terminates at Traefik,
public or tailnet. Because it's the **DNS-01** challenge, certs issue before any DNS record
or app exists, and no inbound ports are required. Renewals and per-app HTTPS are automatic
(`tls=true` on every router). Confirm issuance in the Traefik dashboard's ACME panel.

There is **no Let's Encrypt account to create** —
[why](faq#why-is-there-no-lets-encrypt-account-to-create). `ACME_EMAIL` just needs to be an
address on a real domain you control (the API rejects reserved ones like `@example.com`); it
needn't receive mail. While experimenting, use the **staging CA** — Let's Encrypt rate limits
"last up to one week and cannot be overridden":

```yaml
caServer: https://acme-staging-v02.api.letsencrypt.org/directory   # in data/traefik/traefik.template.yml
```

then `just up`. Staging certs are untrusted (browsers warn — expected); switching back to
production means dropping the account storage first so the staging account isn't reused:

```bash
just down && rm -f data/traefik/acme.json && just up   # dirs re-creates it 0600
```

### Editing Traefik's config

Traefik's static config is **rendered, not copied**: the repo tracks
`data/traefik/traefik.template.yml`, and `just up` renders it to
`$CONFIG_DIR/traefik/traefik.yml` (untracked) with your `ACME_EMAIL` filled in. **Edit the
template, never the rendered file** — `just up` overwrites the output every run.
`dynamic.yml` and `crowdsec-acquis.yaml` need no rendering and are mounted as tracked files
(`dynamic.yml` resolves its one secret at runtime with Traefik's Go templating).

## Traefik dashboard

`https://traefik.<DOMAIN>`, behind basic auth (`TRAEFIK_DASHBOARD_CREDENTIALS`) plus an IP
allow-list (`dashboardAcl@file` in `data/traefik/dynamic.yml`, covering your LAN and tailnet
CGNAT ranges). For any \*arr-scale question — "is the cert issued?", "which routers exist?" —
it's the fastest place to look. Reach it over the tailnet (the allow-list covers
`100.64.0.0/10`); the loopback of an SSH port-forward is deliberately blocked — get on the
tailnet first ([Quickstart §3](quickstart#3-verify-ssh-over-the-tailnet)).
