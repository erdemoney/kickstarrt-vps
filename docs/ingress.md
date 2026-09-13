---
title: Ingress
nav_order: 8
---

# Ingress: Traefik, direct from the public IP

Public traffic path: Cloudflare edge (proxied A records) → ufw `:80/:443` → Traefik → CrowdSec →
service on `internal`. Traefik routes purely by its own `Host()` labels; the A records just map
each hostname to this box's public IP, and ufw decides who reaches the server at all.

## Security gate: finish setup before going public

Because the box is on a public IP, an app is on the internet the moment DNS points at it and the
ports are open — and until its first-run setup is done the app has **no login**, so anyone who
finds the subdomain can create the admin account or reconfigure the app for you. Because of that
the order is fixed:

1. **Set up every app first via the hosts-file window** — [Quickstart](quickstart#3-first-boot)
   maps every URL to the VPS without any DNS or ports open, so nothing is public while the
   full [The \*arrs](arrs) walkthrough happens.
2. **Minimum before exposing each app: its setup is finished** — admin account exists and auth is
   on: Jellyfin (admin created on first login), Sonarr/Radarr/Prowlarr/Bazarr/Profilarr (Settings →
   General → Authentication), Seerr (admin on first login), Decypharr (wizard completed).
3. **Only then expose it** — open `:80`/`:443` and point the A records (last step of the
   [Quickstart](quickstart#going-public-last)).

## Exposing a hostname (DNS)

Every app subdomain already has a Traefik router (compose labels), so "exposing" an app is a
DNS decision, not a per-app config:

1. In the Cloudflare zone's **DNS** tab, create an **A record** for `DOMAIN` and `*.DOMAIN`,
   both pointing at the VPS's public IP.
2. **Proxy status: orange-cloud (Proxied)** for the zone — every hostname then reaches Traefik
   through the Cloudflare edge, which is where [geolock](#geolock-optional-eg-usa-only) and
   [Cloudflare Access](#authentication-with-cloudflare-access) apply. Media traffic is exempted
   from caching below instead of being sent direct.
3. Keep **TLS mode** at **Full (strict)** (SSL/TLS → Edge Certificates) so the edge → Traefik leg
   uses the real cert.

The active public hostnames are simply: which `*.DOMAIN` A records you've created (plus which
subdomains the routers accept). Deleting the A record removes the hostname from the internet.

**Keep the public surface minimal.** The only hostnames users actually need are
`seerr.<DOMAIN>` (so they can request) and `jellyfin.<DOMAIN>` (so they can watch). Everything else
— Radarr, Sonarr, Prowlarr, Bazarr, Profilarr, Decypharr, the Traefik dashboard — is an admin
panel: leave it out of the public A records. If you need to administer from elsewhere, get in over
a **VPN** to the server rather than publishing a panel — and if you do expose any panel, put
[Cloudflare Access](#authentication-with-cloudflare-access) in front of it.

## Certificates (automatic)

HTTPS is one-time setup, then handled for you. Traefik's ACME provider creates the
`_acme-challenge` TXT record via the Cloudflare API (`CLOUDFLARE_DNS_TOKEN`, from
[Quickstart](quickstart)) and issues a **Let's Encrypt wildcard cert for `*.DOMAIN`** — one cert
covering every hostname that terminates at Traefik. Because it's the **DNS-01** challenge, certs
issue before any A record exists or any port is open on the firewall — DNS is the only thing the
challenge touches. Renewals and per-app HTTPS are automatic (`tls=true` on every router).
Confirm issuance in the Traefik dashboard's ACME panel (`https://traefik.<DOMAIN>`).

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

## Media through Cloudflare (no CDN caching)

Cloudflare's content restriction (historically "Section 2.8") only applies to the **CDN
service** — caching and serving content at the edge. Serving media on a proxied hostname is fine
as long as the edge does **not cache** the video.

1. Cloudflare dashboard for the zone → **Caching → Cache Rules** → **Create rule**.
2. When: **Hostname** equals `jellyfin.<DOMAIN>` (add `/Videos/*` for path-level matching if
   preferred).
3. Then: **Cache eligibility** → **Bypass cache**.
4. Save; repeat for any other media hostnames.

Verify media responses are not cached:

```bash
curl -sI https://jellyfin.<DOMAIN>/web/ | grep -iE 'cf-cache-status|age|cache-control'
```

Expect `cf-cache-status: DYNAMIC` (or `BYPASS`) and no meaningful `Age` on media URLs.

## Geolock (optional, e.g. USA only)

Do this in Cloudflare, not Traefik: Cloudflare sees the real visitor IP at the edge; Traefik
only sees Cloudflare's proxy IP, so a Traefik-side geoblock would be unreliable without trusting
`X-Forwarded-For` (which reopens spoofing).

1. Zone dashboard → **Security → WAF → Custom rules** → **Create rule**.
2. Field **Country**, operator **is not**, value **United States**; action **Block**.
3. Save — blocks every public hostname on the zone from outside the US.

Notes: country comes from the edge IP (VPNs bypass it); blocking at the edge keeps the junk from
ever reaching the VPS. (This same pattern is also where you'd enforce any other zone-wide WAF
rules.)

## Authentication with Cloudflare Access

CrowdSec decides **which IPs** are allowed; Cloudflare Access decides **which identities**. It
works at the edge, *before* the request reaches your box — the Zero Trust dashboard →
**Access → Applications** → **Add an application** → **Self-hosted** — so a request that doesn't
pass its policy never travels to the VPS, let alone Traefik. Set the **Application domain** to
the hostname you want to protect (e.g. `radarr.<DOMAIN>`), create a **Policy** (any of: your
logged-in Cloudflare / SSO identity, an email domain, or a
[service token](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/) for
machine clients), choose a **Session duration**, and save. Visitors get the Access login page;
everything else in the zone stays public.

Caveats and how it fits the stack:

- **Do not put Access in front of Jellyfin if *external* TV/media apps must stream.** Jellyfin's
  TV and mobile clients (LG/Samsung, Android TV, Apple TV, Roku, ...) authenticate with a device
  **token**, not a browser, and cannot complete Cloudflare Access's interactive login — they fail
  to connect. A public `jellyfin.<DOMAIN>` must stay in front of Access if any external app
  should work. Leave it unprotected rather than breaking clients — Jellyfin's own accounts still
  guard it, and the web UI is unaffected. (A service token is the workaround for
  machine-to-machine clients that can send headers, not for the TV apps, which can't.)
- It is an extra layer over each app's own auth (Jellyfin accounts, the Traefik dashboard's
  basic-auth) — belt-and-suspenders, not a replacement. Rejected traffic never reaches the
  VPS, so Traefik and the apps only ever see approved requests.
- It composes with CrowdSec at different layers: Access filters unauthenticated humans at the
  edge while CrowdSec still blocks scanner IPs inside Traefik. Enable both; neither interferes
  with the other's bypasses.
- CrowdSec on the box still matters for **non-proxied** traffic and for IPs that Access lets
  through — keep both.

## Traefik dashboard

The API dashboard is exposed at `https://traefik.<DOMAIN>` behind basic auth
(`TRAEFIK_DASHBOARD_CREDENTIALS`, see [Quickstart](quickstart)) plus a private-source-range ACL.
For any \*arr-scale question ("is the cert issued?", "which routers exist?") the dashboard is the
fastest place to look.