#!/usr/bin/env bash
# retrosync-reset.sh — Maintenance / cleanup tool for RetroSync.
#
# Removes RetroSync folder configs (and optionally device pairings) from a
# NAS Syncthing instance over its REST API. Use it to clean up "ghost users"
# (folders left behind after a directory was deleted by hand), remove a whole
# user, drop individual folders, or wipe every RetroSync folder for a fresh
# start.
#
# It only ever touches Syncthing *configuration* (folder + device entries
# whose folder id starts with "retrosync-"). It does NOT delete any data
# files — delete those yourself on the NAS afterward if you want them gone.
#
# License: GPL-3.0   Project: https://github.com/The-HBA/Retrosync
if [ -z "${BASH_VERSION:-}" ]; then
    printf 'retrosync-reset.sh requires bash, not sh/dash.\n' >&2
    exit 1
fi
set -euo pipefail

readonly FOLDER_ID_PREFIX="retrosync"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# ── tiny output helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_GREY=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_GREY=""
fi
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info()  { printf '%sℹ%s %s\n' "$C_CYAN"  "$C_RESET" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s✗%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
fatal() { err "$@"; exit 1; }
hr()    { printf '%s%s%s\n' "$C_GREY" "════════════════════════════════════════════════════════════" "$C_RESET"; }

prompt()    { local q="$1" d="${2:-}" r; if [[ -n "$d" ]]; then printf '%s [%s]: ' "$q" "$d" >&2; else printf '%s: ' "$q" >&2; fi; IFS= read -r r; echo "${r:-$d}"; }
prompt_yn() { local q="$1" d="${2:-n}" r; while true; do printf '%s [%s/%s]: ' "$q" "$([[ $d == y ]] && echo Y || echo y)" "$([[ $d == n ]] && echo N || echo n)" >&2; IFS= read -r r; r="${r:-$d}"; case "${r,,}" in y|yes) return 0;; n|no) return 1;; *) printf '  y or n.\n' >&2;; esac; done; }
prompt_secret() { local q="$1" r; printf '%s: ' "$q" >&2; IFS= read -rs r; printf '\n' >&2; echo "$r"; }

for t in curl jq; do command -v "$t" >/dev/null 2>&1 || fatal "Missing required tool: $t"; done

# ── connect ──────────────────────────────────────────────────────────────────
NAS_URL=""; NAS_KEY=""

load_from_profile() {
    # Offer to read NAS URL + key from an existing RetroSync profile.json.
    local pf="${XDG_CONFIG_HOME:-$HOME/.config}/retrosync/profile.json"
    [[ -f "$pf" ]] || return 1
    local url key storage
    url="$(jq -r '.nas_syncthing.url // empty' "$pf" 2>/dev/null || true)"
    storage="$(jq -r '.nas_syncthing.api_key_storage // "plaintext"' "$pf" 2>/dev/null || true)"
    key="$(jq -r '.nas_syncthing.api_key // empty' "$pf" 2>/dev/null || true)"
    [[ -z "$url" ]] && return 1
    # Only auto-use the key if it's stored plaintext; other modes need the
    # main script's decryption, so fall back to prompting.
    if [[ "$storage" != "plaintext" || -z "$key" ]]; then
        info "Found a profile at $pf (NAS: ${url}) but its API key is not plaintext."
        return 1
    fi
    if prompt_yn "Use NAS connection from $pf ?" "y"; then
        NAS_URL="$url"; NAS_KEY="$key"; return 0
    fi
    return 1
}

