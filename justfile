set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

stack_list := "traefik media-server"
restic_image := "restic/restic:0.19.1"

# Show available recipes
default:
    just --list

# Full first-time setup: create each .env, print the auto-generated values
# (CONFIG_DIR, TAILNET_IP, PUBLIC_BIND, CROWDSEC_BOUNCER_API_KEY) up front, then prompt for
# the rest, offering defaults from this recipe (Enter accepts / keeps current).
# Already-set values are skipped on re-run; `just init force` re-prompts them
# (Enter keeps the current value, typing replaces it). Shared vars (DOMAIN,
# CONFIG_DIR) are synced across stacks. Browser pages are only opened after
# confirmation, and only in a GUI session. Safe to re-run — nothing is
# overwritten without consent.
init FORCE="":
    #!/usr/bin/env bash
    set -euo pipefail

    # ---- prettier UI: pure ANSI + unicode, plain-text fallback when piped ----
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
        B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
        RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
        MAG=$'\033[35m'; CYN=$'\033[36m'
    else
        B=''; D=''; R=''; RED=''; GRN=''; YEL=''; MAG=''; CYN=''
    fi
    case "${LC_ALL:-$LANG}" in
        *[Uu][Tt][Ff]*) G='─'; H='─'; V='│'; TL='╭'; TR='╮'; BL='╰'; BR='╯'
                        S='▸'; OK='✓'; WARN='⚠'; DONE='✔'; ELLIP='…' ;;
        *)              G='-'; H='-'; V='|'; TL='+'; TR='+'; BL='+'; BR='+'
                        S='>'; OK='ok'; WARN='!'; DONE='done'; ELLIP='...' ;;
    esac
    RULE=$(printf -- "$G%.0s" {1..66})

    hr() { printf '%s\n' "${CYN}${RULE}${R}"; }
    hdr() { hr; printf '%s\n' "  ${B}${CYN}${S} $1${R}"; hr; }
    chip() { printf '  %s%s%s\n' "$B$MAG" "$1" "$R"; }
    ok() { printf '  %s%s%s %s\n' "$GRN" "$OK" "$R" "$1"; }
    warn() { printf '  %s%s%s %s\n' "$YEL" "$WARN" "$R" "$1"; }
    muted() { printf '  %s%s%s\n' "$D" "$1" "$R"; }
    ask() { printf '  %s%s%s: ' "$B" "$1" "$R"; }
    lbl() { printf '%s%s%s' "$B$MAG" "$1" "$R"; }
    cur() { printf '%s%s%s' "$CYN" "$1" "$R"; }
    dim() { printf '%s%s%s' "$D" "$1" "$R"; }
    panel() {   # panel <title> [<line>...]: bordered card emulating the Cloudflare GUI
        local title="$1"; shift
        local w="${#title}" line i
        for line in "$@"; do
            [ "${#line}" -gt "$w" ] && w="${#line}"
        done
        printf '  %s' "$TL"
        i=0; while [ "$i" -lt "$((w+2))" ]; do printf '%s' "$H"; i=$((i+1)); done
        printf '%s\n' "$TR"
        printf '  %s %s%s%s %s\n' "$V" "$B$MAG" "$(printf '%-*s' "$w" "$title")" "$R" "$V"
        printf '  %s %-*s %s\n' "$V" "$w" "" "$V"
        for line in "$@"; do
            case "$line" in
                *:)
                    printf '  %s %s%s%-*s%s %s\n' "$V" "$B" "" "$w" "$line" "$R" "$V"
                    ;;
                *)
                    printf '  %s %-*s %s\n' "$V" "$w" "$line" "$V"
                    ;;
            esac
        done
        printf '  %s' "$BL"
        i=0; while [ "$i" -lt "$((w+2))" ]; do printf '%s' "$H"; i=$((i+1)); done
        printf '%s\n' "$BR"
    }
    auto_row() {   # LABEL VALUE NOTE: one aligned row of the auto-generated summary
        printf '  %s %s %s\n' \
            "$(lbl "$(printf '%-*s' 23 "$1")")" \
            "$(cur "$2")" \
            "$(dim "$3")"
    }

    hdr "kickstArrt"
    muted "Every secret, one at a time  -  safe to re-run, nothing is"
    muted "overwritten without consent. Written to: stacks/*/.env"
    echo

    FORCE=0
    case "{{ FORCE }}" in
        ""|n|N|no|No|NO|0|false|False|FALSE) : ;;
        f|F|force|Force|FORCE|-f|--force|y|Y|yes|Yes|YES|1|true|True|TRUE) FORCE=1 ;;
        *)
            FORCE=1
            warn "unrecognized FORCE arg '{{ FORCE }}' (expected 'force') - continuing in force mode"
            ;;
    esac
    if [ "$FORCE" -eq 1 ]; then
        warn "force mode: already-set values are re-prompted (Enter keeps the current value)"
    fi

    TRAEFIK_ENV=stacks/traefik/.env
    MEDIA_ENV=stacks/media-server/.env
    ALL_ENVS=("$TRAEFIK_ENV" "$MEDIA_ENV")

    for s in {{ stack_list }}; do
        if [ -f "stacks/$s/.env" ]; then
            muted "stacks/$s/.env   already exists (skipping create)"
        else
            cp "stacks/$s/.env.example" "stacks/$s/.env"
            ok "stacks/$s/.env   created from example"
        fi
    done
    echo

    get_var() {   # prints the current value of KEY in FILE ('' if unset)
        sed -n "s|^$2=\(.*\)|\1|p" "$1" | tail -n1
    }

    set_var() {   # sets KEY to VALUE in FILE, preserving the rest of the file
        local esc                     # (temp file + mv: `sed -i` is not portable,
        esc=$(printf '%s' "$3" | sed -e 's/[&|\\]/\\&/g')   # BSD/macOS sed eats the
        sed "s|^$2=.*|$2=$esc|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"   # next arg)
    }

    vars_defined_in() {   # echoes each .env that defines the given VAR
        local var="$1" f
        for f in "${ALL_ENVS[@]}"; do
            if [ -f "$f" ] && grep -q "^$var=" "$f"; then
                printf '%s\n' "$f"
            fi
        done
    }

    set_all() {   # sets VAR to VALUE in every .env that defines it
        local var="$1" value="$2" f
        for f in $(vars_defined_in "$var"); do
            set_var "$f" "$var" "$value"
        done
    }

    skip_set() {   # FILE VAR [SHOW]: when the value is set and not forcing, print
        local cur show="${3:-1}"   # 'already set' and return 0 so callers skip the
        cur=$(get_var "$1" "$2") || true   # prompt; SHOW=0 hides the value (secrets)
        if [ -z "$cur" ] || [ "$FORCE" -eq 1 ]; then
            return 1
        fi
        if [ "$show" = 1 ]; then
            ok "$2 already set ($cur)"
        else
            ok "$2 already set"
        fi
        return 0
    }

    show_url() {   # these run headless; print the URL instead of opening a browser
        local url="$1"
        printf '  %s%s%s\n' "$B$CYN" "-> open in a browser: $url" "$R"
    }

    prompt_value() {   # FILE VAR [hint] [normalizer]: show current value, Enter keeps, type to
        local file="$1" var="$2" hint="${3:-}" norm="${4:-}" cur ans
        cur=$(get_var "$file" "$var") || true
        if [ -n "$cur" ]; then
            printf '  %s [%s, %s] > ' "$(lbl "$var")" "$(cur "$cur")" "$(dim "Enter to keep")"
        elif [ -n "$hint" ]; then
            printf '  %s [%s] > ' "$(lbl "$var")" "$(dim "$hint")"
        else
            printf '  %s > ' "$(lbl "$var")"
        fi
        read -r ans || ans=""
        if [ -n "$ans" ]; then
            if [ -n "$norm" ]; then
                ans=$("$norm" "$ans") || true
            fi
            if [ "$ans" != "$cur" ]; then
                set_all "$var" "$ans"
            fi
        fi
    }

    prompt_default() {   # FILE VAR DEFAULT: like prompt_value but an empty value offers
        local file="$1" var="$2" def="$3" cur ans   # DEFAULT on Enter instead of staying empty
        cur=$(get_var "$file" "$var") || true
        if [ -n "$cur" ]; then
            printf '  %s [%s, %s] > ' "$(lbl "$var")" "$(cur "$cur")" "$(dim "Enter to keep")"
            read -r ans || ans=""
        else
            printf '  %s [%s, %s] > ' "$(lbl "$var")" "$(cur "$def")" "$(dim "Enter to use")"
            read -r ans || ans=""
            [ -z "$ans" ] && ans="$def"
        fi
        if [ -n "$ans" ] && [ "$ans" != "$cur" ]; then
            set_all "$var" "$ans"
        fi
        return 0
    }

    abs_path() {   # print $1 as an absolute path, resolving relative against $PWD
        case "$1" in
            /*) p="$1" ;;
            *) p="$PWD/$1" ;;
        esac
        if command -v realpath >/dev/null 2>&1; then
            realpath -m "$p"
        else
            printf '%s\n' "$p"
        fi
    }

    prompt_id() {   # FILE VAR DEFAULT: propose DEFAULT (this user's id) while the
        local file="$1" var="$2" def="$3" cur ans   # value is unset; once set, offer to keep it
        cur=$(get_var "$file" "$var") || true
        if [ -z "$cur" ]; then
            printf '  %s [%s, %s] > ' "$(lbl "$var")" "$(cur "$def")" "$(dim "Enter to use")"
            read -r ans || ans=""
            [ -z "$ans" ] && ans="$def"
        else
            printf '  %s [%s, %s] > ' "$(lbl "$var")" "$(cur "$cur")" "$(dim "Enter to keep")"
            read -r ans || ans=""
        fi
        if [ -n "$ans" ] && [ "$ans" != "$cur" ]; then
            set_all "$var" "$ans"
        fi
        return 0
    }

    # ---- auto-generated values: derived or generated up front, shown together ----

    # CONFIG_DIR is derived, not configured: it is always the repo's own data/ dir.
    # The tracked traefik config, the app state and the restic backup scope all live
    # there, so pointing it elsewhere would silently split them apart.
    CONFIG_DIR_VALUE="$(abs_path "{{ justfile_directory() }}/data")"
    set_all CONFIG_DIR "$CONFIG_DIR_VALUE"

    # TAILNET_IP: this VPS's Tailscale address. The CoreDNS resolver in this stack
    # answers *.DOMAIN with it, so admin panels resolve by name on the tailnet
    # (see docs/tailnet.md). Detected via the tailscale CLI; prompted only when
    # detection is impossible. Force mode re-detects and refreshes a set value.
    ts_ip=$(get_var "$TRAEFIK_ENV" TAILNET_IP) || true
    ts_note=""
    if [ -n "$ts_ip" ] && [ "$FORCE" -eq 0 ]; then
        ts_note="already set"
    else
        ts_def=""
        if command -v tailscale >/dev/null 2>&1; then
            ts_def=$(tailscale ip -4 2>/dev/null | head -n1 || true)
        fi
        if [ -z "$ts_def" ] && command -v sudo >/dev/null 2>&1; then
            ts_def=$(sudo -n tailscale ip -4 2>/dev/null | head -n1 || true)
        fi
        if [ -n "$ts_def" ]; then
            if [ "$ts_def" != "$ts_ip" ]; then
                set_var "$TRAEFIK_ENV" TAILNET_IP "$ts_def"
            fi
            ts_ip="$ts_def"
            ts_note="detected via 'tailscale ip -4'"
        fi
    fi

    # PUBLIC_BIND: the IP Traefik binds its PUBLIC entrypoints to - the address
    # the provider maps the internet to (the default-route source IP: on
    # direct-IP hosts the public IPv4 itself, on Oracle the VNIC private IP the
    # VCN 1:1-NATs to :443). Detected via `ip route`; won't pick a tailnet
    # (100.64.0.0/10) or loopback address. Detectable almost always; override in
    # stacks/traefik/.env if the box has several public paths.
    pb=$(get_var "$TRAEFIK_ENV" PUBLIC_BIND) || true
    pb_note=""
    if [ -n "$pb" ] && [ "$FORCE" -eq 0 ]; then
        pb_note="already set"
    else
        pb_def=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | sed -n 's/.*src \([0-9.]*\).*/\1/p' \
            | grep -Ev '^(127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
            | head -n1 || true)
        [ -n "$pb_def" ] || pb_def=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '{ split($4,a,"/"); if (a[1] !~ /^(127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)/) { print a[1]; exit } }' || true)
        if [ -n "$pb_def" ]; then
            if [ "$pb_def" != "$pb" ]; then
                set_var "$TRAEFIK_ENV" PUBLIC_BIND "$pb_def"
            fi
            pb="$pb_def"
            pb_note="detected via 'ip route'"
        fi
    fi

    # CROWDSEC_BOUNCER_API_KEY: shared between the crowdsec container and Traefik's
    # bouncer plugin - a random 32-byte key, generated once, never printed in full.
    cs_key=$(get_var "$TRAEFIK_ENV" CROWDSEC_BOUNCER_API_KEY) || true
    cs_note="already set"
    if [ -z "$cs_key" ]; then
        cs_key=$(openssl rand -hex 32)
        set_var "$TRAEFIK_ENV" CROWDSEC_BOUNCER_API_KEY "$cs_key"
        cs_note="random 32-byte key"
    fi

    hdr "Auto-generated values"
    muted "Derived or generated for you - nothing to type. Full values live in stacks/*/.env."
    echo
    auto_row CONFIG_DIR "$CONFIG_DIR_VALUE" ""
    if [ -n "$ts_note" ]; then
        auto_row TAILNET_IP "$ts_ip" "($ts_note)"
    else
        auto_row TAILNET_IP "$ts_ip" "(not detectable - prompted below)"
    fi
    if [ -n "$pb_note" ]; then
        auto_row PUBLIC_BIND "$pb" "($pb_note)"
    else
        auto_row PUBLIC_BIND "$pb" "(not detectable - prompted below)"
    fi
    auto_row CROWDSEC_BOUNCER_API_KEY "${cs_key:0:8}${ELLIP}" "($cs_note)"
    if [ -z "$ts_note" ]; then
        prompt_value "$TRAEFIK_ENV" TAILNET_IP \
            "e.g. 100.64.0.3 (tailscale CLI unavailable - 'tailscale up' first, then re-run 'just init')"
    fi
    if [ -z "$pb_note" ]; then
        prompt_value "$TRAEFIK_ENV" PUBLIC_BIND \
            "the provider-mapped public IP (ip route detection failed - 'ip' missing?)"
    fi
    echo

    hdr "Domain and paths (shared across stacks)"
    if ! skip_set "$TRAEFIK_ENV" DOMAIN; then
        prompt_value "$TRAEFIK_ENV" DOMAIN "your domain, e.g. example.com"
    fi
    echo

    hdr "traefik"
    if ! skip_set "$TRAEFIK_ENV" SUB_DOMAIN_TRAEFIK; then
        prompt_default "$TRAEFIK_ENV" SUB_DOMAIN_TRAEFIK traefik
    fi
    # Let's Encrypt only needs a syntactically valid contact on a real domain - it stopped
    # sending mail in June 2025 and no longer stores the address, so it does not have to be
    # deliverable. It cannot be a dummy either: Boulder rejects @example.com outright.
    # Defaulting to admin@$DOMAIN is always valid (they own the zone) and needs no thought.
    if ! skip_set "$TRAEFIK_ENV" ACME_EMAIL; then
        muted "ACME_EMAIL is the Let's Encrypt contact address. It does not have to receive mail"
        muted "(they stopped sending it in 2025), but it must be a real domain - @example.com is"
        muted "rejected by their API - so it defaults to admin@ your own domain."
        prompt_default "$TRAEFIK_ENV" ACME_EMAIL "admin@$(get_var "$TRAEFIK_ENV" DOMAIN)"
    fi
    echo

    chip "TRAEFIK_DASHBOARD_CREDENTIALS"
    if ! skip_set "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_CREDENTIALS 0; then
        cur_cred=$(get_var "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_CREDENTIALS) || true
        cur_user=""
        if [ -n "$cur_cred" ]; then
            cur_user=${cur_cred%\'}; cur_user=${cur_user#\'}; cur_user=${cur_user%%:*}
        fi
        if [ -n "$cur_user" ]; then
            muted "Currently set for user '$cur_user' - a blank password keeps the existing"
            muted "hash, a new one replaces it."
        else
            muted "htpasswd-style user:hash for the Traefik dashboard (blank password ="
            muted "generate nothing, username defaults to admin)."
        fi
        ask "dashboard username (default ${cur_user:-admin})"
        read -r dash_user || dash_user=""
        ask "dashboard password (hidden)"
        read -rs dash_pass || dash_pass=""
        printf '\n'
        if [ -z "$dash_pass" ]; then
            if [ -n "$cur_user" ]; then
                muted "blank password - credentials left unchanged"
            else
                muted "blank password - nothing generated (re-run 'just init' to set them)"
            fi
        else
            [ -n "$dash_user" ] || dash_user="${cur_user:-admin}"
            hash=$(openssl passwd -apr1 "$dash_pass" 2>/dev/null) || hash=""
            case "$hash" in
                \$apr1\$*) : ;;
                *) hash=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$dash_user" "$dash_pass" | cut -d: -f2) ;;
            esac
            set_var "$TRAEFIK_ENV" TRAEFIK_DASHBOARD_CREDENTIALS "'$dash_user:$hash'"
            ok "set (single-quoted so compose doesn't eat the hash)"
        fi
    fi
    echo

    chip "CLOUDFLARE_DNS_TOKEN"
    if ! skip_set "$TRAEFIK_ENV" CLOUDFLARE_DNS_TOKEN 0; then
        dns_domain="$(get_var "$TRAEFIK_ENV" DOMAIN)"
        [ -n "$dns_domain" ] || dns_domain="<DOMAIN>"
        cur_dns=$(get_var "$TRAEFIK_ENV" CLOUDFLARE_DNS_TOKEN) || true
        muted "Create it: dash.cloudflare.com -> My Profile -> API Tokens -> Create Custom Token"
        panel "Create Custom Token" \
            "Permissions:" \
            "  Zone -> Zone -> Read" \
            "  Zone -> DNS -> Edit" \
            "Zone Resources:" \
            "  Include -> Specific zone -> <DOMAIN>" \
            "Client IP Address Filtering:" \
            "  skip - your ISP can change your public IP and break renewals" \
            "  (see docs/quickstart.md)" \
            "TTL: optional"
        muted "Paste it below (hidden). Leave empty to skip; set it later."
        show_url "https://dash.cloudflare.com/profile/api-tokens"
        ask "CLOUDFLARE_DNS_TOKEN (hidden)"
        read -rs token || token=""
        printf '\n'
        if [ -n "$token" ]; then
            set_var "$TRAEFIK_ENV" CLOUDFLARE_DNS_TOKEN "$token"
            ok "set: $dns_domain - Zone:Read, DNS:Edit"
            muted "verifying with Cloudflare..."
            if command -v curl >/dev/null 2>&1 && \
               curl -fsS --connect-timeout 10 --max-time 20 \
                   "https://api.cloudflare.com/client/v4/user/tokens/verify" \
                   -H "Authorization: Bearer $token" | grep -q '"status":"active"'; then
                ok "verified: token is active"
            else
                warn "could not verify the token (offline, wrong paste, or revoked)."
                muted "This only checks validity - permissions surface at first cert issuance."
            fi
        else
            if [ -n "$cur_dns" ]; then
                muted "skipped - token left unchanged"
            else
                muted "skipped - set it later: re-run 'just init' or edit .env directly"
            fi
        fi
    fi
    echo

    hdr "media-server"
    sid=$(id -u); sgid=$(id -g)
    if [ "$sid" -eq 0 ]; then
        sid=1000; sgid=1000
        muted "(running as root - proposing 1000:1000 so containers don't run as root;"
        muted "re-run as your deploy user to use its uid/gid)"
    fi
    if ! skip_set "$MEDIA_ENV" ENV_PUID; then
        prompt_id "$MEDIA_ENV" ENV_PUID "$sid"
    fi
    if ! skip_set "$MEDIA_ENV" ENV_PGID; then
        prompt_id "$MEDIA_ENV" ENV_PGID "$sgid"
    fi
    echo
    for sub in JELLYFIN SEERR RADARR SONARR PROWLARR BAZARR DECYPHARR; do
        if skip_set "$MEDIA_ENV" "SUB_DOMAIN_$sub"; then continue; fi
        prompt_default "$MEDIA_ENV" "SUB_DOMAIN_$sub" "${sub,,}"
    done
    echo

    hdr "restic backups (optional)"
    BACKUP_ENV=.env.restic
    if [ ! -f "$BACKUP_ENV" ]; then
        cp .env.restic.example .env.restic
        ok "created $BACKUP_ENV from .env.restic.example"
    fi
    if [ "$FORCE" -eq 0 ] && [ -n "$(get_var "$BACKUP_ENV" RESTIC_REPOSITORY)" ] && [ -n "$(get_var "$BACKUP_ENV" RESTIC_PASSWORD)" ]; then
        ok "already configured ($(get_var "$BACKUP_ENV" RESTIC_REPOSITORY))"
    else
        ask "Configure R2 restic backups now? [y/N]"
        read -r yes_backup || yes_backup=""
        case "$yes_backup" in
        y|Y|yes|Yes|YES)
            muted "Back up this repo (all .env files + data/) to an encrypted restic repository"
            muted "in Cloudflare R2 (this stack lives on Cloudflare); restic runs in a container."
            panel "Create API token" \
                "Token name:" \
                "  anything (e.g. kickstarrt-restic)" \
                "Permissions:" \
                "  Object -> Read & Write" \
                "Specify bucket(s):" \
                "  Apply to specific buckets only -> <BUCKET>" \
                "TTL: optional" \
                "Client IP Address Filtering:" \
                "  skip - your ISP can change your public IP and break backups" \
                "  (see docs/maintenance.md)"
            muted "Different backend? Edit RESTIC_REPOSITORY + creds in .env.restic -"
            muted "that's the only supported deviation. The values are prompted below."
            show_url "https://dash.cloudflare.com/?to=/:account/r2/overview"
            show_url "https://dash.cloudflare.com/?to=/:account/r2/api-tokens"
            echo
            cur_act=$(get_var "$BACKUP_ENV" R2_ACCOUNT_ID) || true
            if [ -n "$cur_act" ]; then
                printf '  %s [%s, %s] > ' "$(lbl "R2 Account ID")" "$(cur "$cur_act")" "$(dim "Enter to keep")"
            else
                printf '  %s [%s] > ' "$(lbl "R2 Account ID")" "$(dim "R2 page, scroll down: Usage -> Account Details")"
            fi
            read -r acct || acct=""
            [ -n "$acct" ] && set_var "$BACKUP_ENV" R2_ACCOUNT_ID "$acct"

            cur_bkt=$(get_var "$BACKUP_ENV" R2_BUCKET) || true
            if [ -n "$cur_bkt" ]; then
                printf '  %s [%s, %s] > ' "$(lbl "R2 bucket name")" "$(cur "$cur_bkt")" "$(dim "Enter to keep")"
            else
                printf '  %s [%s] > ' "$(lbl "R2 bucket name")" "$(dim "R2 dashboard -> Create bucket")"
            fi
            read -r bkt || bkt=""
            [ -n "$bkt" ] && set_var "$BACKUP_ENV" R2_BUCKET "$bkt"

            cur_key=$(get_var "$BACKUP_ENV" AWS_ACCESS_KEY_ID) || true
            if [ -n "$cur_key" ]; then
                printf '  %s [%s, %s] > ' "$(lbl "R2 Access Key ID")" "$(cur "$cur_key")" "$(dim "Enter to keep")"
            else
                printf '  %s [%s] > ' "$(lbl "R2 Access Key ID")" "$(dim "Manage R2 API Tokens")"
            fi
            read -r akey || akey=""
            [ -n "$akey" ] && set_var "$BACKUP_ENV" AWS_ACCESS_KEY_ID "$akey"

            if [ -n "$(get_var "$BACKUP_ENV" AWS_SECRET_ACCESS_KEY)" ]; then
                printf '  %s [%s, %s] > ' "$(lbl "R2 Secret Access Key")" "$(dim "hidden")" "$(dim "Enter to keep")"
            else
                printf '  %s [%s] > ' "$(lbl "R2 Secret Access Key")" "$(dim "hidden, same page")"
            fi
            read -rs skey || skey=""
            printf '\n'
            [ -n "$skey" ] && set_var "$BACKUP_ENV" AWS_SECRET_ACCESS_KEY "$skey"

            acct=$(get_var "$BACKUP_ENV" R2_ACCOUNT_ID) || true
            bkt=$(get_var "$BACKUP_ENV" R2_BUCKET) || true
            if [ -n "$acct" ] && [ -n "$bkt" ]; then
                set_var "$BACKUP_ENV" AWS_DEFAULT_REGION auto
                set_var "$BACKUP_ENV" RESTIC_REPOSITORY "s3:https://$acct.r2.cloudflarestorage.com/$bkt"
            fi

            ask "RESTIC_PASSWORD (hidden, blank to skip)"
            read -rs rpw || rpw=""
            printf '\n'
            [ -n "$rpw" ] && set_var "$BACKUP_ENV" RESTIC_PASSWORD "$rpw"
            if [ -n "$(get_var "$BACKUP_ENV" RESTIC_REPOSITORY)" ] && [ -n "$(get_var "$BACKUP_ENV" RESTIC_PASSWORD)" ]; then
                ok "restic configured (R2) - next: 'just backup-init', then 'just backup'."
            else
                warn "left incomplete - fill RESTIC_REPOSITORY + RESTIC_PASSWORD in .env.restic later."
            fi
            ;;
        *)
            if [ -n "$(get_var "$BACKUP_ENV" RESTIC_REPOSITORY)" ] && [ -n "$(get_var "$BACKUP_ENV" RESTIC_PASSWORD)" ]; then
                muted "skipped - .env.restic left as configured"
            else
                muted "skipped - fill .env.restic later and run 'just backup-init'."
            fi
            ;;
        esac
    fi
    echo

    hr
    printf '%s\n' "  ${B}${GRN}${DONE}${R} ${B}init complete${R}"
    muted "Review stacks/*/.env, then run 'just up'."
    muted "Re-runs skip what's already set; 'just init force' re-prompts those values."
    muted "Keep the box locked down (SSH tailnet-only) - go public with 'just go-public'"
    muted "(Cloudflare A records + open :443/:80; docs/ingress.md, Quickstart §10)."
    hr

