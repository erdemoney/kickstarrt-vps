---
title: Decypharr
nav_order: 5
---

# Decypharr (debrid gateway)

Decypharr mounts your debrid provider as a FUSE filesystem and exposes qBittorrent- and
SABnzbd-compatible APIs, so Sonarr/Radarr see "instant" debrid files instead of a download
queue. It runs from the media-server stack with the FUSE plumbing already in the compose
(`/mnt/debrid:/mnt:rshared`, `/dev/fuse`, `SYS_ADMIN`, `apparmor:unconfined`) — nothing to
add.

## First-run setup wizard

Visit `https://decypharr.<DOMAIN>` once, over the tailnet ([Quickstart §8](quickstart#8-set-up-the-apps)).
Wizard order:

1. **Authentication** — create the admin username/password. The **API token shown once** after
   setup completes is Decypharr's *own* API credential: save it (regenerates via
   `POST /api/refresh-token`). It is **not** the password
   the \*arrs' download-client config asks for — that's the arr's own API key
   ([The \*arrs](arrs#download-clients-sonarrradarr--decypharr)).
2. **Debrid account** — add at least one provider (Real-Debrid, AllDebrid, Debrid-Link,
   Torbox, Premiumize) with its API key; Torbox also provides Usenet ([Services](services)).
3. **Usenet (optional)** — NNTP server details, only if downloading from Usenet.
4. **Download Folder Path** — `/mnt/decypharr/downloads` — where Decypharr places the symlinks
   the \*arrs import. Keep it **on the same mount as the root folders** or imports degrade to
   slow disk copies that dereference the symlink
   ([The \*arrs](arrs#imports-are-symlinks-not-hardlinks)). Don't point it at an off-mount dir.
5. **Mount System** — pick **DFS**, mount path `/mnt/decypharr` (what the \*arrs import from),
   and a cache dir. Keep the **Cache Directory** default `/tmp/decypharr-cache`: it's a
   disposable chunk cache (re-warms on demand; wiping it on redeploys costs nothing) and
   keeping it in the container keeps it out of restic backups and `$CONFIG_DIR`. Don't point
   it at the FUSE mount `/mnt/decypharr` (it would recurse into debrid) or at a tmpfs/RAM (a
   chunk cache is sized in GB — RAM is for Jellyfin's transcode). Cap the **Disk Cache Size**
   at a few GB so the rolling cache can't fill the system disk.

Outside the wizard: **root folders** are lowercase subpaths of the same mount, and they must
match *exactly*: `/mnt/decypharr/shows` for Sonarr, `/mnt/decypharr/movies` for Radarr, and
Jellyfin's libraries point at those same folders
([Jellyfin](jellyfin#1-libraries-on-the-decypharr-mount)).

Config is written to `$CONFIG_DIR/decypharr/configs/config.json`.

## Integration with Sonarr/Radarr

The wiring has two sides; the \*arr-UI side (download clients, root folders) is documented in
[The \*arrs](arrs#download-clients-sonarrradarr--decypharr). Decypharr's own side:

- **Outbound** — Decypharr → Settings → **Arrs**: it auto-detects apps that hit it; give each
  arr's host (`http://sonarr:8989`, never the public URL) and API key.
- **Repair worker / queue cleanup** — enable in Settings → Arrs (the blacklist + research
  defaults are sensible) so failed grabs don't clog the queue.

No **path mapping** is needed in this stack: Decypharr's mount path and the arrs' bind are
the same absolute path (`/mnt/decypharr`), so the path it reports is the path they can open.
Add a remote path mapping only if you deviate — a different mount path in Decypharr's config,
a different container path in the bind, or Decypharr on another host.

## Visibility of the mount

Decypharr creates its FUSE mount *inside* its own container; `:rshared` pushes it out to the
host at `/mnt/debrid/decypharr`, and `jellyfin`/`sonarr`/`radarr`/`bazarr` receive it with
`:rslave`. Both halves ship in the compose. Two rules make that work, and both are easy to
get wrong if you ever edit the binds:

- **Bind the parent, not the mountpoint.** Consumers bind `/mnt/debrid` (as `/mnt`), not
  `/mnt/decypharr:/mnt/decypharr`. A mount appearing *at* `/mnt/decypharr` belongs to its
  parent mount, so it propagates to anyone watching the parent — but a bind of the
  mountpoint itself captures whatever was there at container start and never sees the FUSE
  mount arrive.
- **The flags are asymmetric.** The producer shares (`:rshared`); the consumers receive
  (`:rslave`). A plain bind with no flag propagates nothing in either direction.

The indirection through the dedicated host directory `/mnt/debrid` (bound in *as* `/mnt`)
keeps the containers from ever seeing the host's real `/mnt` — backup drives or other disks
mounted there stay invisible to five media containers that would otherwise hold them
read-write.

The net effect: **no startup order to respect** — consumers can boot before Decypharr and the
mount appears inside them when it's created; restarting Decypharr re-propagates instead of
leaving the others with a stale `Transport endpoint is not connected` handle.

One-time host prep and recovery:

```bash
sudo mkdir -p /mnt/debrid                    # before first `just up` (explicit > root-owned auto-create)
sudo fusermount -u -z /mnt/debrid/decypharr  # clear a stale mountpoint after an unclean kill
findmnt -o TARGET,PROPAGATION /mnt/debrid    # want "shared"; systemd makes / rshared at boot,
sudo mount --make-rshared /mnt/debrid        # so this fix is rarely needed
```

If a consumer comes up empty (`/mnt/decypharr` shows nothing inside a container), it's one of
the three above.

## Reference

- Decypharr docs: <https://decypharr.com/guides> (wizard, arr integration, mounts,
  troubleshooting)