normalize_url() {
    # "1.2.3.4" / "1.2.3.4:8384" / "http://host:8384" -> "http://host:8384/rest"
    local raw="$1" scheme=http rest hostpart
    if [[ "$raw" =~ ^(https?)://(.+)$ ]]; then scheme="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; else rest="$raw"; fi
    rest="${rest%/}"; rest="${rest%/rest}"
    hostpart="${rest%%/*}"
    [[ "$hostpart" =~ :[0-9]+$ ]] || hostpart="${hostpart}:8384"
    echo "${scheme}://${hostpart}/rest"
}

api() {
    # api METHOD PATH [body]
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -fsS -X "$method" -H "X-API-Key: $NAS_KEY" -H "Content-Type: application/json" \
            -d "$body" "${NAS_URL}${path}" 2>/dev/null
    else
        curl -fsS -X "$method" -H "X-API-Key: $NAS_KEY" "${NAS_URL}${path}" 2>/dev/null
    fi
}

connect() {
    if ! load_from_profile; then
        local raw
        raw="$(prompt "NAS Syncthing address (e.g. 192.168.1.50:8384)")"
        [[ -z "$raw" ]] && fatal "No address given."
        NAS_URL="$(normalize_url "$raw")"
        NAS_KEY="$(prompt_secret "NAS Syncthing API key")"
    fi
    info "Connecting to ${NAS_URL} …"
    local ping
    ping="$(api GET /system/ping || true)"
    if [[ "$(echo "$ping" | jq -r '.ping // empty' 2>/dev/null)" != "pong" ]]; then
        fatal "Couldn't reach Syncthing at ${NAS_URL} (check address + API key)."
    fi
    ok "Connected."
}

# ── data helpers ─────────────────────────────────────────────────────────────
# Echo all RetroSync folder objects (id + path), one compact JSON per line.
retrosync_folders() {
    api GET /config/folders \
        | jq -c --arg p "${FOLDER_ID_PREFIX}-" '.[] | select(.id | startswith($p)) | {id, path, label}'
}

# Echo "user<TAB>count" for each detected user. A "user" is the path component
# right after the longest common base; we infer it from the folder id instead:
#   retrosync-<user>-<scope>  -> user
#   retrosync-<scope>         -> "(single-user / no username)"
list_users() {
    retrosync_folders | jq -r '.id' | awk -v pre="${FOLDER_ID_PREFIX}-" '
        {
            id = $0; sub("^" pre, "", id)
            # id is now "<user>-<scope>" or "<scope>" (scope may contain "-").
            # Heuristic: known bare scopes have no user segment.
            n = split(id, parts, "-")
            scope0 = parts[1]
            if (scope0 == "roms" || scope0 == "bios" || scope0 == "save" || \
                scope0 == "rd" || scope0 == "rb" || scope0 == "custom") {
                u = "(no username)"
            } else {
                u = parts[1]
            }
            cnt[u]++
        }
        END { for (u in cnt) printf "%s\t%s\n", u, cnt[u] }
    ' | sort
}

delete_folder() {
    local id="$1"
    if [[ $DRY_RUN -eq 1 ]]; then printf '%s[DRY]%s would DELETE folder %s\n' "$C_CYAN" "$C_RESET" "$id"; return 0; fi
    if api DELETE "/config/folders/${id}" >/dev/null; then ok "removed folder ${id}"; else err "failed to remove ${id}"; fi
}

# Remove device entries that are no longer referenced by any folder.
prune_orphan_devices() {
    local my_id devices folders refs dev
    my_id="$(api GET /system/status | jq -r '.myID')"
    devices="$(api GET /config/devices)"
    folders="$(api GET /config/folders)"
    echo "$devices" | jq -r '.[].deviceID' | while read -r dev; do
        [[ "$dev" == "$my_id" ]] && continue
        refs="$(echo "$folders" | jq --arg d "$dev" '[.[] | .devices[]? | select(.deviceID==$d)] | length')"
        if [[ "$refs" == "0" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                printf '%s[DRY]%s would remove unused device %s\n' "$C_CYAN" "$C_RESET" "${dev:0:7}…"
            else
                api DELETE "/config/devices/${dev}" >/dev/null && ok "removed unused device ${dev:0:7}…"
            fi
        fi
    done
}

ids_for_user() {
    # Echo folder ids belonging to a given username ("(no username)" => bare).
    local target="$1"
    retrosync_folders | jq -r '.id' | awk -v pre="${FOLDER_ID_PREFIX}-" -v want="$target" '
        {
            id=$0; key=id; sub("^" pre, "", key)
            n=split(key, parts, "-"); scope0=parts[1]
            if (scope0=="roms"||scope0=="bios"||scope0=="save"||scope0=="rd"||scope0=="rb"||scope0=="custom") u="(no username)"; else u=parts[1]
            if (u==want) print id
        }'
}

# ── menu actions ─────────────────────────────────────────────────────────────
show_all() {
    echo; hr; printf '%sAll RetroSync folders on the NAS%s\n' "$C_BOLD" "$C_RESET"; hr
    local any=0 line id path
    while IFS= read -r line; do
        any=1
        id="$(echo "$line" | jq -r '.id')"
        path="$(echo "$line" | jq -r '.path')"
        printf '  %-36s %s\n' "$id" "$path"
    done < <(retrosync_folders)
    [[ $any -eq 0 ]] && info "No retrosync-* folders configured."
}

remove_user() {
    echo
    local users; users="$(list_users)"
    [[ -z "$users" ]] && { info "No RetroSync users found."; return 0; }
    local -a names=() counts=()
    while IFS=$'\t' read -r u c; do names+=("$u"); counts+=("$c"); done <<< "$users"
    echo "Users:"; local i
    for ((i=0; i<${#names[@]}; i++)); do printf '    [%d] %-24s (%s folder(s))\n' "$((i+1))" "${names[i]}" "${counts[i]}"; done
    local sel; sel="$(prompt "Remove which user (number, blank to cancel)")"
    [[ -z "$sel" ]] && return 0
    [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#names[@]} )) || { warn "Invalid choice."; return 0; }
    local user="${names[$((sel-1))]}"
    local -a ids=(); while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(ids_for_user "$user")
    echo; warn "About to remove ${#ids[@]} folder config(s) for user '${user}':"
    printf '    %s\n' "${ids[@]}"
    echo
    if prompt_yn "Proceed? (configs only; data files are left untouched)" "n"; then
        local id; for id in "${ids[@]}"; do delete_folder "$id"; done
        prune_orphan_devices
        echo; info "Done. If you also want the DATA gone, delete that user's directory on the NAS."
    fi
}

remove_folders() {
    echo
    local -a ids=() line id; while IFS= read -r line; do id="$(echo "$line" | jq -r '.id')"; ids+=("$id"); done < <(retrosync_folders)
    (( ${#ids[@]} == 0 )) && { info "No retrosync-* folders configured."; return 0; }
    local i; for ((i=0; i<${#ids[@]}; i++)); do printf '    [%d] %s\n' "$((i+1))" "${ids[i]}"; done
    echo "Enter numbers to remove, space-separated (e.g. '1 3 4'), blank to cancel:"
    local sel; sel="$(prompt "Remove")"
    [[ -z "$sel" ]] && return 0
    local -a chosen=() n; for n in $sel; do [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#ids[@]} )) && chosen+=("${ids[$((n-1))]}"); done
    (( ${#chosen[@]} == 0 )) && { warn "Nothing valid selected."; return 0; }
    echo; warn "Will remove:"; printf '    %s\n' "${chosen[@]}"; echo
    if prompt_yn "Proceed?" "n"; then local id; for id in "${chosen[@]}"; do delete_folder "$id"; done; prune_orphan_devices; fi
}

wipe_all() {
    echo
    local -a ids=() line id; while IFS= read -r line; do id="$(echo "$line" | jq -r '.id')"; ids+=("$id"); done < <(retrosync_folders)
    (( ${#ids[@]} == 0 )) && { info "No retrosync-* folders configured."; return 0; }
    warn "This removes ALL ${#ids[@]} retrosync-* folder config(s) from the NAS Syncthing."
    warn "Data files are NOT deleted. This cannot be undone (you'd re-run setup to recreate)."
    echo
    local confirm; confirm="$(prompt "Type 'WIPE' to confirm")"
    [[ "$confirm" == "WIPE" ]] || { info "Cancelled."; return 0; }
    local id; for id in "${ids[@]}"; do delete_folder "$id"; done
    prune_orphan_devices
}

main() {
    printf '%sRetroSync reset / cleanup%s' "$C_BOLD" "$C_RESET"
    [[ $DRY_RUN -eq 1 ]] && printf '  %s(dry run — no changes)%s' "$C_CYAN" "$C_RESET"
    printf '\n'
    connect
    while true; do
        echo; hr
        echo "  [1] Show all RetroSync folders on the NAS"
        echo "  [2] Remove a user (all their folders)"
        echo "  [3] Remove specific folders"
        echo "  [4] Wipe ALL RetroSync folders (fresh start)"
        echo "  [5] Prune unused device pairings"
        echo "  [6] Exit"
        hr
        case "$(prompt "Choice" "1")" in
            1) show_all ;;
            2) remove_user ;;
            3) remove_folders ;;
            4) wipe_all ;;
            5) prune_orphan_devices ;;
            6) exit 0 ;;
            *) warn "Pick 1–6." ;;
        esac
    done
}
main "$@"