# Create the shared Docker network (idempotent). The subnet is pinned inside
# 172.16.0.0/12 so the ufw-docker forward gate (installed by `just lockdown`)
# already covers this network's egress with its default RFC1918 subnets.
# Only change it if you re-provision the gate with `sudo ufw-docker install --docker-subnets`.
networks:
    docker network inspect internal >/dev/null 2>&1 || docker network create --subnet 172.30.0.0/16 internal

# Lock the box down: install ufw (if missing), apply the tailnet-only
# deny-incoming ruleset, and install the ufw-docker forward gate. Idempotent.
# Enabling deny-incoming cuts the public IP route, so this first refuses to
# run unless the box is on the tailnet (tailscale ip -4), then prints what it
# will do and asks before executing.
#
# On distros that shipped iptables-persistent/netfilter-persistent (Oracle's
# Ubuntu images), installing ufw under apt removes those as a side effect. That
# transition happens HERE, in the same command that immediately enables a
# replacement firewall - so there is never a reboot between "old firewall
# removed" and "ufw in charge" (the hole you'd otherwise get on the next boot).
lockdown:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! tailscale ip -4 >/dev/null 2>&1; then
        echo "tailscale is not connected - refusing to drop the public IP route." >&2
        echo "Join the tailnet first: sudo tailscale up" >&2
        exit 1
    fi
    echo "About to lock the box down:"
    echo "  - install ufw if the bootstrap hasn't (also swaps out a distro-shipped iptables-persistent)"
    echo "  - ufw default-deny incoming (tailnet 22/53/443 allowed, no public ports)"
    echo "  - ufw --force enable"
    echo "  - re-apply the ufw-docker DOCKER-USER forward gate (and ufw-docker.service)"
    echo "This only re-applies the tailnet lockdown - public 443/80 rules you added are untouched."
    echo "If this SSH session is still over the public IP, ufw will DROP it - reconnect over the tailnet."
    read -r -p "Continue? [y/N] " lockdown_confirm
    if [ "$lockdown_confirm" != "y" ] && [ "$lockdown_confirm" != "Y" ]; then
        echo "aborted."
        exit 1
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        echo "installing ufw..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y ufw
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y ufw
        elif command -v zypper >/dev/null 2>&1; then
            sudo zypper install -y ufw
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -Sy --noconfirm ufw
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache ufw
        else
            echo "no supported package manager found - install ufw first, then re-run: just lockdown" >&2
            exit 1
        fi
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        echo "ufw install failed - install it manually, then re-run: just lockdown" >&2
        exit 1
    fi
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
    sudo ufw allow from 100.64.0.0/10 to any port 53 proto udp
    sudo ufw allow from 100.64.0.0/10 to any port 53 proto tcp
    sudo ufw allow from 100.64.0.0/10 to any port 443 proto tcp
    sudo ufw --force enable
    if [ ! -x /usr/bin/ufw-docker ]; then
        sudo curl -fsSL https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker \
            -o /usr/bin/ufw-docker
        sudo chmod 0755 /usr/bin/ufw-docker
    fi
    # ufw-docker's `install` copies itself to /usr/local/bin - a stale copy there
    # would shadow /usr/bin via PATH and fail with `cp: same file`. Drop it; the
    # install step recreates it.
    sudo rm -f /usr/local/bin/ufw-docker
    # `install --system` runs `mandb -q` under `set -e`; on minimal images
    # without man-db that aborts after writing the rules but before installing
    # ufw-docker.service. Shim a no-op mandb for the duration of the install.
    shim_mandb=0
    if ! command -v mandb >/dev/null 2>&1; then
        printf '#!/bin/sh\nexit 0\n' | sudo tee /usr/bin/mandb >/dev/null
        sudo chmod 0755 /usr/bin/mandb
        shim_mandb=1
    fi
    cleanup_mandb() { [ "$shim_mandb" -eq 1 ] && sudo rm -f /usr/bin/mandb; }
    trap cleanup_mandb EXIT
    sudo ufw-docker install --system
    cleanup_mandb
    trap - EXIT
    sudo systemctl restart ufw
    echo
    echo "lockdown applied: tailnet only, containers gated by ufw."
    echo "Verify any time with: sudo ufw-docker check"
    echo "Open the public serving ports when you're ready with: just go-public"

