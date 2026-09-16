---
title: Tailnet DNS
nav_order: 4
---

# Tailnet DNS: admin panels by name

The admin panels (Radarr, Sonarr, Prowlarr, Bazarr, Decypharr, the Traefik dashboard) have **no public DNS records** — inside your tailnet they resolve **by name**,
`https://radarr.<DOMAIN>` and so on, with the same wildcard Let's Encrypt cert, no
`/etc/hosts` editing, and no extra login. The one-time console registration happens during
setup, **before** first boot ([Quickstart §6](quickstart#6-register-the-tailnet-dns-resolver));
this page is the mechanics, verification, and troubleshooting.

## How it works

Traefik routes every app by hostname on `:443`, and the DNS-01 wildcard cert covers every
`*.DOMAIN` — the only missing link is *resolution on tailnet devices*. MagicDNS gives each
node one name (`<node>.<tailnet>.ts.net`) and can't be told to serve your own domain;
Tailscale's supported mechanism for that is **split DNS**:

1. A tiny **CoreDNS** container in the `traefik` stack answers every `*.DOMAIN` name (and the
   apex) with the VPS's **tailnet IP**.
2. You register it in Tailscale as a **restricted (split) nameserver for `DOMAIN` only** —
   tailnet clients send just `*.DOMAIN` lookups to it; everything else still uses
   MagicDNS/public DNS.
3. From any tailnet device, `radarr.<DOMAIN>` resolves to the box's tailnet address → the
   request rides the WireGuard mesh to Traefik's **`https-tailnet` entrypoint** — published
   on no IP except `TAILNET_IP` ([Ingress](ingress#the-security-gate)) — → routed by
   `Host()` → served with the real cert. **Being on the tailnet is the gate** — there is no
   extra auth to configure, and off-tailnet peers can't even reach the panel's socket.

Two consequences of the split-DNS registration, both worth knowing up front:

- **`DOMAIN` is dedicated to this stack.** CoreDNS answers *every* name under it with the
  tailnet IP — if the domain also hosted, say, `www` or mail publicly, tailnet devices would
  stop reaching those.
- **Until CoreDNS is up, `*.DOMAIN` lookups fail.** Split DNS intercepts the domain with no
  fallback, so between registering the resolver (quickstart §6) and first boot (§7)
  resolution is dead. Expected, and it heals at first boot.

The server side is handled by the standard flow: `just init` fills `TAILNET_IP`, `just up`
renders the Corefile from the tracked template and starts CoreDNS bound to `TAILNET_IP:53`
only (it deliberately doesn't bind `0.0.0.0:53` — systemd-resolved already holds the
loopback). Reachability is enforced in two places: the ufw rules from
[Quickstart §4](quickstart#4-lock-the-box-down-ufw) allow `53` and `443` from the tailnet,
and the ufw-docker gate from the [bootstrap script](quickstart#2-get-in-join-the-tailnet)
is what makes those rules apply to this container at all — published ports ride Docker's
`FORWARD` chain, which UFW's `INPUT` rules never inspect
(mechanics in [Hardening](hardening#docker-and-ufw-the-forward-gate)).

## Verify from a tailnet device

Replace `radarr` with any panel name:

| OS | Command | Expected |
| -- | ------- | -------- |
| macOS | `dscacheutil -q host -a name radarr.<DOMAIN>` | Address = your tailnet IP |
| Linux | `getent hosts radarr.<DOMAIN>` | tailnet IP |
| Windows | `Resolve-DnsName radarr.<DOMAIN>` | IPAddress = your tailnet IP (use `Resolve-DnsName`, **not** `nslookup` — it misses split-DNS/NRPT rules) |

From the box itself: `just dnscheck`. A device **not** on the tailnet won't resolve these at
all — there's no public record for the panels, by design.

## Troubleshooting

- **Names don't resolve yet** — devices pick up the new nameserver on their next Tailscale
  DNS update. Rejoin the tailnet, or flush: `sudo dscacheutil -flushcache` (macOS),
  `sudo systemctl restart systemd-resolved` (Linux), `ipconfig /flushdns` (Windows).
- **The box was rebuilt / tailnet IP changed** — run the bootstrap script (or
  `sudo tailscale up`) on the new box, re-run `just init force` (it re-detects and
  refreshes `TAILNET_IP`), then update the nameserver IP in the Tailscale admin console.
- **Nothing answers on the box itself** — `just dnscheck`; confirm CoreDNS is up
  (`docker compose -f stacks/traefik/compose.yaml ps coredns`), ufw has the `53` rules
  (`sudo ufw status`), and the forward gate is applied (`sudo ufw-docker check`; verify with
  `sudo iptables -nL DOCKER-USER`). From the **public internet**, nothing works until
  [going public](quickstart#10-go-public-last) — that's by design.
- **You skipped the console step** — `just dns` prints exactly what to paste in.
