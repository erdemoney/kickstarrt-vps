---
title: Oracle Cloud (free tier)
nav_order: 2
---

# Oracle Cloud free-tier VPS

The walkthrough from zero to a running Ubuntu 26.04 box on Oracle Cloud **Always Free**, built to
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

## 1. Virtual cloud network (VCN) — via the VCN wizard

The console's [VCN wizard](https://cloud.oracle.com/networking/solutions/vcn) (**"Start VCN
wizard"**) creates everything the box needs in one pass — the VCN, a public subnet, and the
internet gateway + route that give it outbound internet:

| Field | Fill in |
| ----- | ------- |
| **VCN name** | `kickstarrt-vcn` |
| **Compartment** | leave the default (root) compartment — use the same one for everything below |
| **VCN IPv4 CIDR block** | `10.0.0.0/16` |
| **Enable IPv6** | leave unchecked (not needed) |
| **Use DNS hostnames in this VCN** | keep checked (default) — instances get hostnames from the DNS label, which auto-fills from the name |
| **Configure public subnet → IP address type** | IPv4 |
| **Configure public subnet → IPv4 CIDR block** | `10.0.0.0/24` |
| **Configure private subnet** | leave the defaults — the wizard always creates one, but it isn't used by this stack |

**Next** → review → **Create VCN**. The wizard builds the VCN, the public subnet, the **Internet
Gateway**, and the `0.0.0.0/0 → Internet Gateway` default route automatically — no other networking
steps are needed.

**About the security lists:** the ones the wizard attaches permit SSH/`22` and ICMP from the
internet and everything from inside the VCN. Leave them alone — nothing here listens inbound.
The real enforcement point is the OS firewall (ufw deny-all in [Hardening](hardening)); sshd is
only ever reachable from your tailnet.

## 2. Create the compute instance

[Compute → Instances → Create instance](https://cloud.oracle.com/compute/instances/create):

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt` |
| **Creation In Compartment** | same compartment |
| **Placement → Availability domain** | leave the default — regions differ (some have a single AD, others several); it doesn't matter for this stack |
| **Image** | **Change image** → Operating system **Ubuntu** → Version **Canonical Ubuntu 26.04 Minimal aarch64** — the Minimal **aarch64** build, for this Arm shape (don't pick the x86 variant). Ubuntu matches this repo's `apt`/`ufw`/`fail2ban` commands verbatim |
| **Shape** | **Change shape** → **VM.Standard.A1.Flex** (Ampere, Arm): **2 OCPU / 12 GB / 2 Gbps** — the console spells it "2 core OCPU, 12 GB memory, 2 Gbps network bandwidth", the Always-Free ARM allotment. The only valid shape for this stack: every image in `stacks/` publishes `arm64` builds, and the x86 shapes (e.g. `VM.Standard.E2.1.Micro` at 1 GB) are not a valid choice. The shape must show **Always Free-eligible** |
| **Networking → Primary VNIC** | select existing VCN `kickstarrt-vcn` and its **public subnet** (the one the wizard created); private IPv4 **automatically assigned**; **Public IPv4 address: Automatically assign** — the box gets a public IP for *outbound* internet only; ufw is deny-all, nothing listens inbound, so nothing is exposed |
| **Add SSH keys** | **No SSH keys — leave it empty.** You never SSH over the public internet: bootstrap is via the console, then everything rides the Tailscale tailnet (see [Hardening](hardening)) |
| **Storage → Boot volume** | default (≈ 46.6 GB, Oracle-managed encryption, in-transit encryption on) — no extra block volumes |

**Advanced options** (expand it; everything defaults): keep the **Initialization script empty** —
first-run setup happens over the console per [Hardening](hardening), not via a bootstrap script.
The **Security** section stays off as well — **Secure Boot**, **Measured Boot**, and **Trusted
Platform Module** are all disabled by default; shielding guards boot integrity for shared tenancy
and this box gains nothing from it behind the tunnel.

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
- **"Out of capacity"** creating an A1 is the norm, not the exception — Always-Free ARM is the
  most contended shape on OCI. Capacity frees up continually, so: hit **Create** again (retries
  often succeed in minutes), try a different availability domain if your region has more than one,
  and if it's single-AD, wait and retry. You can also launch a smaller A1 (e.g. **1 OCPU / 6 GB**)
  when capacity appears and resize to 2 OCPU / 12 GB afterward — flex shapes resize in place,
  still free. The reliable long-term unblock is upgrading to Pay As You Go (previous note). Keep
  the Always Free tag on the shape, or you'll be billed.