# Open (or close) the public serving ports for going public (Quickstart §10).
# Default action `open`; `just go-public close` removes them again. The other
# half - Cloudflare A records for the public hostnames - stays a manual step.
# Pair with `just lockdown` (which never touches public rules) for a quick
# public/private toggle.
go-public action="open":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{action}}" = "close" ]; then
        echo "About to close the public serving ports:"
        echo "  - remove ufw allow 443/tcp"
        echo "  - remove ufw allow 80/tcp (the http -> https redirect)"
        echo "Tailnet doors are untouched - the box stays reachable."
        read -r -p "Continue? [y/N] " go_public_confirm
        if [ "$go_public_confirm" != "y" ] && [ "$go_public_confirm" != "Y" ]; then
            echo "aborted."
            exit 1
        fi
        sudo ufw delete allow 443/tcp
        sudo ufw delete allow 80/tcp
        echo
        echo "public serving ports closed - the box is tailnet-only again."
        echo "Re-assert the lockdown any time with: just lockdown"
        exit 0
    fi
    echo "About to open the public serving ports:"
    echo "  - allow 443/tcp (Traefik https - the real way in)"
    echo "  - allow 80/tcp (http -> https redirect only; nothing is served on it)"
    echo "Do the manual half first: Cloudflare A records for seerr.<DOMAIN> and jellyfin.<DOMAIN>"
    echo "pointing at the public IP (DNS only - never proxied), or no DNS name reaches these."
    echo "See docs/ingress.md and Quickstart §10."
    if ! command -v ufw >/dev/null 2>&1 || ! sudo ufw status 2>/dev/null | grep -Fq "Status: active"; then
        echo "WARNING: ufw is not active - these rules only take effect once you run 'just lockdown'." >&2
    fi
    read -r -p "Continue? [y/N] " go_public_confirm
    if [ "$go_public_confirm" != "y" ] && [ "$go_public_confirm" != "Y" ]; then
        echo "aborted."
        exit 1
    fi
    sudo ufw allow 443/tcp
    sudo ufw allow 80/tcp
    echo
    echo "public serving ports open: Cloudflare -> VPS :443 -> Traefik -> CrowdSec -> the apps."
    echo "Close them again any time with: just go-public close"

