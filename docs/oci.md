---
title: Oracle Cloud (free tier)
nav_order: 2
---

# Oracle Cloud free-tier VPS

The walkthrough from zero to a running Ubuntu 24.04 box on Oracle Cloud **Always Free**, built to
match this repo's access model: **no public ports at all**. Bootstrap via the provider console,
manage via Tailscale, serve apps via the Cloudflare tunnel — there is no SSH-on-the-internet step
anywhere in it.

Sign up for Oracle Cloud **Free Tier** first (dash.cloud.oracle.com). Everything on this page
uses **Always Free** resources — no trial credits, no hourly charges.

## 1. Create the virtual cloud network (VCN)

[Networking → VCNs](https://cloud.oracle.com/networking/vcns) → **Create VCN**:

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt-vcn` |
| **Create In Compartment** | leave the default (root) compartment — use the same one for everything below |
| **IPv4 CIDR Blocks** | `10.0.0.0/16` (one block; the subnet in step 2 sits inside it) |
| **IPv6 Prefixes** | leave unchecked (not needed) |
| **ULA Prefixes** | leave unchecked |
| **DNS Resolution** | keep **Use DNS hostnames in this VCN** checked (default) — instances get hostnames from the DNS label, which auto-fills from the name |
| **Tags / security attributes** | none |

Create. The console then generates the VCN's **default** route table, security list, and DHCP
options automatically — but *not* an internet gateway; that's step 3.

## 2. Create the subnet

Back on the [VCNs](https://cloud.oracle.com/networking/vcns) page → open `kickstarrt-vcn` →
**Subnets** tab → **Create Subnet**:

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt-public` |
| **Create In Compartment** | same compartment as the VCN |
| **Subnet Type** | **Regional** (recommended) |
| **IP Type** | **IPv4 CIDR Block** → `10.0.0.0/24` |
| **Route Table** | the VCN's **Default Route Table** |
| **Subnet Access** | **Public Subnet** — "Allow public IP addresses for instances in this subnet". Required: only a public subnet routes outbound through the free internet gateway; a private one would need a *paid* NAT gateway |
| **DNS Resolution** | keep **Use DNS hostnames in this subnet** checked |
| **DHCP Options** | default |
| **Security List** | the VCN's **Default Security List** — leave as-is (see note) |
| **Resource logging** | off |
| **Tags** | none |

**About the security list:** the default one permits SSH/`22` and ICMP from the internet and
everything from inside the VCN. That's fine here — the real enforcement point is the OS firewall
(ufw deny-all in [Hardening](hardening)), and sshd is only ever reachable from your tailnet. If
you want defense-in-depth at the OCI layer, delete the `22` ingress rule (it's never used for
access) — but leave the VCN-internal and ICMP rules alone, and never forward `80`/`443`.

## 3. Internet gateway + default route (don't skip)

A "public" subnet has no internet until a route points at an **Internet Gateway**. Without this,
`apt`, the Tailscale installer, and the tunnel all fail on a brand-new box:

1. [Networking → Internet Gateways](https://cloud.oracle.com/networking/internet-gateways) →
   **Create Internet Gateway** → name `igw` → create (in `kickstarrt-vcn`).
2. `kickstarrt-vcn` → **Route Tables** → **Default Route Table** → **Add Route**:
   - Target Type: **Internet Gateway**
   - Destination: `0.0.0.0/0`
   - Target: `igw`

## 4. Create the compute instance

[Compute → Instances → Create instance](https://cloud.oracle.com/compute/instances/create):

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt` |
| **Creation In Compartment** | same compartment |
| **Placement → Availability domain** | AD 1 (default) |
| **Image** | **Change image** → Operating system **Ubuntu** → Version **Canonical Ubuntu 24.04 LTS**. OCI ships no Debian platform image; Ubuntu matches this repo's `apt`/`ufw`/`fail2ban` commands verbatim |
| **Shape** | leave **VM.Standard.E2.1.Micro** — it must show **Always Free-eligible** (1 OCPU, 1 GB RAM). RAM reality check below |
| **Management** | defaults; **Initialization script** empty — first-run setup happens over the console per [Hardening](hardening) |
| **Availability configuration** | defaults (live migration auto; restore lifecycle default) |
| **Oracle Cloud Agent** | leave enabled |
| **Networking → Primary VNIC** | select existing VCN `kickstarrt-vcn` and subnet `kickstarrt-public`; private IPv4 **automatically assigned**; **Public IPv4 address: Automatically assign** — the box gets a public IP for *outbound* internet only; ufw is deny-all, nothing listens inbound, so nothing is exposed |
| **Add SSH keys** | **No SSH keys — leave it empty.** You never SSH over the public internet: bootstrap is via the console, then everything rides the Tailscale tailnet (see [Hardening](hardening)) |
| **Storage → Boot volume** | default (≈ 46.6 GB, Oracle-managed encryption, in-transit encryption on) — no extra block volumes |

**Create**, then wait a few minutes for provisioning.

## After creation

From the instance's details page, open **Console connection** (a hypervisor-level shell — it
works with no SSH keys and regardless of ufw) and continue to
[Hardening](hardening#1-tailscale--your-only-way-in-no-public-port): install Tailscale there, then
every later login goes over the tailnet, not the console.

Notes:

- **1 GB RAM is tight for this stack.** Jellyfin + the \*arrs + CrowdSec comfortably exceed a
  gigabyte once they're working. The micro is fine for a light, direct-play, few-users setup —
  don't expect CPU transcoding. If your region has capacity, the **Always-Free ARM (Ampere A1)**
  shapes are the better home (current limit: 2 OCPU / 12 GB) — before switching, confirm every
  container image in `stacks/` publishes an `arm64` build (a few, like Decypharr's, may not).
- Oracle **reclaims Always-Free instances it considers idle** (low CPU/network for a while). This
  stack mostly benches idle between streams, so the box can vanish; the common fix is to upgrade
  the account to **Pay As You Go** — Always-Free resources stay free, but the account stops being
  flagged as an unused free tier and the reaper leaves it alone.
- **"Out of capacity"** creating the micro happens; try a different availability domain or region.
  The Always Free tag must show on the shape, or you'll be billed.