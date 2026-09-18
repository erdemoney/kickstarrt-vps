---
title: Indexers
nav_order: 10
---

# Indexers: Prowlarr, custom Cardigann, and AltHub

Prowlarr is the single place indexers are configured; everything syncs to Sonarr/Radarr via
"Apps" (wired in [The \*arrs](arrs)). Any time after the stack is up
([Quickstart §9](quickstart#9-set-up-the-apps)) — but you need at least one before grabs
work.

## Recommended indexers

| Indexer                      | Type               | Cost               | Where it fits                           |
| ---------------------------- | ------------------ | ------------------ | --------------------------------------- |
| Torrentio (custom Cardigann) | torrent aggregator | needs a debrid key | debrid-cached streams through Decypharr |
| TorBox (custom Cardigann)    | torrent search API | needs a TorBox key | TorBox's cached torrents directly       |
| AltHub                       | Usenet             | $20 lifetime       | Usenet streaming through TorBox         |

Detailed recommendations live in [Services](services).

## Custom indexers (Torrentio, TorBox, comet, …)

Prowlarr can run **custom Cardigann indexers**: YAML definitions that talk to a torrent
aggregator / search API (Torrentio, TorBox, comet, zilean, knightcrawler, ...), so results
flow through the normal Prowlarr → Sonarr/Radarr sync and grabs go to Decypharr for debrid
streaming.

1. Install **all** bundled definitions with one command (run on the server; it downloads the
   Prowlarr-Indexers repo archive, copies its `Custom/` dir into prowlarr's config dir, and
   restarts prowlarr):

   ```bash
   just add-indexers
   ```

   (The manual step it automates: put every `*.yml` from
   `https://github.com/dreulavelle/Prowlarr-Indexers/tree/main/Custom` into
   `$CONFIG_DIR/prowlarr/Definitions/Custom` and recreate prowlarr.) Definitions are **inert
   until you add them in Prowlarr**, so installing the whole set saves a pick-a-name step.

   Currently shipped (all are `Custom/<name>.yml` from that repo):

   | Name          | What it is                                      | Needs                        |
   | ------------- | ----------------------------------------------- | ---------------------------- |
   | torrentio     | Torrentio aggregator (ezTV, 1337x, TPB, …)      | debrid provider key          |
   | torbox        | TorBox search API                               | TorBox API key               |
   | comet         | Comet search API                                | service URL + key            |
   | zilean        | DMM/zilean search                               | service URL (self-host or paid) |
   | aiostreams    | AioStreams search                               | service URL + key            |
   | aiostreams-api| AioStreams API search                           | API key                      |
   | annatar       | Annatar search API                              | service URL + key            |
   | debridio      | Debrid.io search                                | API key                      |
   | elfhosted-public | ElfHosted public search                      | service URL                  |
   | elfhosted-internal | ElfHosted internal search                   | service URL                  |
   | elfhosted-torrentio | ElfHosted Torrentio-compatible search     | service URL                  |
   | knightcrawler | KnightCrawler search                            | service URL + key            |
   | orionoid      | Orionoid search                                 | Orionoid API key (paid)      |
   | stremthru     | StremThru aggregator                            | service URL                  |
   | torrentclaw   | TorrentClaw search                              | service URL + key            |

   A missing name is not a bug — the repo just added or renamed it; re-run
   `just add-indexers` to pick up any changes.

2. Prowlarr → **Indexers** → `+` → search the name (e.g. **Torrentio**, **TorBox Torrents**)
   → add it.
   - Fill in whatever the definition asks for (see the "Needs" column above) — e.g. Torrentio
     wants your **Real-Debrid (or supported-debrid) API key**; TorBox wants its **API key**.
   - Torrentio example: `default_opts` holds the provider list plus `qualityfilter=scr,cam`;
     tweak the providers or sort if you want.
   - Save, enable, and confirm a green test; enable for movies/TV in the Sync Profile.
3. It syncs to Sonarr/Radarr like any indexer. For precise hits in Prowlarr search use
   `{imdbid:tt123456}` / `{imdbid:tt1234567}{season:00}{episode:00}`.

## Adding a regular Usenet indexer (e.g. AltHub)

1. Buy / register (see [Services](services)), then take the **API key + Newznab URL** from the
   indexer's profile page.
2. Prowlarr → Indexers → **+** → **Newznab**: paste the URL and API key, enable, test, save.
3. It syncs to Sonarr/Radarr automatically via the Apps configured earlier. With TorBox Pro and
   Decypharr, the resulting Usenet media is streamed through the debrid mount.