# Validate every compose file against the docker compose schema.
# Read-only: never creates or edits a .env (compose treats .env as optional and the
# shell environment outranks it, so CONFIG_DIR is supplied here just for the check).
validate:
    @for s in {{ stack_list }}; do \
        echo "-- stacks/$s/compose.yaml" \
        && CONFIG_DIR="${CONFIG_DIR:-/tmp/just-validate}" \
           docker compose -f "stacks/$s/compose.yaml" config -q || exit 1 \
    ; done

# Pull fresh images for every stack
pull:
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" pull || exit 1 \
    ; done

# Update all containers to the images referenced in compose (pull + recreate changed ones)
update-all:
    just pull
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" up -d || exit 1 \
    ; done

# Update one stack, e.g. `just update traefik`
update stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" pull
    docker compose -f "stacks/{{ stack }}/compose.yaml" up -d

# Recreate one service within a stack (after bumping its tag), e.g. `just up-svc media-server jellyfin`
up-svc stack service:
    docker compose -f "stacks/{{ stack }}/compose.yaml" up -d "{{ service }}"

# Pull + recreate one service within a stack, e.g. `just update-svc media-server jellyfin`
update-svc stack service:
    docker compose -f "stacks/{{ stack }}/compose.yaml" pull "{{ service }}"
    docker compose -f "stacks/{{ stack }}/compose.yaml" up -d "{{ service }}"

# Compare pinned image tags against what the registries publish (read-only)
check-updates:
    #!/usr/bin/env python3
    import json
    import re
    import sys
    import urllib.request

    COMPOSE_FILES = (
        "stacks/traefik/compose.yaml",
        "stacks/media-server/compose.yaml",
    )
    VERSION_RE = re.compile(r"^v?[0-9]+(\.[0-9]+){1,4}$")

    def compose_images(path):
        current = None
        images = []
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            m = re.match(r"^  (\w[\w-]+):$", line)
            if m:
                current = m.group(1)
                continue
            m = re.match(r"^    image: (\S+)$", line)
            if m and current:
                images.append((current, m.group(1)))
        return images

    def split_image(image):
        node, _, _ = image.partition("@")
        name, sep, tag = node.partition(":")
        if not sep:
            tag = "latest"
        parts = name.split("/")
        if len(parts) == 1:
            return "docker.io", "library/" + name, tag
        host = parts[0]
        if "." in host or ":" in host or host == "localhost":
            registry, repo = host, "/".join(parts[1:])
            if registry == "lscr.io":
                return "docker.io", name.split("/", 1)[1], tag
            return registry, repo, tag
        return "docker.io", name, tag

    def http_json(url, headers=None, timeout=20):
        req = urllib.request.Request(url, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)

    def latest_docker_hub(repo):
        url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=100&ordering=last_updated"
        try:
            data = http_json(url)
        except Exception:
            return None
        for item in data.get("results", []):
            if VERSION_RE.match(item["name"]):
                return item["name"]
        return None

    def latest_ghcr(repo):
        try:
            token = http_json(f"https://ghcr.io/token?scope=repository:{repo}:pull")["token"]
        except Exception:
            return None
        tags = []
        url = f"https://ghcr.io/v2/{repo}/tags/list?n=10000"
        while url:
            try:
                req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
                with urllib.request.urlopen(req, timeout=20) as resp:
                    tags.extend(json.load(resp).get("tags", []))
                    url = None
                    for link in resp.headers.get("Link", "").split(","):
                        if 'rel="next"' in link:
                            url = link[link.index("<") + 1:link.index(">")]
            except Exception:
                return None
        candidates = sorted((t for t in tags if VERSION_RE.match(t)),
                            key=lambda t: [int(x) for x in re.sub(r"^v", "", t).split(".")])
        return candidates[-1] if candidates else None

    rows = []
    seen = set()
    for path in COMPOSE_FILES:
        for service, image in compose_images(path):
            key = (path, image)
            if key in seen:
                continue
            seen.add(key)
            registry, repo, pinned = split_image(image)
            if registry == "docker.io":
                latest = latest_docker_hub(repo)
            elif registry == "ghcr.io":
                latest = latest_ghcr(repo)
            else:
                latest = "(unsupported registry)"
            latest_v = latest.lstrip("v") if isinstance(latest, str) else None
            if latest_v is None:
                status = "?"
            else:
                status = "up-to-date" if latest_v == pinned.lstrip("v") else "UPDATE"
            rows.append((path, service, image, latest, status))

    headers = ("compose", "service", "image", "latest", "status")
    display = [[r[0], r[1], r[2], "-" if r[3] is None else r[3], r[4]] for r in rows]
    widths = [max(len(str(r[i])) for r in display + [list(headers)]) + 2 for i in range(len(headers))]
    fmt = "  ".join("{%d:<%d}" % (i, widths[i]) for i in range(len(headers)))
    print(fmt.format(*headers))
    print("  ".join("-" * (w - 2) for w in widths))
    for row in display:
        print(fmt.format(*[str(x) for x in row]))

    updates = sum(1 for _, _, _, _, status in display if status == "UPDATE")
    print(f"\n{updates} image(s) with newer tags available.")
    sys.exit(1 if updates else 0)

