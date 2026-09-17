---
title: Seerr
nav_order: 8
---

# Seerr: media requests

Seerr is the user-facing request portal for the stack. Users browse available movies and
shows, submit requests, and Seerr sends them to Radarr or Sonarr. Those applications then
use the normal indexer and Decypharr workflow to acquire and import the media.

## 1. First login

Open `https://seerr.<DOMAIN>` from a tailnet device during setup. Seerr's first-login wizard
creates its administrator account and lets you sign in with Jellyfin. The Seerr panel is
available on both the public HTTPS and tailnet entrypoints; only publish it after the initial
setup and authentication settings are complete ([Ingress](ingress)).

Seerr stores its configuration under `$CONFIG_DIR/seerr/config`, so recreating the container
does not remove its users or integrations.

## 2. Connect Jellyfin

Seerr uses Jellyfin for user authentication and library availability:

1. In Jellyfin, open **Dashboard → API Keys** and generate an API key.
2. In Seerr, open **Settings → Jellyfin**.
3. Use `http://jellyfin:8096` as the server URL and paste the generated API key.
4. Test and save the connection.

Use the internal service URL, not `https://jellyfin.<DOMAIN>` or `localhost`. All containers
share the `internal` Docker network ([The \*arrs](arrs#docker-networking)).

## 3. Connect Radarr and Sonarr

In Seerr, configure both media managers under **Settings**:

| Application | Internal URL             | API key location                 |
| ----------- | ------------------------ | -------------------------------- |
| Radarr      | `http://radarr:7878`     | Settings → General → API Key     |
| Sonarr      | `http://sonarr:8989`     | Settings → General → API Key     |

For each application:

1. Enable the connection and enter the internal URL and API key.
2. Select the shipped **Direct Play** quality profile.
3. Select the corresponding root folder: `/mnt/movies` for Radarr or `/mnt/shows` for Sonarr.
4. Test and save the connection.

The same wiring is documented with the rest of the service integrations in [The \*arrs](arrs#seerr--jellyfin--radarr--sonarr-requests).

## 4. Request flow

After the integrations are connected, users can search Seerr and request movies or shows.
Seerr pushes approved requests to Radarr or Sonarr, which handle indexers, downloads, and
imports. Once the item is available in the configured library, Jellyfin scans it and Seerr
updates the request status.

Keep Seerr, Jellyfin, Radarr, and Sonarr on the same internal network and use their service
names for app-to-app connections. Public hostnames are for browser access only.
