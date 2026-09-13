---
title: Oracle Cloud (free tier)
nav_order: 2
---

# Oracle Cloud free-tier VPS

The walkthrough from zero to a running Ubuntu 24.04 box on Oracle Cloud **Always Free**, built to
match this repo's access model: **no public ports at all**. Bootstrap via the provider console,
manage via Tailscale, serve apps via the Cloudflare tunnel — there is no SSH-on-the-internet step
anywhere in it.

## 0. About the Oracle Cloud free tier

Oracle Cloud has offered a genuinely free VPS gift since 2020: the **Free Tier** bundles a
few things that are *always* free — no trial credits, no expiry — including exactly what this
stack needs:

- **Compute**: Always-Free **Ampere A1** (ARM) shapes, currently **2 OCPU / 12 GB** of RAM.
- **Storage**: block volumes, plus object storage for backups.
- **Networking**: a **public IPv4**, a VCN with an internet gateway, and the security
  list/route-table plumbing. Use it for *outbound* internet only — this stack opens zero ports.

The catch: Oracle will **reclaim** Always-Free instances it considers idle, and ARM capacity is
frequently "out of capacity" in busy regions. Both are covered later on this page. Oracle also
asks for a card at signup to verify identity (a hold, not a charge) — the Always-Free resources
never bill you.

**Sign up** → [oracle.com/cloud/free](https://www.oracle.com/cloud/free/): pick your name/email,
choose a **home region** (choose carefully — data residency is locked to it and the A1 thundering
herd lives there), verify the card, done. Everything after signup happens in the **Oracle Cloud
console** at [cloud.oracle.com](https://cloud.oracle.com).

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