# List locally available images
images:
    docker images

# Show Docker disk usage (images, containers, volumes)
df:
    docker system df

# Bring the whole stack up (ensures networks + config dirs exist first)
# `just prepare` reads CONFIG_DIR from stacks/media-server/.env
up: networks prepare
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" up -d || exit 1 \
    ; done

# Tear the whole stack down
down:
    @for s in {{ stack_list }}; do \
        echo "-- $s" \
        && docker compose -f "stacks/$s/compose.yaml" down || exit 1 \
    ; done

# Restart one stack, e.g. `just restart traefik`
restart stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" restart

# Stream logs for one stack, e.g. `just logs media-server`
logs stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" logs -f --tail=100

# Stream logs for one service (searched across all stacks), e.g. `just logs-svc jellyfin`
logs-svc service:
    #!/usr/bin/env bash
    set -euo pipefail
    for s in {{ stack_list }}; do
        if docker compose -f "stacks/$s/compose.yaml" ps --services | grep -qx "{{ service }}"; then
            exec docker compose -f "stacks/$s/compose.yaml" logs -f --tail=100 "{{ service }}"
        fi
    done
    echo "no service '{{ service }}' in any stack" >&2
    exit 1

# Show the resolved compose config for one stack, e.g. `just config media-server`
config stack:
    docker compose -f "stacks/{{ stack }}/compose.yaml" config

# List running containers
ps:
    docker ps

# Bootstrap the Torrentio indexer definition into prowlarr's config dir from the
# Prowlarr-Indexers repo (see docs/indexers.md).
# Idempotent; re-run to re-install. Requires git + network; run on the server.
# CONFIG_DIR is read from stacks/media-server/.env (fallback the repo's data/ dir).
bootstrap-torrentio:
    #!/usr/bin/env bash
    set -euo pipefail

    CONFIG_DIR=$(sed -n 's|^CONFIG_DIR=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    CONFIG_DIR="${CONFIG_DIR:-{{ justfile_directory() }}/data}"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    git clone --depth 1 --filter=blob:none https://github.com/dreulavelle/Prowlarr-Indexers "$TMP" >/dev/null 2>&1
    mkdir -p "$CONFIG_DIR/prowlarr/Definitions/Custom"
    cp "$TMP/Custom/torrentio.yml" "$CONFIG_DIR/prowlarr/Definitions/Custom/torrentio.yml"
    echo "installed $CONFIG_DIR/prowlarr/Definitions/Custom/torrentio.yml"
    docker compose -f stacks/media-server/compose.yaml restart prowlarr 2>/dev/null \
        || echo "note: prowlarr is not running, the definition will load on next just up"

# Print a wiring cheat sheet for the *arrs: reads each app's API key
# from $CONFIG_DIR (taken from stacks/media-server/.env, custom via `just init`)
# so you can paste the right values into every UI (docs/arrs.md has the full
# walkthrough). Read-only; run on the server.
wiring:
    #!/usr/bin/env bash
    set -uo pipefail

    # ---- prettier UI: pure ANSI + unicode, plain-text fallback when piped ----
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
        B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
        RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
        MAG=$'\033[35m'; CYN=$'\033[36m'
    else
        B=''; D=''; R=''; RED=''; GRN=''; YEL=''; MAG=''; CYN=''
    fi
    case "${LC_ALL:-$LANG}" in
        *[Uu][Tt][Ff]*) G='─'; H='─'; V='│'; TL='╭'; TR='╮'; BL='╰'; BR='╯'
                        S='▸'; OK='✓'; WARN='⚠'; DONE='✔'; ELLIP='…' ;;
        *)              G='-'; H='-'; V='|'; TL='+'; TR='+'; BL='+'; BR='+'
                        S='>'; OK='ok'; WARN='!'; DONE='done'; ELLIP='...' ;;
    esac
    RULE=$(printf -- "$G%.0s" {1..66})

    hr() { printf '%s\n' "${CYN}${RULE}${R}"; }
    hdr() { hr; printf '%s\n' "  ${B}${CYN}${S} $1${R}"; hr; }
    chip() { printf '  %s%s%s\n' "$B$MAG" "$1" "$R"; }
    ok() { printf '  %s%s%s %s\n' "$GRN" "$OK" "$R" "$1"; }
    warn() { printf '  %s%s%s %s\n' "$YEL" "$WARN" "$R" "$1"; }
    muted() { printf '  %s%s%s\n' "$D" "$1" "$R"; }
    ask() { printf '  %s%s%s: ' "$B" "$1" "$R"; }
    lbl() { printf '%s%s%s' "$B$MAG" "$1" "$R"; }
    cur() { printf '%s%s%s' "$CYN" "$1" "$R"; }
    dim() { printf '%s%s%s' "$D" "$1" "$R"; }
    panel() {   # panel <title> [<line>...]: bordered card emulating the Cloudflare GUI;
                # "key: value" lines get magenta-bold keys + cyan values; other
                # lines stay plain (bold when a bare line ends in ':')
        local title="$1"; shift
        local w="${#title}" line i pad maxk=0 k v
        for line in "$@"; do
            [[ "$line" == *": "* ]] && { k="${line%%:*}"; [ "${#k}" -gt "$maxk" ] && maxk="${#k}"; }
        done
        for line in "$@"; do
            if [[ "$line" == *": "* ]]; then
                v="${line#*: }"
                pad=$((maxk + 2 + ${#v}))
                [ "$pad" -gt "$w" ] && w="$pad"
            else
                [ "${#line}" -gt "$w" ] && w="${#line}"
            fi
        done
        printf '  %s' "$TL"
        i=0; while [ "$i" -lt "$((w+2))" ]; do printf '%s' "$H"; i=$((i+1)); done
        printf '%s\n' "$TR"
        printf '  %s %s%s%s %s\n' "$V" "$B$MAG" "$(printf '%-*s' "$w" "$title")" "$R" "$V"
        printf '  %s %-*s %s\n' "$V" "$w" "" "$V"
        for line in "$@"; do
            case "$line" in
                *": "*)
                    k="${line%%:*}"
                    v="${line#*: }"
                    printf '  %s %s%s%-*s%s %s%-*s%s %s\n' \
                        "$V" "$B$MAG" "$k:" "$((maxk - ${#k}))" "" "$R" \
                        "$CYN" "$((w - maxk - 2))" "$v" "$R" "$V"
                    ;;
                *:)
                    printf '  %s %s%s%-*s%s %s\n' "$V" "$B" "" "$w" "$line" "$R" "$V"
                    ;;
                *)
                    printf '  %s %-*s %s\n' "$V" "$w" "$line" "$V"
                    ;;
            esac
        done
        printf '  %s' "$BL"
        i=0; while [ "$i" -lt "$((w+2))" ]; do printf '%s' "$H"; i=$((i+1)); done
        printf '%s\n' "$BR"
    }
    auto_row() {   # LABEL VALUE NOTE: one aligned row of the auto-generated summary
        printf '  %s %s %s\n' \
            "$(lbl "$(printf '%-*s' 23 "$1")")" \
            "$(cur "$2")" \
            "$(dim "$3")"
    }
    pause() {   # Enter advances to the next step, q quits; silent when not a TTY
        if [ -t 0 ]; then
            printf '  %s\n' "$(dim "next: $1    [Enter] to continue  /  q to quit")"
            read -r _pause_ans </dev/tty || _pause_ans=
            case "$_pause_ans" in
                q|Q|quit|Quit) exit 0 ;;
            esac
        fi
    }

    CONFIG_DIR=$(sed -n 's|^CONFIG_DIR=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    CONFIG_DIR="${CONFIG_DIR:-{{ justfile_directory() }}/data}"

    arr_key() {   # $1 = app name; echoes the ApiKey from its config.xml
        local f="$CONFIG_DIR/$1/config.xml"
        if [ ! -f "$f" ]; then
            echo "(no $1/config.xml - start $1 once so it writes its config)"
            return 1
        fi
        awk -F'[<>]' '
            /<ApiKey>/ {
                s=$0; sub(/^.*<ApiKey>/,"",s); sub(/<\/ApiKey>.*$/,"",s)
                gsub(/^[ \t]+|[ \t]+$/,"",s)
                if (s) { print s; exit }
                if (getline > 0) { sub(/^[ \t]+|[ \t]+$/,"",$0); print; exit }
            }' "$f" || true
    }

    SONARR_KEY=$(arr_key sonarr)
    RADARR_KEY=$(arr_key radarr)
    PROWLARR_KEY=$(arr_key prowlarr)

    show_key() {   # label value: missing values are dimmed hints, present ones cyan
        case "$2" in
            "(no"*)   printf '  %s %s\n' "$(lbl "$(printf '%-*s' 14 "$1")")" "$(dim "$2")" ;;
            "")       printf '  %s %s\n' "$(lbl "$(printf '%-*s' 14 "$1")")" "$(dim "unset - $1 has no key yet")" ;;
            *)        printf '  %s %s\n' "$(lbl "$(printf '%-*s' 14 "$1")")" "$(cur "$2")" ;;
        esac
    }
    show_key "sonarr:8989"   "$SONARR_KEY"
    show_key "radarr:7878"   "$RADARR_KEY"
    show_key "prowlarr:9696" "$PROWLARR_KEY"
    echo
    sonarr_clients() {   # step 1: sonarr
        hdr "sonarr -> Settings -> Download Clients: add BOTH (debrid + usenet)"
        panel "qBittorrent" \
            "Name: Decypharr (debrid)" \
            "Host: decypharr" \
            "Port: 8282" \
            "Username: http://sonarr:8989" \
            "Password: $SONARR_KEY"
        panel "SABnzbd" \
            "Name: Decypharr (usenet)" \
            "Host: decypharr" \
            "Port: 8282" \
            "URL Base: /sabnzbd" \
            "Username: http://sonarr:8989" \
            "Password: $SONARR_KEY"
        muted "(bump Client Priority to prefer debrid or usenet)"
        echo
    }
    radarr_clients() {   # step 2: radarr
        hdr "radarr -> Settings -> Download Clients: add BOTH (debrid + usenet)"
        panel "qBittorrent" \
            "Name: Decypharr (debrid)" \
            "Host: decypharr" \
            "Port: 8282" \
            "Username: http://radarr:7878" \
            "Password: $RADARR_KEY"
        panel "SABnzbd" \
            "Name: Decypharr (usenet)" \
            "Host: decypharr" \
            "Port: 8282" \
            "URL Base: /sabnzbd" \
            "Username: http://radarr:7878" \
            "Password: $RADARR_KEY"
        muted "(bump Client Priority to prefer debrid or usenet)"
        echo
    }
    decypharr_arrs() {   # step 3: decypharr
        hdr "decypharr -> Settings -> Arrs: add one per *arr"
        panel "Sonarr" \
            "Service Name: Sonarr" \
            "Host URL: http://sonarr:8989" \
            "API Token: $SONARR_KEY"
        panel "Radarr" \
            "Service Name: Radarr" \
            "Host URL: http://radarr:7878" \
            "API Token: $RADARR_KEY"
        muted "(enable the repair worker + queue cleanup so failed grabs don't pile up)"
        echo
    }
    sonarr_root() {   # step 2: sonarr root folder
        hdr "sonarr -> Settings -> Media Management -> Root Folders"
        panel "point the library at the Decypharr mount (same filesystem as imports)" \
            "/mnt/decypharr/shows"
        muted "(path must exist - create it first: mkdir -p /mnt/debrid/decypharr/shows  # after the DFS mount is up)"
        echo
    }
    radarr_root() {   # step 4: radarr root folder
        hdr "radarr -> Settings -> Media Management -> Root Folders"
        panel "point the library at the Decypharr mount (same filesystem as imports)" \
            "/mnt/decypharr/movies"
        muted "(path must exist - create it first: mkdir -p /mnt/debrid/decypharr/movies  # after the DFS mount is up)"
        echo
    }
    jellyfin_libs() {   # step 6: jellyfin libraries
        hdr "jellyfin -> Dashboard -> Libraries"
        panel "add one library per arr, on the same folders" \
            "Shows   /mnt/decypharr/shows" \
            "Movies  /mnt/decypharr/movies"
        muted "(Jellyfin reads straight off the mount - no extra paths needed)"
        echo
    }
    jellyfin_transcode() {   # step 7: jellyfin transcode path
        hdr "jellyfin -> Dashboard -> Playback"
        panel "keep transcode scratch off disk" \
            "Transcode path  /transcodes"
        muted "(/transcodes is a tmpfs - software transcodes stay in RAM; see docs/jellyfin.md)"
        echo
    }
    prowlarr_apps() {   # step 8: prowlarr
        hdr "prowlarr -> Settings -> Apps (indexer sync)"
        panel "Sonarr" \
            "Name: Sonarr" \
            "Prowlarr Server: http://prowlarr:9696" \
            "Sonarr Server: http://sonarr:8989" \
            "API Key: $SONARR_KEY"
        panel "Radarr" \
            "Name: Radarr" \
            "Prowlarr Server: http://prowlarr:9696" \
            "Radarr Server: http://radarr:7878" \
            "API Key: $RADARR_KEY"
        muted "(every indexer added here is pushed to both apps, tagged '(Prowlarr)')"
        echo
    }
    seerr() {   # step 9: seerr
        hdr "seerr -> Settings"
        panel "wire Jellyfin + the two arrs" \
            "Jellyfin  http://jellyfin:8096  + API key from Jellyfin Dashboard -> API Keys" \
            "Radarr    http://radarr:7878  $RADARR_KEY" \
            "Sonarr    http://sonarr:8989  $SONARR_KEY"
        muted "(when adding the arrs pick the Direct Play profile + the root folders above)"
        echo
    }
    bazarr_subs() {   # step 10: bazarr
        hdr "bazarr -> Settings -> Sonarr / Radarr (subtitles)"
        panel "add both arrs so subtitles land next to the media" \
            "Sonarr  http://sonarr:8989  $SONARR_KEY" \
            "Radarr  http://radarr:7878  $RADARR_KEY"
        muted "(after enabling, assign a language profile to the libraries - see docs/arrs.md)"
        echo
    }

    sonarr_clients
    pause "sonarr root folders"
    sonarr_root
    pause "radarr download clients"
    radarr_clients
    pause "radarr root folders"
    radarr_root
    pause "decypharr arrs"
    decypharr_arrs
    pause "jellyfin libraries"
    jellyfin_libs
    pause "jellyfin transcode path"
    jellyfin_transcode
    pause "prowlarr apps"
    prowlarr_apps
    pause "seerr"
    seerr
    pause "bazarr subtitles"
    bazarr_subs
    muted "done - paste each URL + API key pair from the panels above and test the connection in the UI."

