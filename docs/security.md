---
title: Security
nav_order: 8
---

# Security: CrowdSec IP blocking

CrowdSec runs in the **traefik stack** at the edge — the layer that sees all public traffic.
Traefik's access log feeds the detection engine; a Traefik middleware plugin enforces the
decisions per request. The verify commands are in the walkthrough
([Quickstart §9](quickstart#9-verify-the-waf-crowdsec)); this page is what's running and how
it behaves.

## Components

- `crowdsec` container — analysis engine + LAPI on the `internal` network at `crowdsec:8080`.
  It reads Traefik's JSON access log via `$CONFIG_DIR/traefik/crowdsec-acquis.yaml` (tracked
  at `data/traefik/`).
- Traefik plugin `bouncer` — the **`crowdsec@file`** middleware in
  `$CONFIG_DIR/traefik/dynamic.yml`, in stream mode. It is attached to the **https
  entrypoint** (`data/traefik/traefik.template.yml`), so it guards every router that
  terminates TLS — current and future — with no per-router labels (the dashboard router
  additionally keeps its own `dashboardAcl` + basic-auth in front). The LAPI key is
  `CROWDSEC_BOUNCER_API_KEY`, injected via Traefik's Go templating (`env` in `dynamic.yml`) —
  Traefik renders dynamic config files as Go templates and does **not** substitute
  shell-style `${VAR}`.

## Behavior defaults

- **Bypasses**: client IPs in RFC1918/CGNAT ranges (`clientTrustedIPs`) are never checked —
  tailnet and LAN clients are exempt. With direct ingress there is no proxy, so the real
  client IP is the socket peer, read directly; `forwardedHeadersTrustedIPs` stays
  private-ranged, so a client can't spoof `X-Forwarded-For` (and the tailnet port-forward
  path still resolves correctly).
- **Fail-open**: `updateMaxFailure: -1` — if LAPI is unreachable, the edge lets traffic
  through rather than blocking everything. Startup is fail-open too
  (`streamStartupBlock: false`): with the middleware edge-wide, the "wait for CrowdSec before
  serving" default would stall all external traffic whenever Traefik restarts while CrowdSec
  is down. The trade-off is a small window at Traefik boot — until the first stream sync
  completes, typically seconds — during which banned IPs are not yet rejected
  ([why fail open](faq#why-does-crowdsec-fail-open)).
- **Mode**: `stream`; the banned-IP cache refreshes every 60s from CrowdSec.

The engine registers with the community blocklist and derives decisions from Traefik logs via
the `crowdsecurity/traefik` and `crowdsecurity/http-cve` collections. CrowdSec decides **which
IPs** get through the edge; the firewall decides who reaches `:443` at all; each app's own
login guards the rest ([Ingress](ingress)).
