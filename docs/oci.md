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

On the create page, select the wizard's **"Add internet connectivity"** option: it creates the
**Internet Gateway** and the `0.0.0.0/0 → Internet Gateway` default route automatically (free) —
that's everything the box needs for outbound internet, so there's no separate gateway step later.
(If your console doesn't offer it, create the VCN, then add an Internet Gateway and a `0.0.0.0/0`
route to it manually — the result is the same.) The VCN's **default** route table, security list,
and DHCP options are created automatically either way.

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

## 3. Create the compute instance

[Compute → Instances → Create instance](https://cloud.oracle.com/compute/instances/create):

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt` |
| **Creation In Compartment** | same compartment |
| **Placement → Availability domain** | AD 1 (default) |
| **Image** | **Change image** → Operating system **Ubuntu** → Version **Canonical Ubuntu 24.04 LTS**. OCI ships no Debian and no Ubuntu 26.04 image yet — 24.04 is the current Ubuntu LTS here. Use the **standard** Ubuntu image, not Minimal: OCI documents Minimal as unsuitable for its Arm shapes. Ubuntu matches this repo's `apt`/`ufw`/`fail2ban` commands verbatim |
| **Shape** | **Change shape** → **VM.Standard.A1.Flex** (Ampere, Arm) → **2 OCPU / 12 GB**, the Always-Free ARM allotment. The only valid shape for this stack: every image in `stacks/` publishes `arm64` builds, and the x86 shapes (e.g. `VM.Standard.E2.1.Micro` at 1 GB) are not a valid choice. The shape must show **Always Free-eligible** |
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

- **This stack fits the A1 comfortably.** Debrid streaming keeps nothing on disk and the
  Always-Free allotment is 12 GB RAM — plenty for Jellyfin, the \*arrs, and CrowdSec, with the two
  cores leaving room for occasional CPU transcode.
- Oracle **reclaims Always-Free instances it considers idle** (low CPU/network for a while). This
  stack mostly benches idle between streams, so the box can vanish without warning; the common fix
  is to upgrade the account to **Pay As You Go** — Always-Free resources stay free, but the account
  stops being flagged as an unused free tier and the reaper leaves it alone.
- **"Out of capacity"** creating an A1 is common — Always-Free ARM is the most contended shape on
  OCI. Try a different availability domain or region, and keep the Always Free tag on the shape, or
  you'll be billed.