# Show the tailnet DNS resolver setup (CoreDNS in the traefik stack).
# The matching Tailscale admin setting is one-time: DNS -> Nameservers -> add
# TAILNET_IP:53, restricted to DNS -> the domain only (see docs/tailnet.md).
dns:
    #!/usr/bin/env bash
    set -euo pipefail
    T=$(sed -n 's|^TAILNET_IP=\(.*\)|\1|p' stacks/traefik/.env | tail -n1)
    D=$(sed -n 's|^DOMAIN=\(.*\)|\1|p' stacks/traefik/.env | tail -n1)
    echo "resolver : $T:53  (CoreDNS container in the traefik stack)"
    echo "serves   : *.$D -> $T     (tailnet only; see docs/tailnet.md)"
    echo "console  : Tailscale DNS -> Nameservers -> custom $T, restricted to $D"

# Query the tailnet DNS resolver directly (run on the server; needs the ufw 53
# rule from docs/quickstart.md §4). Args: optional hostname (default one panel, e.g.
# radarr.<DOMAIN>). Returns the tailnet IP for any *.DOMAIN name.
dnscheck domain="":
    #!/usr/bin/env bash
    set -euo pipefail
    T=$(sed -n 's|^TAILNET_IP=\(.*\)|\1|p' stacks/traefik/.env | tail -n1)
    D=$(sed -n 's|^DOMAIN=\(.*\)|\1|p' stacks/traefik/.env | tail -n1)
    Q="{{ domain }}"
    [ -n "$Q" ] || Q="radarr.$D"
    echo "querying $Q against $T:53 ..."
    docker run --rm --net=host busybox:1.37.0 nslookup "$Q" "$T"
    echo "expect: Address $T  (the VPS tailnet IP)"

# Encrypted, deduplicated repo backups with restic, run in a container (nothing to
# install). Documented backend is Cloudflare R2 (see how-to in the wiki); `.env.restic`
# is configured by `just init` (R2_ACCOUNT_ID / R2_BUCKET / AWS creds -> RESTIC_REPOSITORY
# + RESTIC_PASSWORD; `AWS_DEFAULT_REGION=auto` is required for R2). Deviating is one edit
# in .env.restic - RESTIC_REPOSITORY selects any backend (local, sftp:, s3:, b2:, rclone: ...)
# and RESTIC_PASSWORD encrypts it; everything in that file is forwarded via docker run
# --env-file, so backend credentials added there are forwarded too. Scope: the repo working
# tree - every .env plus data/ (with the default layout that includes the $CONFIG_DIR app
# config state too). If you point CONFIG_DIR at external storage, cover it with native
# snapshots / a second restic profile. Configure .env.restic with `just init`, or copy
# .env.restic.example by hand.
[group('Backups')]
backup-init:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f .env.restic ]; then
        echo "no .env.restic - run 'just init' (answer yes to restic) or copy .env.restic.example to .env.restic"
        exit 1
    fi
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    if docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} snapshots >/dev/null 2>&1; then
        echo "repository already initialized at $(sed -n 's|^RESTIC_REPOSITORY=\(.*\)|\1|p' .env.restic | tail -n1)"
    else
        echo "initializing restic repository ..."
        docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} init
    fi

