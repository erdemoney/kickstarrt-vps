---
title: The *arrs
nav_order: 6
---

# The \*arrs: networking and app wiring

First-run setup happens over the tailnet while nothing is public
([Quickstart §8](quickstart#8-set-up-the-apps)) — open `https://radarr.<DOMAIN>` and friends
from any tailnet device. This page is the wiring walkthrough: what to paste where, in a
workable order. Run `just wiring` on the box first — it prints each URL + API key (read
from `$CONFIG_DIR` on disk), then walks through one service at a time: Enter advances to
the next step, `q` quits (piping it prints everything at once).

## Docker networking

One shared, `external: true` network — `internal` — carries all app-to-app traffic, Traefik
included. It's created by `just up` (`just networks` standalone); nothing inside Docker binds
an IP you need to care about — the names are what matter. Every service sets a
`container_name` matching its name, so containers are reachable at `http://<service>:<port>`
and a newly added container is reachable from every existing app.

## Internal DNS names and API keys

All services share the `internal` network, so every container reaches the others by
**service name**. Always use these internal URLs when one app asks for another — never
`localhost`, never the public subdomain (public URLs hairpin out to the internet and back,
break CORS, and add latency; they are for browsers only).

| Service   | Internal URL            | Port | API key lives at                                |
| --------- | ----------------------- | ---- | ----------------------------------------------- |
| jellyfin  | `http://jellyfin:8096`  | 8096 | Jellyfin → Dashboard → API Keys (generate one)  |
| seerr     | `http://seerr:5055`     | 5055 | (outbound only)                                 |
| radarr    | `http://radarr:7878`    | 7878 | Settings → General → API Key                    |
| sonarr    | `http://sonarr:8989`    | 8989 | Settings → General → API Key                    |
| prowlarr  | `http://prowlarr:9696`  | 9696 | Settings → General → API Key                    |
| recyclarr | —                      | —    | automatic — nothing to paste (see below)        |
| bazarr    | `http://bazarr:6767`    | 6767 | (outbound only)                                 |
| decypharr | `http://decypharr:8282` | 8282 | Settings → API token (shown once after wizard)  |

Rule of thumb: when any UI asks for another app's **URL + API key**, use the
`http://<service>:<port>` from the table and the key from the target app. Sanity-check any
link from inside the network:
`docker exec <service> curl -fsS http://sonarr:8989/ping`.

## Download clients: Sonarr/Radarr ← Decypharr

In each arr: Settings → **Download Clients** → add. With both protocols configured in
Decypharr, add **two** clients pointing at it — Decypharr exposes both APIs
([Decypharr](decypharr#integration-with-sonarrradarr) covers its side of the wiring):

- **qBittorrent** — name `Decypharr (debrid)`
  - Host `decypharr`, port `8282`
  - Username: the **arr's own URL** — `http://sonarr:8989` (or radarr's); Decypharr identifies
    the caller by this.
  - Password: that **arr's own API key** (Settings → General) — *not* the Decypharr token.
  - Category `sonarr` / `radarr`; priority `0`.
- **SABnzbd** — name `Decypharr (usenet)`, only if you configured Usenet in Decypharr
  - Host `decypharr`, port `8282`, **URL base `/sabnzbd`**
  - Same username/password as above.
  - Category `sonarr` / `radarr`; priority `0`.

Give them different priorities to prefer one protocol over the other — the arr sends a
release to the highest-priority client that can handle it. Test each client.

## Root folders and the mount

Sonarr/Radarr root folders must point at paths inside their own containers. In this stack the
library lives on Decypharr's FUSE mount (`/mnt/decypharr`), already reachable from every
service that touches media files — `sonarr`, `radarr`, `bazarr` (subtitles land next to the
video) and `jellyfin` (playback) — via the shared bind `- /mnt/debrid:/mnt:rslave`. Nothing
to add by hand: point Sonarr's root folder at `/mnt/decypharr/shows` and Radarr's at
`/mnt/decypharr/movies`, and in
Jellyfin add the libraries the same way ([Jellyfin setup](jellyfin) covers libraries plus the
transcode policy). Also set Jellyfin → Playback → **Transcode path**
to `/transcodes` (a tmpfs — transcode scratch never hits disk; this edition transcodes in
software, so keep the library direct-play friendly).

If those paths look empty inside a container, check mount propagation
([Decypharr](decypharr#visibility-of-the-mount)).

## Imports are symlinks, not hardlinks

There's no local download to hardlink here: Decypharr hands the \*arrs a **symlink** into its
FUSE mount, and importing renames that link into the root folder — the payload never lands on
disk, it streams from the debrid provider at playback (FUSE debrid mounts can't hardlink
anyway: `link()` isn't implemented). Two constraints follow:

- **Keep Decypharr's download folder and the \*arr root folders on the same mount** (both
  under `/mnt/decypharr`). Same filesystem means the import is a rename of a tiny symlink —
  instant. If they straddle filesystems the \*arrs fall back to copying, and copying a
  symlink *dereferences* it: the entire file gets pulled from debrid onto local disk.
- **Every consumer must resolve the symlink target at the same path.** What's stored in the
  library is an absolute path into the mount, so `sonarr`, `radarr`, `bazarr`, and `jellyfin`
  all bind `/mnt/decypharr` at the identical path. Change it in one place and that app sees a
  library full of dangling links.

## Prowlarr → Sonarr/Radarr (indexer sync)

1. Prowlarr → Settings → **Apps** → **Add Application** → **Sonarr** — URL
   `http://sonarr:8989`, API key from Sonarr → Settings → General. Leave the sync profile
   defaults; check "Enable" and the correct categories.
2. Same for **Radarr** → `http://radarr:7878` + its API key. Test both.

Every indexer added in Prowlarr (including Torrentio, [Indexers](indexers)) is then pushed to
both apps automatically (tagged `(Prowlarr)`).

## Seerr → Jellyfin + Radarr + Sonarr (requests)

1. Seerr → Settings → **Jellyfin**: server name, URL `http://jellyfin:8096`, and an **API key
   generated on the Jellyfin server** (Dashboard → API Keys — the admin account is created on
   Jellyfin's first login).
2. Seerr → **Radarr** and **Sonarr**: enable, add `http://radarr:7878` / `http://sonarr:8989`
   + API keys, pick the shipped **Direct Play** quality profile and the root folder for each.
3. Users can now request via Seerr, which pushes to Radarr/Sonarr.

## Bazarr → Sonarr/Radarr (subtitles)

Bazarr only fetches subtitles for titles added **after** a language profile is assigned —
the easy-to-forget step.

1. Settings → **Sonarr** → enable, URL `http://sonarr:8989`, API key. Same for
   **Radarr** → `http://radarr:7878`.
2. Create a language profile (Languages → manage), then assign it in the Sonarr/Radarr
   library views via **Mass Edit**.
3. **Subtitle providers** (the fiddly part):
   - **OpenSubtitles.com** — primary; the old `.org` API is shut down. Create an account,
     generate an **API key** on your profile page, enter username + API key. Free tier is
     rate-limited (~20 downloads/day); VIP removes the cap.
   - **subdl.com** — free fallback; grab an API key from your account panel (~2,000
     searches/day).
   - **Whisper (optional)** — AI-generated fallback when nothing clears a minimum score;
     needs a separate whisper ASR service.
4. Rank providers by preference and raise each language's **minimum score** if subs arrive
   out of sync or machine-translated. Subtitle folder: **Alongside media file**.

## Quality profiles (Recyclarr — automatic)

Quality profiles and custom formats are **not wired by hand** in this stack. [Recyclarr](https://recyclarr.dev)
runs as a container and syncs the shipped **"Direct Play"** profile — TRaSH Guide definitions
tuned for this CPU-only edition — into Radarr and Sonarr automatically:

- **When**: right after first boot (it waits for the arrs to be up, then syncs once), and
  daily after that. Nothing to paste anywhere; watch it with `docker logs recyclarr`.
- **What**: release-group tiers, repack preferences and TRaSH file sizes from the guide, plus
  `-10000` (never grab) scores for anything that would force a video transcode or break
  playback — AV1/VP9/VC-1/MPEG2 codecs, Dolby Vision without an HDR10 fallback, Blu-ray disk
  images, and low-quality/obfuscated groups. Audio is left unpenalized (audio transcodes are
  cheap on the server). The ladder is WEB-DL → Bluray encode → Remux at 1080p and 2160p.
- **Where**: `data/recyclarr/configs/radarr.yml` and `sonarr.yml`, tracked in the repo — edit
  to tune (e.g. score AV1 at `0` if every client decodes it, or drop the 2160p qualities to
  cap at 1080p), then apply immediately:

  ```bash
  docker compose -f stacks/media-server/compose.yaml exec recyclarr recyclarr sync
  ```

The profile is reset to match the config on every sync, so manual edits in the arr UI don't
stick — the YAML is the source of truth. Pick **Direct Play** wherever an app asks for a
quality profile (Seerr's Radarr/Sonarr settings, Radarr/Sonarr defaults). The arrs' API keys
are read by the recyclarr container at start (never committed); if you regenerate an arr's
API key, restart it: `just up-svc media-server recyclarr`.

> Migrating from the old Profilarr setup? Nothing to migrate — its container and panel are
> gone; the leftover `$CONFIG_DIR/profilarr` dir is inert and safe to delete.

## Managing from your phone

**Ruddarr** ([ruddarr.com](https://ruddarr.com)) is a free, open-source **iOS companion app**
for Radarr and Sonarr — browse the library and calendar, kick off searches, act on the queue
or history. It's a *client*, not a service: nothing runs on the server. Point it at each
instance's **Application URL**: with Tailscale on the phone, `https://radarr.<DOMAIN>` /
`https://sonarr.<DOMAIN>` resolve to the box's tailnet address ([Tailnet DNS](tailnet)) — no
public A records, no extra auth (the tailnet is the gate). The app handles HTTPS and
reverse-proxy headers; the panels' own logins and CrowdSec still apply, so they stay
admin-only — the app is just another client.
