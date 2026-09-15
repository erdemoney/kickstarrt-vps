---
title: Jellyfin
nav_order: 7
---

# Jellyfin: playback setup

The admin account is created on Jellyfin's **first login** (the setup wizard). From there
the two things that need configuring are the libraries — they point at the Decypharr mount —
and the transcode policy, tuned for a CPU-only VPS.

## 1. Libraries on the Decypharr mount

No path mapping needed: the compose already binds Decypharr's FUSE mount into Jellyfin at
`/mnt/decypharr` (`- /mnt/debrid:/mnt:rslave`), the identical absolute path the \*arrs import
from, so the symlinks Decypharr hands over resolve at the same place everywhere
([Decypharr](decypharr#visibility-of-the-mount)).

Dashboard → **Libraries** → **Add Media Library**:

- **Content type** — Movies / Shows (or whatever your folder holds).
- **Folders** → **+** → add a subpath of `/mnt/decypharr`, e.g. `/mnt/decypharr/movies`.
- Save, then **Scan All Libraries**.

If a library shows empty here but populated on the host, it's the classic mount-propagation
mistake ([Decypharr → Visibility of the mount](decypharr#visibility-of-the-mount)).

Also set Dashboard → **Playback** → **Transcoding path** to `/transcodes` — a tmpfs, so
transcode scratch never touches disk. This stack transcodes in software (no GPU,
[FAQ](faq#why-does-jellyfin-transcode-in-software-no-gpu)) and Recyclarr ships a **Direct
Play** quality profile, so the goal is to keep playback direct and never let a client push
the server into a CPU-only video transcode.

## 2. Transcode policy: no video transcoding, remux + audio transcoding stay on

Jellyfin has **no global "disable video transcoding" switch** — it's set per user
([upstream#645](https://github.com/jellyfin/jellyfin/issues/645)). Open
**Dashboard → Users → edit the user → Access** → the *Media playback* block:

| Setting                                                | Value | Meaning                                                  |
| ------------------------------------------------------ | ----- | -------------------------------------------------------- |
| Allow media playback                                   | on    |                                                          |
| Allow **video playback that requires transcoding**     | **off** | never re-encode video (software transcode = CPU churn) |
| Allow **video playback that requires conversion without re-encoding** | **on** | remux / direct stream — container change, streams copied |
| Allow **audio playback that requires transcoding**     | **on** | audio transcode is cheap and often needed                |

Repeat for **each user** — a new user inherits the defaults (video transcoding on), so set
it when you add one.

What this buys you: anything that only needs a container remux or an audio transcode plays;
anything that *requires* video transcoding (codec the client can't play, or burned-in
subtitles) fails with an error instead of transcode-spiking the server — by design. Keep
clients direct-play friendly (bitrate caps live on the client, not the server) and the VPS
stays idle.

## 3. Seerr

Seerr talks to Jellyfin over the internal network: **Dashboard → API Keys** → generate, then
Seerr → Settings → **Jellyfin** → server `http://jellyfin:8096` + that key
([The \*arrs](arrs#seerr--jellyfin--radarr--sonarr-requests)). Jellyfin's own dashboard
credentials are only handled by Jellyfin's first-login wizard — nothing to store in `.env`.