[group('Backups')]
backup:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        -v "{{ justfile_directory() }}":/repo:ro \
        {{ restic_image }} backup /repo \
        --exclude /repo/.git

[group('Backups')]
backup-list:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} snapshots

[group('Backups')]
backup-check:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    docker run --rm --env-file .env.restic -v restic-cache:/root/.cache/restic {{ restic_image }} check

[group('Backups')]
backup-prune:
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    KEEP_ARGS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^RESTIC_KEEP_([A-Z]+)=([0-9]+)$ ]] || continue
        [ "${BASH_REMATCH[2]}" -gt 0 ] || continue
        KEEP_ARGS+=( "--keep-${BASH_REMATCH[1],,}" "${BASH_REMATCH[2]}" )
    done < .env.restic

    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        {{ restic_image }} forget --prune "${KEEP_ARGS[@]}"

# Restore a snapshot into the repo working tree (default: latest). Non-destructive:
# dry-runs first and shows exactly what would change, then asks before writing.
# Files not in the snapshot are kept (no --delete); restored files replace current
# ones in place (restic --overwrite=always).
[group('Backups')]
backup-restore SNAPSHOT="latest":
    #!/usr/bin/env bash
    set -euo pipefail

    [ -f .env.restic ] || { echo "no .env.restic - see 'just backup-init'"; exit 1; }
    grep -q '^RESTIC_REPOSITORY=..*$' .env.restic || { echo "set RESTIC_REPOSITORY in .env.restic"; exit 1; }
    grep -q '^RESTIC_PASSWORD=..*$' .env.restic || { echo "set RESTIC_PASSWORD in .env.restic"; exit 1; }

    echo "previewing what the restore would change (dry run; nothing is written) ..."
    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        -v "{{ justfile_directory() }}":/repo:ro \
        {{ restic_image }} restore "{{ SNAPSHOT }}" --target / --dry-run -vv

    echo
    printf 'Files not in the snapshot are kept; the rest get overwritten in place. Restore %s into %s/? ' "{{ SNAPSHOT }}" "{{ justfile_directory() }}"
    read -r confirm || confirm=""
    case "$confirm" in
    y|Y|yes|Yes|YES) : ;;
    *) echo "aborted - nothing was restored."; exit 1 ;;
    esac

    echo
    echo "restoring {{ SNAPSHOT }} into {{ justfile_directory() }}/ ..."
    docker run --rm \
        --env-file .env.restic \
        -v restic-cache:/root/.cache/restic \
        -v "{{ justfile_directory() }}":/repo \
        {{ restic_image }} restore "{{ SNAPSHOT }}" --target /

# Install a systemd timer that runs 'just backup' on ON_CALENDAR (default daily).
# Writes kickstarrt-restic-backup.{service,timer} under /etc/systemd/system via sudo, then
# enables the timer. Rerun to change the schedule. systemd is assumed on Linux
# servers; on a host without it (Alpine, a NAS scheduler, cron) this prints a
# fallback instead of erroring, and .env.restic is required before it will run.
[group('Backups')]
backup-schedule ON_CALENDAR="daily":
    #!/usr/bin/env bash
    set -euo pipefail

    command -v systemctl >/dev/null 2>&1 || {
        echo "no systemd (systemctl not found) - run the backup via cron instead, e.g.:"
        echo "  0 4 * * * cd '{{ justfile_directory() }}' && $(command -v just || echo 'just') backup"
        echo "(or your NAS scheduler; see docs/maintenance.md)"
        exit 1
    }
    command -v sudo >/dev/null 2>&1 || { echo "sudo not found - install sudo or run these commands as root"; exit 1; }
    command -v just >/dev/null 2>&1 || { echo "'just' not on PATH - install just before scheduling"; exit 1; }
    [ -f .env.restic ] || { echo "no .env.restic - configure restic first ('just init' or copy .env.restic.example)"; exit 1; }

    JUST_BIN=$(command -v just)
    REPO="{{ justfile_directory() }}"
    ON_CALENDAR="{{ ON_CALENDAR }}"

    printf '%s\n' \
        "This installs a systemd timer that runs '$JUST_BIN backup' in '$REPO'" \
        "on calendar '$ON_CALENDAR'. Two files are written under /etc/systemd/system" \
        'with sudo and the timer is enabled + started:'
    printf '  /etc/systemd/system/kickstarrt-restic-backup.timer\n  /etc/systemd/system/kickstarrt-restic-backup.service\n'
    printf 'Proceed? [y/N] '
    read -r ok || ok=""
    case "$ok" in
    y|Y|yes|Yes|YES) : ;;
    *) echo "aborted"; exit 1 ;;
    esac

    printf '%s\n' \
        '[Unit]' \
        'Description=Restic backup of the media repo' \
        'After=network-online.target' \
        'Wants=network-online.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        "WorkingDirectory=$REPO" \
        "ExecStart=$JUST_BIN backup" \
        | sudo tee /etc/systemd/system/kickstarrt-restic-backup.service >/dev/null

    printf '%s\n' \
        '[Unit]' \
        'Description=Run the restic repo backup daily' \
        '' \
        '[Timer]' \
        "OnCalendar=$ON_CALENDAR" \
        'Persistent=true' \
        'Unit=kickstarrt-restic-backup.service' \
        '' \
        '[Install]' \
        'WantedBy=timers.target' \
        | sudo tee /etc/systemd/system/kickstarrt-restic-backup.timer >/dev/null

    sudo systemctl daemon-reload
    sudo systemctl enable --now kickstarrt-restic-backup.timer
    echo
    echo "installed kickstarrt-restic-backup.{service,timer} - timer enabled and active."
    systemctl list-timers kickstarrt-restic-backup.timer --no-pager
    echo "remove it later with 'just backup-unschedule'."

# Stop and remove the restic backup systemd timer + service installed by
# backup-schedule (idempotent; sudo)
[group('Backups')]
backup-unschedule:
    #!/usr/bin/env bash
    set -euo pipefail

    command -v systemctl >/dev/null 2>&1 || { echo "no systemd - nothing to uninstall"; exit 0; }
    command -v sudo >/dev/null 2>&1 || { echo "sudo not found - run these commands as root"; exit 1; }

    sudo systemctl disable --now kickstarrt-restic-backup.timer >/dev/null 2>&1 || true
    sudo systemctl reset-failed kickstarrt-restic-backup.timer >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/kickstarrt-restic-backup.timer /etc/systemd/system/kickstarrt-restic-backup.service
    sudo systemctl daemon-reload
    echo "removed kickstarrt-restic-backup.{timer,service} and stopped the timer."

