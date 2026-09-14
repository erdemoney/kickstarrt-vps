---
title: Ingress
nav_order: 9
---

# Ingress: Traefik on :443 (no tunnel)

Public traffic path: **DNS (Cloudflare, DNS-only) → VPS public IP `:443` → Traefik → service on
`internal`**. Traefik routes purely by its own `Host()` labels. There is **no Cloudflare Tunnel**
in this edition — traffic goes straight to the server, and Cloudflare is used for exactly two
things: DNS records and the DNS-01 challenge that issues the wildcard cert. Neither carries any
video, which keeps the stack clearly on the right side of Cloudflare's CDN terms (more on
[why](#why-not-proxy-media-via-cloudflare)).

**The VPS serves the internet from exactly one port: TCP `443` (Traefik).** TCP `80` is open only
to bounce `http://` to `https://` — the entrypoint-level redirect in `traefik.template.yml`, with
nothing served on it — and the HSTS header (`secHeaders@file`, sent on every https response) makes
repeat browsers upgrade on their own and skip `:80` after the first visit. SSH reaches sshd only
from your tailnet ([Hardening](hardening)). Everything on `:443` is fronted by CrowdSec
([Security](security)).

## Security gate: finish setup before going public

Inbound is blocked until *you* allow it — nothing here is accidentally public. The order is fixed:

1. **Set up every app first over the tailnet** — either directly at the server's tailnet IP or
   through the [SSH port-forward window](quickstart#3-first-boot). That's
   where the first-run walkthrough in [The \*arrs](arrs) happens.
2. **Minimum before exposing each app: its setup is finished** — admin account exists and auth is
   on: Jellyfin (admin created on first login), Sonarr/Radarr/Prowlarr/Bazarr/Profilarr (Settings →
   General → Authentication), Seerr (admin on first login), Decypharr (wizard completed).
3. **Only then go public** — the last step is adding DNS records *and* opening `:443` (and its
   `:80` https-redirect companion) at the firewall (see [Going public last](quickstart#going-public-last)).
   Reversible either way: delete the records, or `sudo ufw delete allow 443/tcp` and
   `allow 80/tcp`.

## Adding a public hostname (DNS record)

Public exposure is controlled by **A records** in Cloudflare DNS — not by anything on the box.
Traefik already serves every app on its subdomain the moment `just up` runs; whether the world can
*reach* that depends on DNS and the firewall.

1. [DNS → Records](https://dash.cloudflare.com/?to=/:account/dns) → **Add record**.
2. **Type `A`**, **Name** the subdomain (e.g. `jellyfin`, `seerr`), **IPv4 address** = the VPS's
   public IP.
3. **Proxy status: DNS only** (grey cloud). This is the important part — *never* orange-cloud
   (proxied) a media hostname: that would route the video through Cloudflare's edge, which is
   exactly what their terms forbid on a free plan.
4. Save; DNS propagates in minutes.

**Keep the public surface minimal.** The only hostnames anyone needs are `seerr.<DOMAIN>` (so they
can request) and `jellyfin.<DOMAIN>` (so they can watch). Nothing else gets an A record — Radarr,
Sonarr, Prowlarr, Bazarr, Profilarr, Decypharr, and the Traefik dashboard stay off the public DNS
and are reached over the tailnet **by name** via [Tailnet DNS](tailnet).

**One honest caveat about direct ingress:** Traefik answers any hostname it has a router for, even
with no DNS record — a determined client can connect to the IP and send a `Host:` header directly,
so the absence of a DNS record is *not* a security boundary, just a de-facto one. Every panel is
still behind its own app login (and the Traefik dashboard behind basic-auth *and* an
IP allow-list — see below). If you want any panel *hard*-blocked from the internet, add an
`ipAllowList` middleware (allow your tailnet/LAN ranges, e.g. `100.64.0.0/10`, `10.0.0.0/8`,
`172.16.0.0/12`, `192.168.0.0/16`) to that service's router labels in `stacks/media-server/compose.yaml`
and `just update-svc media-server <svc>`.

## Why not proxy media via Cloudflare

Cloudflare's [Service-Specific Terms](https://www.cloudflare.com/service-specific-terms-application-services/)
(the updated replacement for the old §2.8): the **CDN** service "can be used to cache and serve web
pages and websites", and unless you're an Enterprise customer you "must use" paid services (Stream,
Images, R2) "in order to serve video and other large files via the CDN" — with Cloudflare reserving
the right to disable/limit the CDN when it suspects otherwise. Video *streamed from your own origin*
through the free edge is not covered by an exception, whether or not caching is disabled, and a
Cloudflare Tunnel routes traffic through that same edge.

So this edition **does not move any video through Cloudflare's network**: public hostnames are
DNS-only (grey-cloud) A records straight to the VPS, and Cloudflare only answers recursive DNS
lookups and the ACME `_acme-challenge` TXT record. That's unreservedly compliant, and since the box
has a **static public IP** the tunnel's main trick — hiding the IP — had no value here anyway.

The edge-only features that leave with the tunnel — WAF geolock and Cloudflare Access — are
handled inside the box instead: [CrowdSec](security) is the WAF, and an Access-style login would
have broken Jellyfin's TV and mobile apps anyway (they authenticate with a device token, not a
browser). Neither is missed on a way in that the firewall already controls.

## Certificates (automatic)

HTTPS is one-time setup, then handled for you. Traefik's ACME provider creates the
`_acme-challenge` TXT record via the Cloudflare API (`CLOUDFLARE_DNS_TOKEN`, from
[Quickstart](quickstart)) and issues a **Let's Encrypt wildcard cert for `*.DOMAIN`** — one cert
covering every hostname that terminates at Traefik, whether from the public internet or the tailnet
port-forward.
Because it's the **DNS-01** challenge, certs issue before any DNS record or app exists; no inbound
ports are required. Renewals and per-app HTTPS are automatic (`tls=true` on every router). Confirm
issuance in the Traefik dashboard's ACME panel (`https://traefik.<DOMAIN>`).

There is **no Let's Encrypt account to create** — no signup, dashboard, or email verification.
Traefik registers one over ACME on first start and stores it in `$CONFIG_DIR/traefik/acme.json`;
`ACME_EMAIL` (default `admin@<DOMAIN>` in `just init`) just needs to be a real, controlled domain
— the API rejects reserved ones (`@example.com`) — but it needn't receive mail.

While experimenting, use the **staging CA** — Let's Encrypt rate limits "last up to one week and
cannot be overridden". In `data/traefik/traefik.template.yml`:

```yaml
caServer: https://acme-staging-v02.api.letsencrypt.org/directory
```

then `just up`. Staging certs are untrusted (browsers warn — that's expected); switching back to
production means dropping the account storage first so the staging account/certs aren't reused:

```bash
just down && rm -f data/traefik/acme.json && just up   # dirs re-creates it 0600
```

### Editing Traefik's config

Traefik's static config is **rendered, not copied**: the repo tracks
`data/traefik/traefik.template.yml`, and `just up` renders it to
`$CONFIG_DIR/traefik/traefik.yml` (untracked) with your `ACME_EMAIL` filled in. **Edit the
template, never the rendered file** — `just up` overwrites the output every run. `dynamic.yml`
and `crowdsec-acquis.yaml` need no rendering and are mounted as tracked files (`dynamic.yml`
resolves its one secret at runtime with Traefik's Go templating).

## Traefik dashboard

The API dashboard is exposed at `https://traefik.<DOMAIN>` behind basic auth
(`TRAEFIK_DASHBOARD_CREDENTIALS`, see [Quickstart](quickstart)) plus an IP allow-list
(`dashboardAcl@file` in `data/traefik/dynamic.yml`, covering your LAN and tailnet
CGNAT ranges). For any \*arr-scale question ("is the cert issued?", "which routers exist?") the
dashboard is the fastest place to look. Note the allow-list also covers `100.64.0.0/10` — reach it
over the tailnet (e.g. via a `just hosts <tailnet-ip>` block); through the SSH port-forward
loopback it's blocked by design (see [Hardening](hardening#1-tailscale--your-only-way-in-no-public-port)).