---
title: Oracle Cloud (free tier)
nav_order: 2
---

# Oracle Cloud free-tier VPS

The walkthrough from zero to a running Ubuntu 26.04 box on Oracle Cloud **Always Free**, built to
match this repo's access model: **one serving port (`443`, opened last) plus `80` as a `http →
https` redirect**. Bootstrap over SSH, manage via Tailscale, serve the apps straight off the VPS's
public IP — the box's only wide-open door is `:443`, opened last; a short public-SSH window during
setup is closed the moment [Hardening](hardening) locks SSH to the tailnet.

## 0. About the Oracle Cloud free tier

Oracle Cloud has offered a genuinely free VPS gift since 2020: the **Free Tier** bundles a
few things that are *always* free — no trial credits, no expiry — including exactly what this
stack needs:

- **Compute**: Always-Free **Ampere A1** (ARM) shapes, currently **2 OCPU / 12 GB** of RAM.
- **Storage**: block volumes, plus object storage for backups.
- **Networking**: a **public IPv4**, a VCN with an internet gateway, and the security
  list/route-table plumbing. That IP is this stack's ingress — it serves `:443` on it (plus the
  `:80` `http → https` redirect; both opened last, [Hardening](hardening)) — so it should stay
  **stable**: once you add DNS records, the IP needs to survive stop/start and rebuilds (see
  "Reserve the public IP" below).

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
Gateway**, and the `0.0.0.0/0 → Internet Gateway` default route automatically — nothing else to
wire up. The two networking additions this stack needs (`:443`, plus `:80` for the https
redirect) happen right after, below.

**After the VCN wizard creates the public subnet**, open its **Security List** (Public subnet →
Security Lists, or Networking → Virtual cloud networks → `kickstarrt-vcn` → Security Lists →
`Default Security List for kickstarrt-vcn`) and make **two additions**: an **Ingress Rule** for
**TCP, destination port `443`, source `0.0.0.0/0`** ("Allow public HTTPS to Traefik") and one for
**TCP, destination port `80`, source `0.0.0.0/0`** ("Allow public HTTP − serves only the
`http → https` redirect"). Leave the rest alone — the wizard's default `22` ingress rule stays
**for now**: that's the door you `ssh` in through during setup (key-only — Ubuntu sets no
password for its user, so only the key you paste can log in). It is **closed at
[Hardening → Firewall](hardening#3-firewall--ufw)**, the step that locks SSH to the tailnet. The
real per-port enforcement point, though, is the **OS firewall**: ufw stays deny-incoming and the
stack doesn't answer from the internet until the deliberate
[Going public](quickstart#going-public-last) step runs `sudo ufw allow 443/tcp` and
`sudo ufw allow 80/tcp`.

## 2. Create the compute instance

[Compute → Instances → Create instance](https://cloud.oracle.com/compute/instances/create):

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt` |
| **Creation In Compartment** | same compartment |
| **Placement → Availability domain** | leave the default — regions differ (some have a single AD, others several); it doesn't matter for this stack |
| **Image** | **Change image** → Operating system **Ubuntu** → Version **Canonical Ubuntu 26.04 Minimal aarch64** — the Minimal **aarch64** build, for this Arm shape (don't pick the x86 variant). Ubuntu matches this repo's `apt`/`ufw`/`fail2ban` commands verbatim |
| **Shape** | **Change shape** → **VM.Standard.A1.Flex** (Ampere, Arm): **2 OCPU / 12 GB / 2 Gbps** — the console spells it "2 core OCPU, 12 GB memory, 2 Gbps network bandwidth", the Always-Free ARM allotment. The only valid shape for this stack: every image in `stacks/` publishes `arm64` builds, and the x86 shapes (e.g. `VM.Standard.E2.1.Micro` at 1 GB) are not a valid choice. The shape must show **Always Free-eligible** |
| **Networking → Primary VNIC** | select existing VCN `kickstarrt-vcn` and its **public subnet** (the one the wizard created); private IPv4 **automatically assigned**; **Public IPv4 address: Automatically assign** — the box gets its public IP here; with ufw deny-incoming and the security list closed except `443`, nothing is reachable until the [going-public](quickstart#going-public-last) step |
| **Add SSH keys** | paste your **workstation's public key** (`~/.ssh/id_ed25519.pub`) — it's how you get in: during setup over the public IP, and over the tailnet afterwards. Canonical Ubuntu images configure **no console password**, so this key is the only way onto the box. Never leave it empty |
| **Storage → Boot volume** | default (≈ 46.6 GB, Oracle-managed encryption, in-transit encryption on) — no extra block volumes |

**Advanced options** (expand it): keep the **Initialization script empty** — there is no
cloud-init bootstrap; first-run setup happens over SSH, exactly like any other VPS
([Quickstart §1](quickstart#1-get-in-set-up-tailscale)). The **Security** section stays off as
well — **Secure Boot**, **Measured Boot**, and **Trusted Platform Module** are all disabled by
default; shielding guards boot integrity for shared tenancy and this box gains nothing from it.

**Create**, then wait a few minutes for provisioning.

## After creation

The instance is up, and you get in over SSH like any other VPS — the VCN's `22` rule is still in
place, which is the point: that's the door for the **first login**. From the instance's details
page note the **Public IP address**, then:

```bash
ssh ubuntu@<PUBLIC-IP>     # key you pasted at creation; proceed even if a "host key" prompt appears
```

Then follow [Quickstart → 1. Get in](quickstart#1-get-in-set-up-tailscale): the bootstrap one-liner
installs the stack's prerequisites and joins the box to your tailnet — approve the auth URL it
prints, and it hands you the tailnet address that becomes your SSH address from then on. Once the
tailnet is confirmed working, [Hardening → Firewall](hardening#3-firewall--ufw) closes the `22`
door (delete the VCN ingress rule, lock ufw to tailnet-only) and every later login goes over the
tailnet.

The **Console connection** can't help here: Canonical Ubuntu images configure **no console
password**, so the console never accepts a login. Your SSH key — pasted at creation — is the only
way onto the box. Keep it as the break-glass door where your provider's image allows it; on
Ubuntu it's the volume-attach rescue instead.

Notes:

- **This stack fits the A1 comfortably.** Debrid streaming keeps nothing on disk and the
  Always-Free allotment is 12 GB RAM — plenty for Jellyfin, the \*arrs, and CrowdSec, with the two
  cores leaving room for occasional CPU transcode.
- **Reserve the public IP before adding DNS.** An auto-assigned public IP is released when the
  instance stops and may come back different on a rebuild — which would strand the DNS records.
  On the instance page → **Attached VNICs** → the public IP → **Convert to Reserved IP** (or
  Networking → IP management → Reserve public IP, then assign it). Reserved public IPs are
  Always-Free eligible. This *is* the IP your [A records](ingress#adding-a-public-hostname-dns-record)
  point at.
- Oracle **reclaims Always-Free instances it considers idle** (low CPU/network for a while). This
  stack mostly benches idle between streams, so the box can vanish without warning; the common fix
  is to upgrade the account to **Pay As You Go** — Always-Free resources stay free, but the account
  stops being flagged as an unused free tier and the reaper leaves it alone. To upgrade: navigation
  menu → **Billing & Cost Management** → **Upgrade and Manage Payment** → tick the terms box →
  **Upgrade your account**. As soon as a card is on the account, Oracle places a **$100
  pre-authorization hold** on it (like the ~$1 signup hold) — it shows on your statement as
  "Pending" and is reversed automatically within a few business days; it is a hold, not a charge.
  PAYG accounts also get different, higher **capacity limits** than the Always-Free pool — which is
  what makes the "out of capacity" problem in the next note mostly go away.
- **"Out of capacity"** creating an A1 is the norm, not the exception — Always-Free ARM is the
  most contended shape on OCI. Capacity frees up continually, so: hit **Create** again (retries
  often succeed in minutes), try a different availability domain if your region has more than one,
  and if it's single-AD, wait and retry. You can also launch a smaller A1 (e.g. **1 OCPU / 6 GB**)
  when capacity appears and resize to 2 OCPU / 12 GB afterward — flex shapes resize in place,
  still free. The reliable long-term unblock is upgrading to Pay As You Go (previous note). Keep
  the Always Free tag on the shape, or you'll be billed.