---
title: Oracle Cloud (free tier)
nav_order: 15
---

# Appendix: Oracle Cloud free-tier VPS

The provider-specific walkthrough from zero to a running Ubuntu 26.04 box on Oracle Cloud
**Always Free**. Once the box exists, everything else is the standard
[Quickstart](quickstart). The overview's [access model](index#the-access-model) applies here
like everywhere: the box's only wide-open door is `:443`, opened last; a short public-SSH
window during setup is closed by [Quickstart §5](quickstart#5-lock-the-box-down-ufw).

## 0. About the free tier

Oracle Cloud's **Free Tier** bundles a few things that are *always* free — no trial credits,
no expiry — including exactly what this stack needs:

- **Compute**: Always-Free **Ampere A1** (ARM) shapes, currently **2 OCPU / 12 GB** of RAM.
- **Storage**: block volumes, plus object storage for backups.
- **Networking**: a **public IPv4**, a VCN with an internet gateway, and the security
  list/route-table plumbing.

The catch: Oracle **reclaims Always-Free instances it considers idle**, and ARM capacity is
frequently "out of capacity" in busy regions — both covered in the notes at the bottom of this
page. Signup asks for a card to verify identity (a hold, not a charge); the Always-Free
resources never bill you.

**Sign up** → [oracle.com/cloud/free](https://www.oracle.com/cloud/free/): pick your
name/email, choose a **home region** (choose carefully — data residency is locked to it and
the A1 capacity contest lives there), verify the card, done. Everything after signup happens
in the **Oracle Cloud console** at [cloud.oracle.com](https://cloud.oracle.com).

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

**Next** → review → **Create VCN**. The wizard builds the VCN, the public subnet, the
**Internet Gateway**, and the `0.0.0.0/0 → Internet Gateway` default route automatically.

**After the wizard creates the public subnet**, open its **Security List** (Public subnet →
Security Lists, or Networking → Virtual cloud networks → `kickstarrt-vcn` → Security Lists →
`Default Security List for kickstarrt-vcn`) and make **two additions**: an **Ingress Rule**
for **TCP, destination port `443`, source `0.0.0.0/0`** ("Allow public HTTPS to Traefik") and
one for **TCP, destination port `80`, source `0.0.0.0/0`** ("Allow public HTTP — serves only
the `http → https` redirect"). Leave the rest alone: the wizard's default `22` ingress rule
stays **for now** — that's the door you `ssh` in through during setup, and it's deleted in
[Quickstart §5](quickstart#5-lock-the-box-down-ufw). The OS firewall (ufw) is the real
per-port enforcement point either way: nothing answers from the internet until the
[going-public](quickstart#10-go-public-last) step.

## 2. Create the compute instance

[Compute → Instances → Create instance](https://cloud.oracle.com/compute/instances/create):

| Field | Fill in |
| ----- | ------- |
| **Name** | `kickstarrt` |
| **Creation In Compartment** | same compartment |
| **Placement → Availability domain** | leave the default — regions differ (some have a single AD, others several); it doesn't matter for this stack |
| **Image** | **Change image** → Operating system **Ubuntu** → Version **Canonical Ubuntu 26.04 Minimal aarch64** — the Minimal **aarch64** build, for this Arm shape (don't pick the x86 variant). Ubuntu matches this repo's `apt`/`ufw`/`fail2ban` commands verbatim |
| **Shape** | **Change shape** → **VM.Standard.A1.Flex** (Ampere, Arm): **2 OCPU / 12 GB / 2 Gbps** — the console spells it "2 core OCPU, 12 GB memory, 2 Gbps network bandwidth", the Always-Free ARM allotment. The only valid shape for this stack: every image in `stacks/` publishes `arm64` builds, and the x86 shapes (e.g. `VM.Standard.E2.1.Micro` at 1 GB) are not a valid choice. The shape must show **Always Free-eligible** |
| **Networking → Primary VNIC** | select existing VCN `kickstarrt-vcn` and its **public subnet** (the one the wizard created); private IPv4 **automatically assigned**; **Public IPv4 address: Automatically assign** — the box gets its public IP here; nothing is reachable until the [going-public](quickstart#10-go-public-last) step |
| **Add SSH keys** | paste your **workstation's public key** (`~/.ssh/id_ed25519.pub`) — it's how you get in: during setup over the public IP, and over the tailnet afterwards. Canonical Ubuntu images configure **no console password**, so this key is the only way onto the box. Never leave it empty |
| **Storage → Boot volume** | default (≈ 46.6 GB, Oracle-managed encryption, in-transit encryption on) — no extra block volumes |

**Advanced options**: leave everything default — no cloud-init script (first-run setup
happens over SSH, exactly like any other VPS — [Quickstart §2](quickstart#2-get-in-join-the-tailnet)),
and the Secure Boot / TPM toggles off.

**Create**, then wait a few minutes for provisioning.

## After creation

The instance is up, and you get in over SSH like any other VPS — the VCN's `22` rule is still
in place, which is the point: that's the door for the **first login**. From the instance's
details page note the **Public IP address**, then:

```bash
ssh ubuntu@<PUBLIC-IP>     # key you pasted at creation; proceed even if a "host key" prompt appears
```

Then continue with the [Quickstart](quickstart#2-get-in-join-the-tailnet): the bootstrap
one-liner installs the stack's prerequisites and joins the box to your tailnet — approve the
auth URL it prints, and it hands you the tailnet address that becomes your SSH address from
then on. Once tailnet SSH is confirmed, [Quickstart §5](quickstart#5-lock-the-box-down-ufw)
closes the `22` door (delete the VCN ingress rule, lock ufw to tailnet-only) and every later
login goes over the tailnet.

The **Console connection** can't help here: Canonical Ubuntu images configure **no console
password**, so the console never accepts a login. Your SSH key — pasted at creation — is the
only way onto the box; recovery for a tailnet-locked box is the volume-attach rescue (detach
the boot volume, mount it on a second instance, and fix the node).

Notes:

- **This stack fits the A1 comfortably.** Debrid streaming keeps nothing on disk and the
  Always-Free allotment is 12 GB RAM — plenty for Jellyfin, the \*arrs, and CrowdSec, with
  the two cores leaving room for occasional CPU transcode.
- **Reserve the public IP before adding DNS.** An auto-assigned public IP is released when
  the instance stops and may come back different on a rebuild — which would strand the DNS
  records. On the instance page → **Attached VNICs** → the public IP → **Convert to Reserved
  IP** (or Networking → IP management → Reserve public IP, then assign it). Reserved public
  IPs are Always-Free eligible. This *is* the IP your [A records](ingress#adding-a-public-hostname-dns-record)
  point at.
- Oracle **reclaims Always-Free instances it considers idle** (low CPU/network for a while).
  This stack mostly benches idle between streams, so the box can vanish without warning; the
  common fix is to upgrade the account to **Pay As You Go** — Always-Free resources stay
  free, but the account stops being flagged as an unused free tier and the reaper leaves it
  alone. To upgrade: navigation menu → **Billing & Cost Management** → **Upgrade and Manage
  Payment** → tick the terms box → **Upgrade your account**. As soon as a card is on the
  account, Oracle places a **$100 pre-authorization hold** on it — it shows on your statement
  as "Pending" and is reversed automatically within a few business days; a hold, not a
  charge. PAYG accounts also get higher **capacity limits** than the Always-Free pool — which
  makes the "out of capacity" problem below mostly go away.
- **"Out of capacity"** creating an A1 is the norm, not the exception — Always-Free ARM is
  the most contended shape on OCI. Capacity frees up continually, so: hit **Create** again
  (retries often succeed in minutes), try a different availability domain if your region has
  more than one, and if it's single-AD, wait and retry. You can also launch a smaller A1
  (e.g. **1 OCPU / 6 GB**) when capacity appears and resize to 2 OCPU / 12 GB afterward —
  flex shapes resize in place, still free. The reliable long-term unblock is upgrading to Pay
  As You Go (previous note). Keep the Always Free tag on the shape, or you'll be billed.