# Prepare everything on disk that compose bind-mounts (idempotent; called by `just up`):
# the per-service config dirs, traefik's logs dir and acme.json (0600, must be a FILE -
# docker would otherwise create a directory and ACME storage breaks), and the rendered
# traefik.yml. CONFIG_DIR comes from stacks/media-server/.env (the repo's data/ dir).
# PUID/PGID: media-server .env ENV_PUID/ENV_PGID, else this user's ids, else
# 1000 - so ownership always matches what the containers run as.
# Also prepares the Decypharr host bind tree (/mnt/debrid) + its DFS mountpoint,
# owned to PUID/PGID (sudo) - see docs/decypharr.md.
prepare:
    #!/usr/bin/env bash
    set -euo pipefail

    CONFIG_DIR=$(sed -n 's|^CONFIG_DIR=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    CONFIG_DIR="${CONFIG_DIR:-{{ justfile_directory() }}/data}"
    PUID=$(sed -n 's|^ENV_PUID=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    PGID=$(sed -n 's|^ENV_PGID=\(.*\)|\1|p' stacks/media-server/.env | tail -n1)
    if [ -z "$PUID" ] || [ "$PUID" = auto ]; then
        PUID=$(id -u)
        [ "$PUID" -eq 0 ] && PUID=1000
    fi
    if [ -z "$PGID" ] || [ "$PGID" = auto ]; then
        PGID=$(id -g)
        [ "$PGID" -eq 0 ] && PGID=1000
    fi

    # Host bind tree (/mnt/debrid - the compose binds it into every media container
    # as /mnt). Decypharr mounts DFS at /mnt/debrid/decypharr as the stack user, and a
    # root-owned mountpoint is exactly the "fusermount3: user has no write access to
    # mountpoint" failure. Nothing under it is owned on the host - the *arrs and
    # Jellyfin read through the FUSE mount - so fix ownership non-recursively: on a
    # live stack a recursive chown would walk straight into the mount, and re-owning
    # the live decypharr mountpoint itself would hit the FUSE fs.
    #
    # Only the pieces that are actually missing/mis-owned get touched, so a normal
    # `just up` needs no sudo at all: the first run prompts once, a repair prompts
    # only when something is genuinely wrong.
    HOST_LIB=/mnt/debrid
    FIX=()
    for d in "$HOST_LIB" "$HOST_LIB/decypharr"; do
        findmnt -rno TARGET "$d" >/dev/null 2>&1 && continue   # a live mount - never re-own
        [ -e "$d" ] || { FIX+=("$d"); continue; }
        [ "$(stat -c %u:%g "$d" 2>/dev/null)" = "$PUID:$PGID" ] || FIX+=("$d")
    done
    if [ "${#FIX[@]}" -gt 0 ]; then
        if [ "$(id -u)" -eq 0 ]; then
            mkdir -p -- "${FIX[@]}" && chown "$PUID":"$PGID" -- "${FIX[@]}"
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo mkdir -p -- "${FIX[@]}" && sudo chown "$PUID":"$PGID" -- "${FIX[@]}"
        elif command -v sudo >/dev/null 2>&1; then
            sudo mkdir -p -- "${FIX[@]}"
            sudo chown "$PUID":"$PGID" -- "${FIX[@]}"
        else
            echo "no root or sudo available: create and chown $HOST_LIB yourself"
            echo "(see docs/decypharr.md) - else decypharr's DFS mount will fail"
        fi
    fi

    mkdir -p "$CONFIG_DIR"/{jellyfin/config,seerr/config,radarr,sonarr,prowlarr,recyclarr,bazarr/config,decypharr/configs,crowdsec/config,crowdsec/data}

    # traefik: logs dir (crowdsec reads it) + acme.json as a FILE with 0600, or
    # docker creates a directory there and cert storage silently fails.
    mkdir -p "$CONFIG_DIR/traefik/logs"
    [ -e "$CONFIG_DIR/traefik/acme.json" ] || touch "$CONFIG_DIR/traefik/acme.json"
    chmod 600 "$CONFIG_DIR/traefik/acme.json" 2>/dev/null || true

    # Entrypoint bind IPs: PUBLIC_BIND (the provider-mapped IP) and TAILNET_IP
    # (the box's Tailscale IP) are published on separate host IPs by
    # stacks/traefik/compose.yaml's ports - never on 0.0.0.0 - so each entrypoint
    # gets its own :443 socket. Existing installs upgrade seamlessly: fill them
    # from tailscale / the default route when they're unset.
    if ! grep -q "^TAILNET_IP=" stacks/traefik/.env 2>/dev/null; then
        echo "TAILNET_IP=" >> stacks/traefik/.env
    fi
    TAILNET_IP=$(sed -n 's|^TAILNET_IP=\(.*\)|\1|p' stacks/traefik/.env | tail -n1 || true)
    if [ -z "$TAILNET_IP" ]; then
        TS_NEW=$( { command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null; } | head -n1 || true)
        [ -n "$TS_NEW" ] || TS_NEW=$( { command -v sudo >/dev/null 2>&1 && sudo -n tailscale ip -4 2>/dev/null; } | head -n1 || true)
        if [ -n "$TS_NEW" ]; then
            sed "s|^TAILNET_IP=.*|TAILNET_IP=$TS_NEW|" stacks/traefik/.env > stacks/traefik/.env.tmp \
                && mv stacks/traefik/.env.tmp stacks/traefik/.env
            TAILNET_IP="$TS_NEW"
            echo "tailnet entrypoint: filled TAILNET_IP=$TAILNET_IP (stacks/traefik/.env)"
        fi
    fi
    if ! grep -q "^PUBLIC_BIND=" stacks/traefik/.env 2>/dev/null; then
        echo "PUBLIC_BIND=" >> stacks/traefik/.env
    fi
    PUBLIC_BIND=$(sed -n 's|^PUBLIC_BIND=\(.*\)|\1|p' stacks/traefik/.env | tail -n1 || true)
    if [ -z "$PUBLIC_BIND" ]; then
        PUB_NEW=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | sed -n 's/.*src \([0-9.]*\).*/\1/p' \
            | grep -Ev '^(127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
            | head -n1 || true)
        [ -n "$PUB_NEW" ] || PUB_NEW=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '{ split($4,a,"/"); if (a[1] !~ /^(127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)/) { print a[1]; exit } }' || true)
        if [ -n "$PUB_NEW" ]; then
            sed "s|^PUBLIC_BIND=.*|PUBLIC_BIND=$PUB_NEW|" stacks/traefik/.env > stacks/traefik/.env.tmp \
                && mv stacks/traefik/.env.tmp stacks/traefik/.env
            PUBLIC_BIND="$PUB_NEW"
            echo "public entrypoint: filled PUBLIC_BIND=$PUB_NEW (stacks/traefik/.env)"
        fi
    fi

    # traefik's static config cannot read env vars, so render it here.
    TPL="{{ justfile_directory() }}/data/traefik/traefik.template.yml"
    if [ -f "$TPL" ]; then
        if [ -z "$TAILNET_IP" ] || [ -z "$PUBLIC_BIND" ]; then
            echo "error: TAILNET_IP/PUBLIC_BIND are empty - docker publishes each of traefik's"
            echo "       entrypoints on its own host IP (compose.yaml ports), and an empty bind"
            echo "       would make those mappings invalid. tailscale must be up (TAILNET_IP)"
            echo "       and a default route present (PUBLIC_BIND); otherwise set them by hand"
            echo "       in stacks/traefik/.env."
            exit 1
        fi
        ACME_EMAIL=$(sed -n 's|^ACME_EMAIL=\(.*\)|\1|p' stacks/traefik/.env 2>/dev/null | tail -n1 || true)
        ACME_EMAIL="${ACME_EMAIL:-}"
        sed "s|\${ACME_EMAIL}|$ACME_EMAIL|g" "$TPL" > "$CONFIG_DIR/traefik/traefik.yml.tmp"
        mv "$CONFIG_DIR/traefik/traefik.yml.tmp" "$CONFIG_DIR/traefik/traefik.yml"
        if [ -z "$ACME_EMAIL" ]; then
            echo "warning: ACME_EMAIL is empty in stacks/traefik/.env - traefik requires it for"
            echo "         the ACME resolver, so no certificates will be issued. Run 'just init'."
            echo "         (There is no Let's Encrypt account to sign up for - see docs/ingress.md.)"
        fi
    fi
    COREPL="{{ justfile_directory() }}/data/traefik/coredns.Corefile"
    if [ -f "$COREPL" ]; then
        COREDOMAIN=$(sed -n 's|^DOMAIN=\(.*\)|\1|p' stacks/traefik/.env | tail -n1 || true)
        if [ -z "$COREDOMAIN" ] || [ -z "$TAILNET_IP" ]; then
            echo "warning: DOMAIN/TAILNET_IP missing in stacks/traefik/.env - CoreDNS"
            echo "         tailnet resolution is disabled. Run 'just init'."
        else
            mkdir -p "$CONFIG_DIR/coredns"
            sed -e "s|@DOMAIN@|$COREDOMAIN|g" -e "s|@TAILNET_IP@|$TAILNET_IP|g" "$COREPL" \
                > "$CONFIG_DIR/coredns/Corefile.tmp"
            mv "$CONFIG_DIR/coredns/Corefile.tmp" "$CONFIG_DIR/coredns/Corefile"
            echo "tailnet DNS: rendered $CONFIG_DIR/coredns/Corefile (*.$COREDOMAIN -> $TAILNET_IP)"
        fi
    fi

    # Only touch entries that are actually mis-owned, and never abort `just up`
    # over a file we cannot chown (e.g. root-owned state from a container).
    chown "$PUID":"$PGID" "$CONFIG_DIR" 2>/dev/null || true
    find "$CONFIG_DIR" \( ! -uid "$PUID" -o ! -gid "$PGID" \) -exec chown "$PUID":"$PGID" {} + 2>/dev/null || true

# Pull the shared, host-agnostic files in from the self-hosted edition (upstream).
# Only files that are UNCHANGED in this edition are taken (a local edit means the
# file has diverged and is yours to reconcile); anything both editions changed is
# reported for a manual diff. Establishes the `upstream` remote on first run.
sync-upstream:
    #!/usr/bin/env bash
    set -euo pipefail

    REMOTE=upstream
    URL="https://github.com/erdemoney/kickstarrt.git"

    if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
        git remote add "$REMOTE" "$URL"
        echo "added $REMOTE -> $URL"
    fi
    git fetch "$REMOTE" -q

    SHARED=(
        "data/traefik/crowdsec-acquis.yaml"
        "data/traefik/dynamic.yml"
        "data/traefik/traefik.template.yml"
        "docs/services.md"
        "docs/indexers.md"
        "docs/decypharr.md"
        ".pre-commit-config.yaml"
    )

    taken=0; diverged=0
    for f in "${SHARED[@]}"; do
        if [ "$(git diff "$REMOTE/main" -- "$f" | head -n1)" = "" ] && \
           [ "$(git diff --cached HEAD -- "$f" | head -n1)" = "" ]; then
            continue   # no upstream change since our HEAD
        fi
        if [ -z "$(git status --porcelain -- "$f")" ]; then
            git checkout "$REMOTE/main" -- "$f"
            echo "took    $f"
            taken=$((taken+1))
        else
            echo "diverged $f  (edited in this edition - resolve manually)"
            diverged=$((diverged+1))
        fi
    done

    echo
    echo "taken=$taken  diverged=$diverged"
    if [ "$taken" -gt 0 ]; then
        echo "review with 'git diff --cached', then commit."
    fi
    echo "every other file is owned by this edition - an upstream merge must never overwrite it."
