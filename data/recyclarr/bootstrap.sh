#!/usr/bin/env bash
# Recyclarr bootstrap (entrypoint override for the media-server stack).
#
# Why this exists: the *arrs generate their API keys on FIRST boot, seconds after
# their containers start - after `just up` begins. Recyclarr needs those keys, so
# this script bridges the gap: wait for the keys, render /config/secrets.yml, run
# one sync immediately (so the shipped "Direct Play" and "Direct Play (Anime)"
# profiles land during setup, not at the first cron tick), then hand off to the stock
# image entrypoint, which
# runs `recyclarr sync` on CRON_SCHEDULE (default @daily) forever.
#
# The arrs' config dirs are mounted read-only at /radarr and /sonarr (compose).
# secrets.yml is regenerated on every container start, so rotating an arr's API
# key is fixed by restarting this container (`just up-svc media-server recyclarr`).

set -euo pipefail

RADARR_XML=/radarr/config.xml
SONARR_XML=/sonarr/config.xml

# Print the <ApiKey> value from an arr's config.xml; empty output = not ready.
# Handles the key being on the same line as the tag or on the following line.
extract_key() {
    awk -F'[<>]' '/<ApiKey>/ {
        s = $0; sub(/^.*<ApiKey>/, "", s); sub(/<\/ApiKey>.*$/, "", s)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s) { print s; exit }
        if (getline > 0) { sub(/^[ \t]+|[ \t]+$/, "", $0); print; exit }
    }' "$1" 2>/dev/null || true
}

# Wait up to ~5 min for an arr to write its API key (the compose depends_on
# healthchecks mean this is normally instant; the loop is belt-and-braces for
# standalone restarts).
wait_for_key() {
    local xml="$1" label="$2" key
    for _ in $(seq 1 60); do
        key=$(extract_key "$xml")
        if [ -n "$key" ]; then
            printf '%s' "$key"
            return 0
        fi
        echo "recyclarr: waiting for $label to write its API key ..."
        sleep 5
    done
    return 1
}

RADARR_KEY=$(wait_for_key "$RADARR_XML" radarr) || {
    echo "recyclarr: no API key from radarr after 5 min - giving up on the first sync." \
         "The cron schedule will retry; check that radarr is running."
    exec /entrypoint.sh
}
SONARR_KEY=$(wait_for_key "$SONARR_XML" sonarr) || {
    echo "recyclarr: no API key from sonarr after 5 min - giving up on the first sync." \
         "The cron schedule will retry; check that sonarr is running."
    exec /entrypoint.sh
}

umask 077
{
    echo "# rendered by bootstrap.sh at container start - do not edit"
    echo "radarr_api_key: $RADARR_KEY"
    echo "sonarr_api_key: $SONARR_KEY"
} > /config/secrets.yml
umask 022
echo "recyclarr: rendered /config/secrets.yml"

# First sync now (up to 3 attempts - the arrs may still be finishing boot).
for attempt in 1 2 3; do
    if recyclarr sync; then
        echo "recyclarr: initial sync complete"
        break
    fi
    if [ "$attempt" = 3 ]; then
        echo "recyclarr: initial sync failed - cron will retry ($CRON_SCHEDULE); see the errors above."
    else
        sleep 60
    fi
done

# Hand off to the stock entrypoint: cron mode, sync on $CRON_SCHEDULE.
exec /entrypoint.sh
