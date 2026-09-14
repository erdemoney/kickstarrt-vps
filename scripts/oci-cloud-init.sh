#!/usr/bin/env bash
#
# oci-cloud-init.sh - paste into Oracle Cloud: Advanced options -> Initialization
# script, when creating the instance (see docs/oci.md).
#
# Joins the fresh Ubuntu box to your tailnet on first boot - no console login
# needed, because Canonical Ubuntu images configure no console password - and
# installs the stack's prerequisites (git, just, Docker + compose plugin) for
# the `ubuntu` user. It is scripts/prerequisites.sh with the headless join
# credentials cloud-init can't type for you.
#
# Before pasting, replace TS_AUTH_KEY below with a fresh **ephemeral** Tailscale
# auth key: admin console (login.tailscale.com) -> Settings -> Keys -> Generate
# auth key, tick Ephemeral. Ephemeral means the key expires and the node
# disappears with the instance, so a recreated box re-joins with a fresh key.
# Never reuse a key; if one leaks, delete it in the admin console immediately.

set -euo pipefail

export TS_HOSTNAME=kickstarrt            # name shown in the Tailscale admin console
export TARGET_USER=ubuntu                # OCI's default user - it owns the docker group
export TS_AUTH_KEY='PASTE-YOUR-EPHEMERAL-AUTH-KEY'

curl -fsSL https://raw.githubusercontent.com/erdemoney/kickstarrt-vps/main/scripts/prerequisites.sh | bash

if ! tailscale ip -4 >/dev/null 2>&1; then
    printf '\n[rescue] tailnet join FAILED. The VCN 22 rule is still present for initial setup, so\n'
    printf '         log in over the public IP (OCI console -> instance details -> Public IP\n'
    printf '         address) with the key you pasted at creation:\n'
    printf '           ssh ubuntu@<PUBLIC-IP>\n'
    printf '         then join by hand:\n'
    printf '           sudo tailscale up     # approve the URL it prints\n'
    printf '           tailscale ip -4       # the tailnet address to keep\n'
    printf '         Delete the VCN 22 ingress rule once the tailnet is your working door\n'
    printf '         (Hardening -> Firewall, in the quickstart).\n'
fi