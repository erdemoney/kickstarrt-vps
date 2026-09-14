---
title: Tailnet DNS
nav_order: 9.5
---

# Tailnet DNS: admin panels by name

The admin panels (Radarr, Sonarr, Prowlarr, Profilarr, Bazarr, Decypharr, the Traefik dashboard)
have **no public DNS records** — they're private. Inside your tailnet, they're reachable **by
name** — `https://radarr.<DOMAIN>`, `https://sonarr.<DOMAIN>`, … — with the same wildcard Let's
Encrypt cert and zero `/etc/hosts`. This page is the how-to.

## How it works

Traefik already routes every app by its hostname on `:443`, and the DNS-01 wildcard cert already
covers every `*.DOMAIN` — so the only missing link was *resolution on tailnet devices*. MagicDNS
gives each *node* one name (`<node>.<tailnet>.ts.net`), not per-app names, and it can't be told to
serve your own domain. Tailscale's supported mechanism for that is **split DNS**:

1. A tiny **CoreDNS** container in the `traefik` stack answers `*.DOMAIN` (and the apex) with the
   VPS's **tailnet IP** (`100.x.y.z`).
2. You register that resolver in Tailscale as a **restricted (split) nameserver for `DOMAIN`**
   only. Tailscale clients send just `*.DOMAIN` lookups to it; everything else still uses
   MagicDNS/public DNS.
3. From any tailnet device, `radarr.<DOMAIN>` resolves to the box's tailnet address → the request
   rides the WireGuard mesh straight to Traefik `:443` → routed by `Host()` → served with the real
   cert. No extra auth: **being on the tailnet *is* the gate.**

It's steady-state: it kicks in once ufw has opened `:443` ([Going public](quickstart#going-public-last)).
During the setup window the only way in stays the SSH port-forward — ufw blocks tailnet `:443` too
until then.

## One-time Tailscale admin console setup

1. [Tailscale Admin → DNS](https://login.tailscale.com/admin/dns) → **Nameservers** →
   **Add nameserver** → **Custom**.
2. Enter the resolver as a plain IP: `100.x.y.z` (your `TAILNET_IP` — print it with `just dns`).
3. Constrain it: pick **"Only send names in these domains"** and add your `DOMAIN` — *not* the
   `ts.net` tailnet name (MagicDNS doesn't delegate that), and *not* global.
4. Leave **MagicDNS** on and **"Override local DNS"** off. Save.

That's the whole console side. After the next DNS refresh on your devices (rejoin the tailnet, or
flush their resolver), the panels resolve.

## Running it (server side)

Already handled by the standard flow:

- `just init` fills `TAILNET_IP` in `stacks/traefik/.env` (auto-detected from `tailscale ip -4`).
- `just dirs` (part of `just up`) renders `$CONFIG_DIR/coredns/Corefile` from the tracked template
  and `just up` starts the CoreDNS container, bound to `TAILNET_IP:53` **only** (it deliberately
  doesn't bind `0.0.0.0:53` — systemd-resolved already holds the loopback).
- ufw allows DNS **from the tailnet only** (`100.64.0.0/10 … port 53`), added in
  [Hardening](hardening).
- Check it: `just dnscheck` queries the resolver directly (`radarr.<DOMAIN>` → your tailnet IP),
  and `just dns` prints the exact nameserver value to enter in the admin console.

## Verify from a tailnet device

Replace `radarr` with any panel name:

| OS | Command | Expected |
| -- | ------- | -------- |
| macOS | `dscacheutil -q host -a name radarr.<DOMAIN>` | Address = your tailnet IP |
| Linux | `getent hosts radarr.<DOMAIN>` | tailnet IP |
| Windows | `Resolve-DnsName radarr.<DOMAIN>` | IPAddress = your tailnet IP (use `Resolve-DnsName`, **not** `nslookup` — it misses split-DNS/NRPT rules) |

A device **not** on the tailnet won't resolve these at all — there's no public A record for the
panels, by design.

## Troubleshooting

- **Names don't resolve yet** — devices usually pick up the new nameserver on their next
  Tailscale DNS update. Rejoin the tailnet, or flush: `sudo dscacheutil -flushcache` (macOS),
  `sudo systemctl restart systemd-resolved` (Linux), `ipconfig /flushdns` (Windows).
- **Nothing answers on the box itself** — `just dnscheck`; confirm CoreDNS is up
  (`docker compose -f stacks/traefik/compose.yaml ps coredns`) and ufw has the `53` rules
  (`sudo ufw status`).
- **Tailnet IP changed** (the box was rebuilt as a new node) — re-run `just init` (Enter accepts
  the new detection), then update the nameserver IP in the Tailscale admin console.
- **You skipped the console step** — `just dns` prints exactly what to paste in.
- **Panels resolve but don't load** — you're before [Going public](quickstart#going-public-last):
  ufw hasn't opened `:443` yet. Use the SSH port-forward (`just hosts 127.0.0.1`) until then.

The `/etc/hosts` block (`just hosts <tailnet-ip>`) still works as a no-CoreDNS fallback on any
machine that can't or won't use the resolver.