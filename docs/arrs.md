---
title: The *arrs
nav_order: 6
---

# The \*arrs: networking and app wiring

First-run setup happens over the tailnet while nothing is public
([Quickstart §8](quickstart#8-set-up-the-apps)) — open `https://radarr.<DOMAIN>` and friends
from any tailnet device. This page is the wiring walkthrough: what to paste where, in a
workable order. Run `just wiring` on the box first — it probes every pairing's reachability
and prints each URL + API key (read from `$CONFIG_DIR` on disk) for every section below,
including the full Decypharr client spec.

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
| profilarr | `http://profilarr:6868` | 6868 | profilarr → Settings → Radarr/Sonarr connection |
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
to add by hand: point each app's root folder at a subpath of `/mnt/decypharr`, and in
Jellyfin add the libraries the same way. Also set Jellyfin → Playback → **Transcode path**
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
   + API keys, pick the quality profile and root folder for each.
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

## Profilarr → Sonarr/Radarr (quality profiles)

1. In profilarr, add the Sonarr/Radarr instances (Settings → connections): URL + each API
   key.
2. Import TRaSH guides / create profiles; profilarr applies them to the apps.

## Managing from your phone

**Ruddarr** ([ruddarr.com](https://ruddarr.com)) is a free, open-source **iOS companion app**
for Radarr and Sonarr — browse the library and calendar, kick off searches, act on the queue
or history. It's a *client*, not a service: nothing runs on the server. Point it at each
instance's **Application URL**: with Tailscale on the phone, `https://radarr.<DOMAIN>` /
`https://sonarr.<DOMAIN>` resolve to the box's tailnet address ([Tailnet DNS](tailnet)) — no
public A records, no extra auth (the tailnet is the gate). The app handles HTTPS and
reverse-proxy headers; the panels' own logins and CrowdSec still apply, so they stay
admin-only — the app is just another client.
