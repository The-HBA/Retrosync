#!/usr/bin/env bash
# retrosync-setup.sh — Configure Syncthing for retro-gaming sync between a
# client device and a central NAS hub via the Syncthing REST API.
#
# Supports: RetroDECK on Linux (including SteamOS / Bazzite), and a "custom
# locations" mode where the user enters absolute paths manually for each
# thing to sync (works with any frontend or no frontend at all).
# Project: https://github.com/<owner>/retrosync
# License: MIT

# POSIX-safe sanity check: the script uses bashisms (arrays, [[ ]], BASH_REMATCH,
# `set -o pipefail`, etc.) throughout. If invoked via `sh retrosync-setup.sh` on
# a system where /bin/sh is dash/ash/etc., bail out with a clear message instead
# of failing on a cryptic syntax error.
if [ -z "${BASH_VERSION:-}" ]; then
    printf 'retrosync-setup.sh requires bash, not sh/dash.\n' >&2
    printf 'Run it as one of:\n  bash %s\n  ./%s   (after: chmod +x %s)\n' \
        "$0" "$(basename "$0")" "$(basename "$0")" >&2
    exit 1
fi

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 1. Banner & version
# ─────────────────────────────────────────────────────────────────────────────
readonly RETROSYNC_VERSION="0.3.0"
readonly RETROSYNC_NAME="RetroSync"
readonly FOLDER_ID_PREFIX="retrosync"

# ─────────────────────────────────────────────────────────────────────────────
# 2. CLI flag parsing
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=0
VERBOSE=0
NO_COLOR=0
PROFILE_PATH=""

print_help() {
    cat <<EOF
${RETROSYNC_NAME} ${RETROSYNC_VERSION}

Configure Syncthing on this device and on your NAS to sync ROMs, BIOS,
saves, save states, and ES-DE metadata.

Usage:
  $(basename "$0") [options]

Options:
  --dry-run         Print every action without making API calls or changes.
  --verbose         Print every API request URL, body, and response.
  --no-color        Disable ANSI colors in output.
  --profile PATH    Use a custom profile file (default: ~/.config/retrosync/profile.json)
  -h, --help        Show this help and exit.
  -V, --version     Show version and exit.

Prerequisites:
  - Syncthing installed and started at least once on this device AND your NAS.
  - One empty top-level directory created on your NAS (e.g. /mnt/tank/emulation).
  - Your NAS Syncthing API key (NAS web UI → Actions → Settings → API Key).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --verbose)    VERBOSE=1; shift ;;
        --no-color)   NO_COLOR=1; shift ;;
        --profile)    PROFILE_PATH="${2:-}"; shift 2 ;;
        -h|--help)    print_help; exit 0 ;;
        -V|--version) echo "${RETROSYNC_NAME} ${RETROSYNC_VERSION}"; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage." >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# 3. Universal constants — Syncthing config locations and API
# ─────────────────────────────────────────────────────────────────────────────
# Syncthing config.xml candidate paths on Linux (XDG state primary, legacy fallback).
# Source: consols-Info.json + perplexity research.
SYNCTHING_CONFIG_CANDIDATES=(
    "${XDG_STATE_HOME:-$HOME/.local/state}/syncthing/config.xml"
    "$HOME/.config/syncthing/config.xml"
)

readonly SYNCTHING_LOCAL_DEFAULT="http://localhost:8384"
readonly DEFAULT_PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/retrosync"
readonly DEFAULT_PROFILE_FILE="${DEFAULT_PROFILE_DIR}/profile.json"
readonly NAS_FOLDER_POLL_TIMEOUT=15
readonly NAS_FOLDER_POLL_INTERVAL=3

# ─────────────────────────────────────────────────────────────────────────────
# 4. Frontend definitions — RetroDECK (Linux Flatpak)
# ─────────────────────────────────────────────────────────────────────────────
# Paths verified against captured RetroDECK directory tree
# (RetroDECK Flatpak sandbox: ~/.var/app/net.retrodeck.retrodeck/).
#
# RetroDECK has TWO valid path conventions for user data:
#   1. The user-facing data dir at ~/retrodeck/ (created by RetroDECK first-launch)
#   2. The Flatpak sandbox at ~/.var/app/net.retrodeck.retrodeck/
# We probe ~/retrodeck/ first, then parse retrodeck.cfg if present, then fall
# back to prompting.
readonly RETRODECK_SANDBOX="$HOME/.var/app/net.retrodeck.retrodeck"
readonly RETRODECK_USER_DATA="$HOME/retrodeck"
readonly RETRODECK_CONFIG_FILE="${RETRODECK_SANDBOX}/config/retrodeck/retrodeck.cfg"

# Subpaths relative to RetroDECK user-data root (e.g. ~/retrodeck/)
readonly RD_ROMS_SUB="roms"
readonly RD_BIOS_SUB="bios"
readonly RD_SAVES_SUB="saves"
readonly RD_STATES_SUB="states"
readonly RD_GAMELISTS_SUB="ES-DE/gamelists"
readonly RD_MEDIA_SUB="ES-DE/downloaded_media"

# Per-emulator save subpaths.
#
# RetroDECK keeps save data under <user-data-dir>/saves/<console>/<emulator>/
# for standalone emulators. The sandbox's config/ tree holds emulator
# *configurations*, not saves, and is mostly empty for save data. Some
# emulators (Dolphin, Cemu) historically also wrote data under the sandbox
# but RetroDECK has migrated them to the user-data dir; the sandbox paths
# are kept as fallbacks for older RetroDECK installs.
#
# Format: "label|console_id|user-data-relative-path|sandbox-relative-fallback|notes"
#
# RetroArch (libretro) loose .srm saves are NOT listed here. They live
# directly at <user-data-dir>/saves/<rom-name>/<rom-name>.srm (mixed with
# the per-console subfolders), with no clean way to capture them as a
# distinct Syncthing folder without overlapping the standalone-emulator
# entries. If you want those synced too, add a Syncthing folder manually
# for ~/retrodeck/saves with .stignore patterns excluding the per-console
# subdirs.
RETRODECK_SAVE_LOCATIONS=(
    # Sony
    "PCSX2 (PS2)|ps2|saves/ps2/pcsx2/memcards|config/PCSX2/memcards|PS2 memory cards"
    "DuckStation (PS1)|ps1|saves/psx/duckstation/memcards|config/duckstation/memcards|PS1 standalone memory cards"
    "RPCS3 savedata (PS3)|ps3|saves/ps3/rpcs3|config/rpcs3/dev_hdd0/home/00000001/savedata|PS3 game saves (RetroDECK flattens dev_hdd0/home/00000001/savedata into saves/ps3/rpcs3)"
    "RPCS3 trophy (PS3)|ps3-trophy|storage/rpcs3/dev_hdd0/home/00000001/trophy|config/rpcs3/dev_hdd0/home/00000001/trophy|PS3 trophies (live under storage/, not saves/)"
    "PPSSPP standalone (PSP)|psp|saves/PSP/PPSSPP-SA|config/ppsspp/PSP/SAVEDATA|PSP standalone saves"
    "Vita3K (PSVita)|psvita|saves/psvita/vita3k|data/Vita3K|PSVita saves"
    # Nintendo
    "Dolphin GC|gamecube|saves/gc/dolphin|data/dolphin-emu/GC|GameCube memory cards (region-organized: EU/US/JP)"
    "Dolphin Wii NAND|wii|saves/wii/dolphin|data/dolphin-emu/Wii|Full Wii NAND incl. Miis (sys/ ticket/ title/)"
    "PrimeHack GC|gamecube-primehack|saves/gc/primehack|data/primehack/GC|Metroid Prime fork of Dolphin - GC saves"
    "PrimeHack Wii|wii-primehack|saves/wii/primehack|data/primehack/Wii|Metroid Prime fork of Dolphin - Wii saves"
    "Cemu (Wii U)|wiiu|saves/wiiu/cemu|data/Cemu|Cemu user data"
    "RyuBing (Switch)|switch|saves/switch/ryubing|config/Ryujinx/bis/user|Switch saves (RyuBing - the active Ryujinx fork after Ryujinx was discontinued)"
    "Azahar (3DS)|n3ds|saves/n3ds/azahar|data/azahar-emu|3DS NAND + SD card (Azahar - Citra fork after takedown)"
    "melonDS (NDS)|nds|saves/nds/melonds|config/melonDS|NDS standalone saves"
    # Sega / Microsoft / others
    "Flycast VMU (Dreamcast)|dreamcast|saves/dreamcast/flycast/vmu|config/flycast/vmu|Dreamcast VMU"
    "xemu (Xbox)|xbox|saves/xbox/xemu|data/xemu|Original Xbox saves"
    "MAME standalone|mame|saves/mame-sa|config/mame|MAME nvram/diff/hiscore"
    "Ruffle (Flash)|flash|saves/flash/ruffle|data/ruffle|Ruffle saved games"
)

# ─────────────────────────────────────────────────────────────────────────────
# 4b. Custom-mode state — paths supplied by the user instead of a frontend layout
# ─────────────────────────────────────────────────────────────────────────────
# In custom mode the user enters an absolute path for each thing they want to
# sync (blank = skip). Scope keys `roms` and `bios` stay bare so a custom-mode
# device can share those Syncthing folders with a RetroDECK device on the same
# NAS. States/gamelists/media use `custom-*` keys because their on-disk layout
# is unknown and almost certainly won't match RetroDECK's. Per-emulator saves
# reuse the same `saves/<console_id>` NAS subpath convention as RetroDECK so
# format-compatible save folders (PCSX2 memcards, DuckStation memcards, etc.)
# can cross-sync between custom and RetroDECK devices.
CUSTOM_ROMS_PATH=""
CUSTOM_BIOS_PATH=""
CUSTOM_STATES_PATH=""
CUSTOM_GAMELISTS_PATH=""
CUSTOM_MEDIA_PATH=""
# Per-emulator saves in custom mode. Each entry: "console_id|absolute_path".
CUSTOM_SAVE_PATHS=()

# RetroArch save subdirectory names (under retroarch/saves/) by core.
# These are the directory names RetroArch creates per core for SRAM/memory cards.
# Source: perplexity research, RETROARCH CORE NAME REFERENCE.
RETROARCH_CORE_DIRS=(
    "Mesen|nes"
    "FCEUmm|nes"
    "Nestopia|nes"
    "Snes9x|snes"
    "bsnes|snes"
    "Mupen64Plus-Next|n64"
    "Genesis Plus GX|genesis"
    "PicoDrive|sega32x"
    "Beetle Saturn|saturn"
    "Beetle PCE|pcengine"
    "PPSSPP|psp"
    "SwanStation|ps1"
    "PCSX-ReARMed|ps1"
    "FinalBurn Neo|neogeo"
    "PUAE|amiga"
    "Stella|atari2600"
    "ProSystem|atari7800"
    "Beetle Lynx|lynx"
    "Opera|3do"
    "DOSBox Pure|dos"
    "Citra|n3ds"
    "melonDS DS|nds"
    "SameBoy|gb"
    "Gambatte|gb"
    "mGBA|gba"
    "Flycast|dreamcast"
)

# ─────────────────────────────────────────────────────────────────────────────
# 5. Console metadata — large-rom warnings, save incompatibilities
# ─────────────────────────────────────────────────────────────────────────────
# Source: consols-Info.json large_rom_consoles + perplexity Section A.
# Format: "console_id|typical_size|warning_message"
LARGE_ROM_CONSOLES=(
    "ps3|20-50GB per game|very large"
    "switch|5-15GB per game|large"
    "ps2|2-8GB per game|medium-large"
    "wii|4-8GB per game|large"
    "wiiu|10-25GB per game|large"
    "xbox|4-8GB per game|large"
    "xbox360|8-15GB per game|large"
)

# Pairs of save formats that are NOT cross-compatible.
# Source: perplexity KNOWN SAVE INCOMPATIBILITIES.
# Format: "console|emulator_a|emulator_b|reason"
KNOWN_INCOMPATIBLE_SAVES=(
    "ps1|DuckStation/SwanStation (.mcd)|PCSX-ReARMed (.srm)|Different memory-card encoding"
    "ps2|PCSX2 (.ps2)|RetroArch PCSX2 core (.srm)|Different format"
    "ps3|RPCS3|other|RPCS3 saves are not portable to other PS3 emulators"
)

# ─────────────────────────────────────────────────────────────────────────────
# 6. Output helpers
# ─────────────────────────────────────────────────────────────────────────────
# Detect color support: stdout is a TTY, terminal supports >=8 colors,
# and --no-color was not passed.
if [[ $NO_COLOR -eq 0 ]] && [[ -t 1 ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_ORANGE=$'\033[38;5;208m'
    readonly C_BLUE=$'\033[34m'
    readonly C_CYAN=$'\033[36m'
    readonly C_GREY=$'\033[90m'
else
    readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_ORANGE="" C_BLUE="" C_CYAN="" C_GREY=""
fi

success() { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info()    { printf '%sℹ%s %s\n' "$C_BLUE"  "$C_RESET" "$*"; }
warn()    { printf '%s⚠%s %s\n' "$C_ORANGE" "$C_RESET" "$*" >&2; }
err()     { printf '%s✗%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
prereq()  {
    # Yellow informational block. Use for "PREREQUISITE" notes and other
    # explanatory passages the user must read but isn't an alert.
    printf '%s' "$C_YELLOW"
    printf '%s\n' "$@"
    printf '%s' "$C_RESET"
}
fatal()   { err "$@"; exit 1; }
verbose() { [[ $VERBOSE -eq 1 ]] && printf '%s[verbose]%s %s\n' "$C_GREY" "$C_RESET" "$*" >&2 || true; }
dry()     { printf '%s[DRY RUN]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
hr()      { printf '%s%s%s\n' "$C_GREY" "═══════════════════════════════════════════════════════════" "$C_RESET"; }

prompt() {
    # prompt "Question" "default" -> echoes user response (or default if empty)
    local question="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$question" "$default" >&2
    else
        printf '%s: ' "$question" >&2
    fi
    IFS= read -r reply
    echo "${reply:-$default}"
}

prompt_yn() {
    # prompt_yn "Question" "y|n default" -> returns 0 for yes, 1 for no
    local question="$1" default="${2:-n}" reply
    while true; do
        printf '%s [%s/%s]: ' "$question" \
            "$([[ "$default" == "y" ]] && echo Y || echo y)" \
            "$([[ "$default" == "n" ]] && echo N || echo n)" >&2
        IFS= read -r reply
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     printf '  Please answer y or n.\n' >&2 ;;
        esac
    done
}

prompt_secret() {
    # prompt_secret "Question" -> echoes user response, no echo to terminal
    local question="$1" reply
    printf '%s: ' "$question" >&2
    IFS= read -rs reply
    printf '\n' >&2
    echo "$reply"
}

# ─────────────────────────────────────────────────────────────────────────────
# API key storage (libsecret | openssl-machine | plaintext | prompt)
#
# Linux equivalents to Windows DPAPI for "encrypt at rest, decryptable only
# by me on this machine":
#
# - libsecret:       Encrypted in the desktop's keyring (GNOME Keyring,
#                    KWallet, etc.) via `secret-tool`. Strongest option but
#                    needs a running keyring agent — fails on headless boxes
#                    and Steam Deck Game Mode.
# - openssl-machine: Encrypted with AES-256-CBC using a key derived from
#                    /etc/machine-id + the current UID. Same "this user on
#                    this machine only" guarantee as Windows DPAPI. Works on
#                    any system with openssl + a machine-id file, which is
#                    basically every modern Linux.
# - plaintext:       Raw key in profile.json. File is chmod 600 on save.
# - prompt:          Nothing stored. Re-prompted every run.
# ─────────────────────────────────────────────────────────────────────────────

libsecret_available() {
    # secret-tool installed AND a keyring is reachable. We test by attempting
    # a no-op lookup; if the daemon isn't running we get a non-zero exit even
    # though the binary is present.
    command -v secret-tool >/dev/null 2>&1 || return 1
    secret-tool lookup service retrosync key __probe >/dev/null 2>&1
    local rc=$?
    # rc=0  -> entry exists (very unlikely on probe), works
    # rc=1  -> entry not found, but daemon reachable, works
    # rc>=2 -> daemon issue
    [[ $rc -le 1 ]]
}

openssl_machine_key() {
    # Derive a 64-char hex key from the machine-id + current UID. Same idea
    # as Windows DPAPI: the key is bound to "this user on this machine."
    # /etc/machine-id is set by systemd at install time; the dbus path is a
    # legacy fallback some distros still populate.
    local machine_id=""
    if [[ -r /etc/machine-id ]]; then
        machine_id="$(cat /etc/machine-id 2>/dev/null)"
    elif [[ -r /var/lib/dbus/machine-id ]]; then
        machine_id="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
    fi
    [[ -z "$machine_id" ]] && return 1
    printf '%s|%s|retrosync' "$machine_id" "$(id -u)" \
        | sha256sum | awk '{print $1}'
}

openssl_machine_available() {
    command -v openssl >/dev/null 2>&1 || return 1
    openssl_machine_key >/dev/null 2>&1
}

openssl_machine_encrypt() {
    local plaintext="$1" key
    key="$(openssl_machine_key)" || return 1
    # -A: base64 without line wrapping; safe for storage in a single JSON field.
    printf '%s' "$plaintext" \
        | openssl enc -aes-256-cbc -salt -pbkdf2 \
            -pass pass:"$key" -base64 -A 2>/dev/null
}

openssl_machine_decrypt() {
    local ciphertext="$1" key
    key="$(openssl_machine_key)" || return 1
    printf '%s' "$ciphertext" \
        | openssl enc -aes-256-cbc -d -salt -pbkdf2 \
            -pass pass:"$key" -base64 -A 2>/dev/null
}

read_api_key_storage_mode() {
    # Build the storage-mode menu dynamically. Stronger options are listed
    # first so the default ("1") is whatever encryption is available. The
    # menu prints to stderr — only the chosen mode string goes to stdout,
    # since this function is called via $(...) and we don't want the menu
    # text captured into the return value.
    local has_libsecret=0 has_openssl=0
    libsecret_available && has_libsecret=1
    openssl_machine_available && has_openssl=1

    local -a modes labels descs
    if (( has_libsecret == 1 )); then
        modes+=("libsecret")
        labels+=("System keyring (libsecret)")
        descs+=("Encrypted by your desktop's keyring (GNOME Keyring,
        KWallet, etc.). profile.json holds no key material.
        Strongest option, but needs a desktop session.")
    fi
    if (( has_openssl == 1 )); then
        modes+=("openssl-machine")
        labels+=("Encrypted with machine-bound key (openssl)")
        descs+=("AES-256 encrypted using a key derived from your
        machine-id and user UID. Decryptable only by you on
        this machine. No desktop session needed; works on
        headless boxes and Steam Deck Game Mode.")
    fi
    modes+=("plaintext")
    labels+=("Plaintext in profile.json")
    descs+=("Simple. The file will be chmod 600 (your user only).
        Risk: if you upload, commit, or share the file by
        accident, the key is visible.")
    modes+=("prompt")
    labels+=("Don't store - prompt on every run")
    descs+=("Most secure. Re-typed each time.")

    {
        echo
        echo "How should the NAS Syncthing API key be stored?"
        echo
        local i
        for i in "${!modes[@]}"; do
            local n=$((i+1))
            local recommended=""
            (( i == 0 )) && recommended=" (recommended)"
            printf '    [%d] %s%s\n' "$n" "${labels[$i]}" "$recommended"
            # Print the (multi-line) description with indentation
            printf '        %s\n' "${descs[$i]}" | sed '2,$s/^        //'
            echo
        done
        if (( has_libsecret == 0 )); then
            echo "  (libsecret/system-keyring option is hidden because either"
            echo "   'secret-tool' isn't installed or no keyring agent is"
            echo "   running. Install libsecret-tools / libsecret on your"
            echo "   distro to enable that option.)"
            echo
        fi
    } >&2

    while true; do
        local choice
        choice="$(prompt "Choice" "1")"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#modes[@]} )); then
            echo "${modes[$((choice-1))]}"
            return
        fi
        warn "Pick a number between 1 and ${#modes[@]}."
    done
}

protect_api_key_for_storage() {
    # Echo the value that should be written to profile.json's api_key field.
    # For libsecret we also write to the keyring as a side effect.
    local mode="$1" key="$2"
    case "$mode" in
        plaintext)
            echo "$key"
            ;;
        prompt)
            echo ""
            ;;
        libsecret)
            if printf '%s' "$key" | secret-tool store \
                --label="RetroSync NAS API key" \
                service retrosync key api-key >/dev/null 2>&1; then
                # profile.json holds an empty api_key with mode=libsecret;
                # the actual secret lives in the keyring.
                echo ""
            else
                warn "Couldn't write to keyring; falling back to plaintext storage."
                echo "$key"
            fi
            ;;
        openssl-machine)
            local enc
            if enc="$(openssl_machine_encrypt "$key")" && [[ -n "$enc" ]]; then
                echo "$enc"
            else
                warn "Machine-key encryption failed; falling back to plaintext."
                echo "$key"
            fi
            ;;
        *)
            echo "$key"
            ;;
    esac
}

unprotect_api_key_from_storage() {
    # Recover the raw key for use in this session.
    local mode="$1" stored="$2" key
    case "$mode" in
        plaintext)
            echo "$stored"
            ;;
        prompt)
            key="$(prompt_secret "NAS Syncthing API key")"
            echo "$key"
            ;;
        libsecret)
            if key="$(secret-tool lookup service retrosync key api-key 2>/dev/null)" && [[ -n "$key" ]]; then
                echo "$key"
            else
                warn "Stored key not found in keyring (was the keyring agent" >&2
                warn "running, or did the entry get cleared?). Re-prompting." >&2
                key="$(prompt_secret "NAS Syncthing API key")"
                echo "$key"
            fi
            ;;
        openssl-machine)
            if key="$(openssl_machine_decrypt "$stored")" && [[ -n "$key" ]]; then
                echo "$key"
            else
                warn "Couldn't decrypt the stored API key (was the profile" >&2
                warn "copied from another user or machine?). Re-prompting." >&2
                key="$(prompt_secret "NAS Syncthing API key")"
                echo "$key"
            fi
            ;;
        *)
            echo "$stored"
            ;;
    esac
}

clear_api_key_from_keyring() {
    # Best-effort: remove the keyring entry. Used by [3] Remove.
    secret-tool clear service retrosync key api-key >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Syncthing API wrappers
# ─────────────────────────────────────────────────────────────────────────────
# All API calls flow through these two wrappers so auth, error handling,
# and verbose logging happen in one place.
#
# Globals consumed: SYNCTHING_LOCAL_URL, SYNCTHING_LOCAL_KEY,
#                   SYNCTHING_NAS_URL,   SYNCTHING_NAS_KEY
#
# Usage: syncthing_request <local|nas> <METHOD> <path> [json_body]
# Echoes: response body
# Returns: 0 on 2xx, non-zero with stderr error on failure.

syncthing_request() {
    local target="$1" method="$2" path="$3" body="${4:-}"
    local url key tmp_body http_status response

    case "$target" in
        local) url="$SYNCTHING_LOCAL_URL"; key="$SYNCTHING_LOCAL_KEY" ;;
        nas)   url="$SYNCTHING_NAS_URL";   key="$SYNCTHING_NAS_KEY"   ;;
        *) err "syncthing_request: unknown target '$target'"; return 2 ;;
    esac

    local full_url="${url}${path}"
    verbose "${method} ${full_url}"
    [[ -n "$body" ]] && verbose "  body: ${body}"

    if [[ $DRY_RUN -eq 1 ]] && [[ "$method" != "GET" ]]; then
        dry "${method} ${full_url}${body:+ (body: ${body:0:80}${#body} bytes)}"
        # Return an empty-but-valid JSON object so callers can keep going.
        echo "{}"
        return 0
    fi

    tmp_body="$(mktemp)"
    REGISTERED_TMPFILES+=("$tmp_body")

    local curl_args=(-sS -X "$method"
        -H "X-API-Key: ${key}"
        -H "Content-Type: application/json"
        -w '\n__HTTP_STATUS__:%{http_code}'
        -o "$tmp_body"
        --connect-timeout 10
        --max-time 60)

    if [[ -n "$body" ]]; then
        curl_args+=(--data-binary "$body")
    fi

    response="$(curl "${curl_args[@]}" "$full_url" 2>&1)" || {
        err "Network error calling ${full_url}: ${response}"
        return 1
    }

    http_status="${response##*__HTTP_STATUS__:}"
    local response_body
    response_body="$(cat "$tmp_body")"

    verbose "  status: ${http_status}"
    [[ -n "$response_body" ]] && verbose "  response: ${response_body:0:200}"

    if [[ "$http_status" =~ ^2 ]]; then
        echo "$response_body"
        return 0
    else
        err "Syncthing API ${method} ${path} failed (HTTP ${http_status})"
        [[ -n "$response_body" ]] && err "  response: ${response_body}"
        return 1
    fi
}

st_get()    { syncthing_request "$1" GET    "$2"; }
st_post()   { syncthing_request "$1" POST   "$2" "$3"; }
st_put()    { syncthing_request "$1" PUT    "$2" "$3"; }
st_delete() { syncthing_request "$1" DELETE "$2"; }

# Cleanup tmpfiles on exit.
REGISTERED_TMPFILES=()
cleanup() {
    local f
    for f in "${REGISTERED_TMPFILES[@]:-}"; do
        [[ -n "$f" ]] && [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 8. Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────

check_bash_version() {
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        fatal "${RETROSYNC_NAME} requires Bash 4.0 or later (you have ${BASH_VERSION})."
    fi
}

check_required_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq   >/dev/null 2>&1 || missing+=(jq)

    if (( ${#missing[@]} > 0 )); then
        err "Missing required tool(s): ${missing[*]}"
        cat >&2 <<'EOF'

Install instructions:

  SteamOS:
    sudo steamos-readonly disable
    sudo pacman -Sy curl jq
    sudo steamos-readonly enable

  Bazzite / Fedora Atomic:
    rpm-ostree install curl jq
    systemctl reboot

  Ubuntu / Debian:
    sudo apt install curl jq

  Arch:
    sudo pacman -S curl jq
EOF
        exit 1
    fi
}

extract_local_syncthing_info() {
    # Walk SYNCTHING_CONFIG_CANDIDATES; on the first readable config.xml,
    # extract the API key and the GUI <address> (port could be customised).
    # Echoes "<api_key>|<gui_address>" on success, returns 0.
    # Returns 1 if no config was found.
    local cfg key addr
    for cfg in "${SYNCTHING_CONFIG_CANDIDATES[@]}"; do
        if [[ -r "$cfg" ]]; then
            verbose "Reading Syncthing config: $cfg"
            key="$(grep -oP '(?<=<apikey>)[^<]+' "$cfg" 2>/dev/null | head -n1 || true)"
            # Scope the <address> grep to the <gui>...</gui> block, since the
            # config has other <address> elements (listen addresses, etc.).
            addr="$(awk '/<gui[ >]/,/<\/gui>/' "$cfg" 2>/dev/null \
                | grep -oP '(?<=<address>)[^<]+' | head -n1 || true)"
            if [[ -n "$key" ]]; then
                echo "${key}|${addr}"
                return 0
            fi
        fi
    done
    return 1
}

prompt_local_syncthing_manual() {
    # Fallback when auto-detect can't find config.xml. Asks for URL + API
    # key directly. Used for Flatpak / portable / custom-port installs.
    echo
    echo "You can still proceed by entering the connection details manually."
    echo "Open Syncthing's Web UI (system tray icon or however you launch it)"
    echo "and grab the address bar's URL + Actions -> Settings -> API Key."
    echo

    local manual_url
    manual_url="$(prompt "Local Syncthing Web UI address" "localhost:8384")"
    if [[ "$manual_url" =~ ^https?:// ]]; then
        SYNCTHING_LOCAL_URL="${manual_url%/}/rest"
    else
        SYNCTHING_LOCAL_URL="http://${manual_url%/}/rest"
    fi

    SYNCTHING_LOCAL_KEY="$(prompt_secret "Local Syncthing API key")"
    if [[ -z "$SYNCTHING_LOCAL_KEY" ]]; then
        fatal "API key required. Aborting."
    fi
}

preflight_local_syncthing() {
    info "Checking local Syncthing…"
    SYNCTHING_LOCAL_URL=""
    SYNCTHING_LOCAL_KEY=""

    # Try to read config.xml from the standard XDG paths.
    local info_str
    if info_str="$(extract_local_syncthing_info)"; then
        local addr
        SYNCTHING_LOCAL_KEY="${info_str%%|*}"
        addr="${info_str#*|}"
        if [[ -n "$addr" ]]; then
            # Both 0.0.0.0 and the explicit 127.0.0.1 are listen addresses;
            # for talking to the local API "localhost" is friendlier.
            addr="${addr//0.0.0.0/localhost}"
            SYNCTHING_LOCAL_URL="http://${addr}/rest"
        else
            SYNCTHING_LOCAL_URL="${SYNCTHING_LOCAL_DEFAULT}/rest"
        fi
    else
        # Auto-detect failed — fall back to manual entry instead of
        # hardcoding more paths (Flatpak sandboxes, AppImage spots, etc.).
        warn "Could not find Syncthing config.xml in:"
        local p
        for p in "${SYNCTHING_CONFIG_CANDIDATES[@]}"; do
            warn "  - $p"
        done
        echo
        echo "Common reasons:"
        echo "  - Syncthing hasn't been started yet on this machine (the"
        echo "    config.xml is created on first launch)."
        echo "  - You're using a Flatpak / AppImage / portable install whose"
        echo "    config lives elsewhere (e.g. Syncthingy keeps it inside"
        echo "    ~/.var/app/com.github.zocker_160.SyncThingy/...)."
        echo "  - The GUI port was changed from 8384."
        prompt_local_syncthing_manual
    fi

    # Verify connectivity. On failure, let the user fix the URL or key
    # without restarting the script.
    while true; do
        if st_get local "/system/ping" >/dev/null 2>&1; then
            success "Local Syncthing reachable at ${SYNCTHING_LOCAL_URL%/rest}"
            return 0
        fi
        echo
        warn "Local Syncthing not responding at ${SYNCTHING_LOCAL_URL%/rest}"
        echo "  Check that:"
        echo "    - Syncthing is running (system tray icon, or"
        echo "      'systemctl --user status syncthing.service')"
        echo "    - The URL above matches the address shown in Syncthing's Web UI"
        echo "    - The API key matches Web UI -> Actions -> Settings -> API Key"
        echo
        if ! prompt_yn "Retry with different connection details?" "y"; then
            fatal "Cancelled."
        fi
        local retry_url
        retry_url="$(prompt "Local Syncthing Web UI address" "${SYNCTHING_LOCAL_URL%/rest}")"
        if [[ "$retry_url" =~ ^https?:// ]]; then
            SYNCTHING_LOCAL_URL="${retry_url%/}/rest"
        else
            SYNCTHING_LOCAL_URL="http://${retry_url%/}/rest"
        fi
        if prompt_yn "Re-enter the API key too?" "n"; then
            SYNCTHING_LOCAL_KEY="$(prompt_secret "Local Syncthing API key")"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Profile load/save
# ─────────────────────────────────────────────────────────────────────────────

profile_file() {
    echo "${PROFILE_PATH:-$DEFAULT_PROFILE_FILE}"
}

profile_exists() {
    [[ -f "$(profile_file)" ]]
}

load_profile() {
    local file
    file="$(profile_file)"
    [[ -f "$file" ]] || return 1
    cat "$file"
}

save_profile() {
    local json="$1" file dir
    file="$(profile_file)"
    dir="$(dirname "$file")"

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "Would save profile to $file"
        return 0
    fi

    mkdir -p "$dir"
    # Backup any existing file first.
    [[ -f "$file" ]] && cp "$file" "${file}.bak"
    printf '%s\n' "$json" | jq '.' > "$file"
    # Lock down permissions: even with libsecret/prompt mode the file
    # contains things like the device IDs and paired NAS address; with
    # plaintext mode it contains the API key. Either way, no reason to
    # let other Linux accounts read it.
    chmod 600 "$file" 2>/dev/null || true
    [[ -f "${file}.bak" ]] && chmod 600 "${file}.bak" 2>/dev/null || true
    success "Profile saved: $file"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 1: profile detection
# ─────────────────────────────────────────────────────────────────────────────

step_profile_detection() {
    if ! profile_exists; then
        EXISTING_PROFILE=""
        return 0
    fi

    EXISTING_PROFILE="$(load_profile)"
    local frontend username nas_addr folder_count
    frontend="$(echo "$EXISTING_PROFILE" | jq -r '.frontend // "?"')"
    username="$(echo "$EXISTING_PROFILE" | jq -r '.username // ""')"
    nas_addr="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.address // "?"')"
    folder_count="$(echo "$EXISTING_PROFILE" | jq -r '.folders | length')"

    echo
    info "An existing ${RETROSYNC_NAME} profile was found for this device:"
    echo "    Frontend:  ${frontend}"
    if [[ -n "$username" ]]; then
        echo "    Username:  ${username} (multi-user)"
    else
        echo "    Mode:      single-user"
    fi
    echo "    NAS:       ${nas_addr}"
    echo "    Folders:   ${folder_count} configured"
    echo
    echo "    [1] Update — add or change folders (keeps existing config)"
    echo "    [2] Start fresh — delete profile and reconfigure"
    echo "    [3] Remove this device from sync (clean up before re-running)"
    echo "    [4] Exit"
    echo
    local choice
    choice="$(prompt "Choice" "1")"
    case "$choice" in
        1) PROFILE_MODE="update" ;;
        2)
            if prompt_yn "Really delete ${RETROSYNC_NAME} profile and reconfigure?" "n"; then
                [[ $DRY_RUN -eq 0 ]] && rm -f "$(profile_file)"
                EXISTING_PROFILE=""
                PROFILE_MODE="fresh"
            else
                exit 0
            fi
            ;;
        3) PROFILE_MODE="remove" ;;
        4) exit 0 ;;
        *) fatal "Invalid choice: $choice" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 2: frontend selection
# ─────────────────────────────────────────────────────────────────────────────

step_frontend_selection() {
    if [[ -n "${EXISTING_PROFILE:-}" ]]; then
        FRONTEND="$(echo "$EXISTING_PROFILE" | jq -r '.frontend')"
        FRONTEND_BASE="$(echo "$EXISTING_PROFILE" | jq -r '.frontend_base_path')"
        if [[ "$FRONTEND" == "custom" ]]; then
            info "Using saved frontend: custom locations"
            restore_custom_state_from_profile
        else
            info "Using saved frontend: ${FRONTEND} at ${FRONTEND_BASE}"
        fi
        return 0
    fi

    echo
    echo "Which retro gaming frontend are you using on this device?"
    echo
    echo "    [1] RetroDECK (Linux Flatpak)"
    echo "    [2] Custom locations  (manually enter the path for each thing to sync)"
    echo
    echo "  Pick [2] if you run any non-RetroDECK frontend on Linux (EmuDeck,"
    echo "  standalone ES-DE, Lutris, plain RetroArch, custom layouts) or if"
    echo "  your save folders live somewhere other than the default RetroDECK"
    echo "  layout. RetroBat users should use retrosync-setup.ps1 on Windows."
    echo
    local choice
    choice="$(prompt "Choice" "1")"
    case "$choice" in
        1) FRONTEND="retrodeck"; detect_retrodeck_base ;;
        2) FRONTEND="custom";    collect_custom_paths   ;;
        *) fatal "Invalid choice: $choice." ;;
    esac
}

# Detect the user-data root for RetroDECK by:
# 1. Checking the conventional ~/retrodeck/ shortcut
# 2. Parsing retrodeck.cfg for configured roms_folder
# 3. Falling back to the Flatpak sandbox itself
# 4. Asking the user to confirm or override
detect_retrodeck_base() {
    if [[ ! -d "$RETRODECK_SANDBOX" ]]; then
        warn "RetroDECK Flatpak sandbox not found at ${RETRODECK_SANDBOX}"
        warn "Is RetroDECK installed and has it been launched at least once?"
    fi

    local detected=""

    # retrodeck.cfg is the authoritative source if RetroDECK has run at
    # least once. Newer builds set rdhome=<absolute path>; older builds
    # set roms_folder=<rdhome>/roms. Parse cfg first so a user who pointed
    # RetroDECK at a non-default location (e.g. /home/me/Games/retrodeck)
    # gets it auto-detected instead of dropping back to ~/retrodeck.
    if [[ -f "$RETRODECK_CONFIG_FILE" ]]; then
        local rdhome roms_folder
        rdhome="$(grep -E '^rdhome=' "$RETRODECK_CONFIG_FILE" 2>/dev/null \
            | head -n1 | cut -d= -f2- || true)"
        if [[ -n "$rdhome" ]]; then
            detected="${rdhome%/}"
            verbose "Parsed retrodeck.cfg rdhome=${rdhome} → base=${detected}"
        else
            roms_folder="$(grep -E '^roms_folder=' "$RETRODECK_CONFIG_FILE" 2>/dev/null \
                | head -n1 | cut -d= -f2- || true)"
            if [[ -n "$roms_folder" ]]; then
                detected="${roms_folder%/roms}"
                detected="${detected%/}"
                verbose "Parsed retrodeck.cfg roms_folder=${roms_folder} → base=${detected}"
            fi
        fi
    fi

    # Fall back to ~/retrodeck if the cfg didn't yield anything.
    if [[ -z "$detected" ]] && [[ -d "$RETRODECK_USER_DATA" ]]; then
        detected="$RETRODECK_USER_DATA"
        verbose "Using default user-data dir: $detected"
    fi

    if [[ -z "$detected" ]]; then
        detected="$RETRODECK_USER_DATA"
        warn "Could not auto-detect RetroDECK data dir. Default: $detected"
        warn "(It may not exist yet — Syncthing will create it on first sync.)"
    fi

    echo
    FRONTEND_BASE="$(prompt "RetroDECK data directory" "$detected")"
    # Strip trailing slash so subsequent path joins don't end up with //.
    FRONTEND_BASE="${FRONTEND_BASE%/}"

    if [[ ! -d "$FRONTEND_BASE" ]]; then
        warn "Path does not exist yet: $FRONTEND_BASE"
        if ! prompt_yn "Continue anyway? (Syncthing will create it on first sync)" "y"; then
            fatal "Cancelled."
        fi
    fi
    success "Using RetroDECK base: $FRONTEND_BASE"
}

# Custom mode: ask the user for an absolute path per scope (blank = skip),
# then for an absolute path per known emulator's save folder (blank = skip).
# Populates the CUSTOM_*_PATH vars and CUSTOM_SAVE_PATHS used by the scope
# builder and saves picker.
collect_custom_paths() {
    echo
    echo "Custom locations mode."
    echo
    echo "Enter the absolute path for each thing you want to sync."
    echo "Leave a prompt blank to skip that entry. Examples:"
    echo "  /mnt/games/roms"
    echo "  $HOME/emulation/bios"
    echo
    info "Each path can point to anywhere — local drive, external drive,"
    info "network mount. Only entries you fill in will be synced."
    echo

    # Custom mode has no single root, so FRONTEND_BASE stays empty. The scope
    # builder emits absolute paths in the local_sub field and step_apply_all
    # detects that and skips the FRONTEND_BASE join.
    FRONTEND_BASE=""

    CUSTOM_ROMS_PATH="$(prompt      "Path to ROMs folder (blank to skip)"             "")"
    CUSTOM_BIOS_PATH="$(prompt      "Path to BIOS folder (blank to skip)"             "")"
    CUSTOM_STATES_PATH="$(prompt    "Path to save states folder (blank to skip)"      "")"
    CUSTOM_GAMELISTS_PATH="$(prompt "Path to ES-DE gamelists folder (blank to skip)"  "")"
    CUSTOM_MEDIA_PATH="$(prompt     "Path to ES-DE downloaded media (blank to skip)"  "")"

    # Strip trailing slashes so subsequent path joins don't end up with //.
    CUSTOM_ROMS_PATH="${CUSTOM_ROMS_PATH%/}"
    CUSTOM_BIOS_PATH="${CUSTOM_BIOS_PATH%/}"
    CUSTOM_STATES_PATH="${CUSTOM_STATES_PATH%/}"
    CUSTOM_GAMELISTS_PATH="${CUSTOM_GAMELISTS_PATH%/}"
    CUSTOM_MEDIA_PATH="${CUSTOM_MEDIA_PATH%/}"

    echo
    echo "Per-emulator save folders."
    echo "Enter the absolute path to each emulator's save directory."
    echo "Blank = skip that emulator."
    echo

    local entry label console_id _primary _sandbox _notes path
    for entry in "${RETRODECK_SAVE_LOCATIONS[@]}"; do
        IFS='|' read -r label console_id _primary _sandbox _notes <<< "$entry"
        path="$(prompt "  ${label}" "")"
        path="${path%/}"
        if [[ -n "$path" ]]; then
            CUSTOM_SAVE_PATHS+=("${console_id}|${path}")
        fi
    done

    local count=0 var
    for var in "$CUSTOM_ROMS_PATH" "$CUSTOM_BIOS_PATH" "$CUSTOM_STATES_PATH" \
               "$CUSTOM_GAMELISTS_PATH" "$CUSTOM_MEDIA_PATH"; do
        [[ -n "$var" ]] && count=$((count + 1))
    done
    count=$((count + ${#CUSTOM_SAVE_PATHS[@]}))

    if (( count == 0 )); then
        fatal "No paths entered — nothing to sync. Re-run and supply at least one path."
    fi

    echo
    success "Collected ${count} custom path(s)."
}

# Re-run with FRONTEND=custom: rebuild CUSTOM_* state from the saved
# folders[] so the rest of the flow doesn't re-prompt for paths.
restore_custom_state_from_profile() {
    local saved_user folders row id lp key console_id
    saved_user="$(echo "$EXISTING_PROFILE" | jq -r '.username // ""')"
    folders="$(echo "$EXISTING_PROFILE" | jq -c '.folders // []')"

    while IFS= read -r row; do
        id="$(echo "$row" | jq -r '.id')"
        lp="$(echo "$row" | jq -r '.local_path')"
        # Strip the universal "retrosync-" prefix.
        key="${id#${FOLDER_ID_PREFIX}-}"
        # Multi-user profiles also have the username prefix; drop that too.
        if [[ -n "$saved_user" ]] && [[ "$key" == "${saved_user}-"* ]]; then
            key="${key#${saved_user}-}"
        fi
        case "$key" in
            roms)             CUSTOM_ROMS_PATH="$lp" ;;
            bios)             CUSTOM_BIOS_PATH="$lp" ;;
            custom-states)    CUSTOM_STATES_PATH="$lp" ;;
            custom-gamelists) CUSTOM_GAMELISTS_PATH="$lp" ;;
            custom-media)     CUSTOM_MEDIA_PATH="$lp" ;;
            save-*)
                console_id="${key#save-}"
                CUSTOM_SAVE_PATHS+=("${console_id}|${lp}")
                ;;
        esac
    done < <(echo "$folders" | jq -c '.[]')
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 3: NAS layout (multi-user + username + base dir)
# ─────────────────────────────────────────────────────────────────────────────

MULTI_USER=0
USERNAME=""

folder_id_for() {
    local key="$1"
    if [[ $MULTI_USER -eq 1 ]]; then
        echo "${FOLDER_ID_PREFIX}-${USERNAME}-${key}"
    else
        echo "${FOLDER_ID_PREFIX}-${key}"
    fi
}

nas_user_root() {
    if [[ $MULTI_USER -eq 1 ]]; then
        echo "${NAS_BASE_DIR}/${USERNAME}"
    else
        echo "${NAS_BASE_DIR}"
    fi
}

step_nas_layout() {
    if [[ -n "${EXISTING_PROFILE:-}" ]]; then
        local saved_multi
        saved_multi="$(echo "$EXISTING_PROFILE" | jq -r '.multi_user // empty')"
        if [[ -z "$saved_multi" ]]; then
            # v0.1.0 profiles had no multi_user field; legacy behavior was always multi-user.
            local saved_user
            saved_user="$(echo "$EXISTING_PROFILE" | jq -r '.username // empty')"
            if [[ -n "$saved_user" ]]; then saved_multi="true"; else saved_multi="false"; fi
        fi
        if [[ "$saved_multi" == "true" ]]; then
            MULTI_USER=1
            USERNAME="$(echo "$EXISTING_PROFILE" | jq -r '.username')"
        else
            MULTI_USER=0
            USERNAME=""
        fi
        NAS_BASE_DIR="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.nas_base')"
        if [[ $MULTI_USER -eq 1 ]]; then
            info "Using saved layout: multi-user (username: ${USERNAME})"
        else
            info "Using saved layout: single-user"
        fi
        info "  NAS base: ${NAS_BASE_DIR}"
        return 0
    fi

    echo
    cat <<EOF
Will more than one person share this NAS for retro-gaming sync?

  [N] Single user (recommended for personal setups)
      Files go directly under your NAS base directory.
      Example with base = /Retrosync:
          /Retrosync/roms/<console>/...
          /Retrosync/saves/...
          /Retrosync/bios/...

  [Y] Multiple users (e.g. you and a partner share the NAS)
      Each person gets their own subfolder so saves stay separate.
      Example with base = /Retrosync:
          /Retrosync/alice/roms/...
          /Retrosync/alice/saves/...
          /Retrosync/bob/roms/...
      You'll be asked to pick a username next.
EOF
    if prompt_yn "Multi-user setup?" "n"; then
        MULTI_USER=1
    else
        MULTI_USER=0
    fi

    if [[ $MULTI_USER -eq 1 ]]; then
        echo
        cat <<EOF
Pick a name for your personal subfolder on the NAS.
Letters, numbers, hyphens and underscores only. No spaces. Max 32 chars.
EOF
        while true; do
            USERNAME="$(prompt "Username")"
            if [[ -z "$USERNAME" ]]; then
                warn "Username cannot be empty."; continue
            fi
            if [[ ${#USERNAME} -gt 32 ]]; then
                warn "Username too long (max 32 chars)."; continue
            fi
            if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
                warn "Letters, numbers, hyphens, underscores only."; continue
            fi
            break
        done
        success "Username set: ${USERNAME}"
    fi

    echo
    echo "Enter the path Syncthing INSIDE the NAS will use for retro-data."
    echo
    prereq \
        "  Reminder: this is the path Syncthing's process sees, NOT the host" \
        "  filesystem path. If your Syncthing runs in a container, this is the" \
        "  container-internal mount path you chose during setup (per the" \
        "  prerequisites above). Native install? Use any host path Syncthing" \
        "  can write to."
    echo
    echo "  Containerized examples:  /Retrosync   /data/emulation"
    echo "  Native install examples: /mnt/tank/retro-data   /srv/sync"
    echo
    echo "If you enter /Retrosync, files will end up (as Syncthing sees them) at:"
    if [[ $MULTI_USER -eq 1 ]]; then
        echo "    /Retrosync/${USERNAME}/roms/<console>/..."
        echo "    /Retrosync/${USERNAME}/saves/..."
        echo "    /Retrosync/${USERNAME}/bios/..."
    else
        echo "    /Retrosync/roms/<console>/..."
        echo "    /Retrosync/saves/..."
        echo "    /Retrosync/bios/..."
    fi
    echo
    while true; do
        NAS_BASE_DIR="$(prompt "Base directory on NAS (container-internal)" "/Retrosync")"
        if [[ -z "$NAS_BASE_DIR" ]] || [[ "${NAS_BASE_DIR:0:1}" != "/" ]]; then
            warn "Path must be absolute (start with /), as Syncthing sees it inside the container."
            continue
        fi
        NAS_BASE_DIR="${NAS_BASE_DIR%/}"
        break
    done
    success "NAS base set: $(nas_user_root)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 4: NAS connection
# ─────────────────────────────────────────────────────────────────────────────

step_nas_connection() {
    NAS_SYNC_TCP_PORT="${NAS_SYNC_TCP_PORT:-22000}"
    NAS_SYNC_UDP_PORT="${NAS_SYNC_UDP_PORT:-22000}"
    API_KEY_STORAGE_MODE="${API_KEY_STORAGE_MODE:-plaintext}"

    if [[ -n "${EXISTING_PROFILE:-}" ]]; then
        SYNCTHING_NAS_URL="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.url // empty')"
        local saved_mode stored_value
        saved_mode="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.api_key_storage // empty')"
        stored_value="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.api_key // empty')"
        # Older profiles (pre-storage-modes) just have api_key as plaintext.
        [[ -z "$saved_mode" ]] && saved_mode="plaintext"
        API_KEY_STORAGE_MODE="$saved_mode"
        SYNCTHING_NAS_KEY="$(unprotect_api_key_from_storage "$saved_mode" "$stored_value")"

        local saved_tcp saved_udp
        saved_tcp="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.sync_tcp_port // empty')"
        saved_udp="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.sync_udp_port // empty')"
        [[ -n "$saved_tcp" ]] && NAS_SYNC_TCP_PORT="$saved_tcp"
        [[ -n "$saved_udp" ]] && NAS_SYNC_UDP_PORT="$saved_udp"

        local mode_label
        case "$saved_mode" in
            plaintext)       mode_label="plaintext in profile" ;;
            libsecret)       mode_label="system keyring (libsecret)" ;;
            openssl-machine) mode_label="machine-bound encrypted (openssl)" ;;
            prompt)          mode_label="re-prompted just now" ;;
            *)               mode_label="$saved_mode" ;;
        esac
        if [[ -n "$SYNCTHING_NAS_URL" ]] && [[ -n "$SYNCTHING_NAS_KEY" ]]; then
            info "Using saved NAS connection: ${SYNCTHING_NAS_URL}"
            info "  API key storage: ${mode_label}"
            info "  Saved sync ports: TCP ${NAS_SYNC_TCP_PORT}, UDP ${NAS_SYNC_UDP_PORT}"
            if verify_nas_reachable; then
                gather_device_ids
                pair_devices
                return 0
            fi
            warn "Saved NAS connection failed — re-prompting."
        fi
    fi

    echo
    echo "Before continuing, make sure you've prepared the NAS side:"
    echo
    prereq \
        "  PREREQUISITE - Syncthing running:" \
        "    Syncthing is installed and started on your NAS, and you can" \
        "    open its Web UI from a browser on this device."
    echo
    prereq \
        "  PREREQUISITE - storage path:" \
        "    Most NAS setups (TrueNAS Scale apps, Docker, Unraid, Synology)" \
        "    run Syncthing in a container that can ONLY see paths mounted" \
        "    into it. Before continuing:" \
        "      1. Create a directory on your NAS storage pool (e.g." \
        "         /mnt/tank/retro-data on the host)." \
        "      2. Mount that host directory into the Syncthing container" \
        "         at a chosen path (e.g. /Retrosync), with read+write" \
        "         permissions for the user Syncthing runs as." \
        "      3. Restart the Syncthing app so the mount is active." \
        "    Skip steps 2-3 if Syncthing is installed natively on the NAS —" \
        "    any path the Syncthing user can write to will work."
    echo
    prereq \
        "  PREREQUISITE - ports exposed (for direct LAN sync, not relay):" \
        "    Make sure these ports are reachable from this device to the NAS" \
        "    Syncthing process. On TrueNAS Scale / Docker / Unraid, these" \
        "    must be exposed by the container to the host network:" \
        "      - 8384/tcp   Web UI / REST API (you'll enter the address" \
        "                   below)." \
        "      - 22000/tcp  Sync data (TCP).  -- default; you'll be asked" \
        "      - 22000/udp  Sync data (QUIC). -- to confirm the ports." \
        "    If you've kept Syncthing's defaults, you don't need to change" \
        "    these numbers - just expose 22000/tcp and 22000/udp on your NAS." \
        "    If you customized them in the Syncthing config, the script will" \
        "    ask for the actual ports next."
    echo
    prereq \
        "  PREREQUISITE - API key:" \
        "    Get your NAS Syncthing API key from the Syncthing Web UI:" \
        "    Actions -> Settings -> API Key. You'll be prompted for it next."
    echo
    prompt "Press Enter when ready" "" >/dev/null

    while true; do
        echo
        cat <<EOF
Enter the NAS Syncthing Web UI / REST API address.
  Use the Web UI port (default 8384) — NOT the data-transfer port (22000).
  If you omit the port, 8384 is assumed.
  Examples:  192.168.1.50:8384
             192.168.1.50          (port defaults to 8384)
             nas.local:8384
EOF
        local addr
        addr="$(prompt "NAS address")"
        if [[ -z "$addr" ]]; then
            warn "Address cannot be empty."
            continue
        fi
        SYNCTHING_NAS_URL="$(format_nas_url "$addr")"
        verbose "Resolved NAS URL: ${SYNCTHING_NAS_URL}"

        SYNCTHING_NAS_KEY="$(prompt_secret "NAS Syncthing API key")"
        if [[ -z "$SYNCTHING_NAS_KEY" ]]; then
            warn "API key cannot be empty."
            continue
        fi

        if verify_nas_reachable; then
            break
        fi
        warn "NAS connection failed — couldn't talk to Syncthing at ${SYNCTHING_NAS_URL}"
        echo "  Check:"
        echo "    - is the address correct and reachable from this machine?"
        echo "    - is Syncthing running on the NAS?"
        echo "    - is the port the Web UI port (default 8384), not 22000?"
        echo "    - is the API key correct (web UI -> Actions -> Settings -> API Key)?"
        if ! prompt_yn "Retry?" "y"; then
            fatal "Cancelled."
        fi
    done

    gather_device_ids

    success "NAS reachable at ${SYNCTHING_NAS_URL}"
    info "  Local device ID:  ${LOCAL_DEVICE_ID:0:7}…"
    info "  NAS   device ID:  ${NAS_DEVICE_ID:0:7}…"

    # Ask how to persist the API key now that we know it works. (Asking
    # before would just waste a prompt if the key turned out to be wrong.)
    API_KEY_STORAGE_MODE="$(read_api_key_storage_mode)"

    echo
    echo "NAS Syncthing sync data ports — the ones used for actual file transfer,"
    echo "NOT the Web UI port. Defaults are 22000 for both TCP and UDP. If you"
    echo "left Syncthing's listen settings at their defaults, just press Enter."
    while true; do
        local tcp_in
        tcp_in="$(prompt "  NAS sync TCP port" "22000")"
        if [[ "$tcp_in" =~ ^[0-9]+$ ]] && (( tcp_in >= 1 )) && (( tcp_in <= 65535 )); then
            NAS_SYNC_TCP_PORT="$tcp_in"
            break
        fi
        warn "  Port must be a number between 1 and 65535."
    done
    while true; do
        local udp_in
        udp_in="$(prompt "  NAS sync UDP port (QUIC)" "22000")"
        if [[ "$udp_in" =~ ^[0-9]+$ ]] && (( udp_in >= 1 )) && (( udp_in <= 65535 )); then
            NAS_SYNC_UDP_PORT="$udp_in"
            break
        fi
        warn "  Port must be a number between 1 and 65535."
    done

    # Pair devices on both sides if not already paired.
    pair_devices
}

gather_device_ids() {
    local local_status nas_status
    local_status="$(st_get local "/system/status")" || fatal "Could not query local Syncthing status"
    nas_status="$(st_get nas "/system/status")" || fatal "Could not query NAS Syncthing status"

    LOCAL_DEVICE_ID="$(echo "$local_status" | jq -r '.myID')"
    NAS_DEVICE_ID="$(echo "$nas_status" | jq -r '.myID')"

    if [[ -z "$LOCAL_DEVICE_ID" ]] || [[ "$LOCAL_DEVICE_ID" == "null" ]]; then
        fatal "Could not determine local Syncthing device ID."
    fi
    if [[ -z "$NAS_DEVICE_ID" ]] || [[ "$NAS_DEVICE_ID" == "null" ]]; then
        err "Could not determine NAS Syncthing device ID."
        err "  The NAS responded but didn't return a valid Syncthing identity."
        err "  Most common cause: wrong port. Use the Web UI port (default 8384),"
        err "  not the data-transfer port (22000)."
        exit 1
    fi
}

verify_nas_reachable() {
    # Verify the endpoint is actually Syncthing's REST API (not a stray
    # web UI on port 80, etc.) by checking that ping returns {"ping":"pong"}.
    local resp
    resp="$(st_get nas "/system/ping" 2>/dev/null)" || return 1
    if echo "$resp" | jq -e '.ping == "pong"' >/dev/null 2>&1; then
        return 0
    fi
    verbose "  ping endpoint returned unexpected payload (not Syncthing?)"
    return 1
}

format_nas_url() {
    # Accepts: "10.0.0.5", "10.0.0.5:8384", "http://nas.local:8384", "https://nas/"
    # Echoes the canonical "<scheme>://<host>:<port>/rest" form.
    # Defaults the port to 8384 (Syncthing REST/Web UI), since users frequently
    # confuse it with 22000 (data transfer) or omit it entirely.
    local raw="$1" scheme="http" rest hostpart
    if [[ "$raw" =~ ^(https?)://(.+)$ ]]; then
        scheme="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
    else
        rest="$raw"
    fi
    rest="${rest%/}"
    hostpart="${rest%%/*}"
    if [[ ! "$hostpart" =~ :[0-9]+$ ]]; then
        hostpart="${hostpart}:8384"
    fi
    echo "${scheme}://${hostpart}/rest"
}

nas_host_from_url() {
    # Strip scheme, path, and port from $SYNCTHING_NAS_URL.
    local h="${SYNCTHING_NAS_URL#http://}"
    h="${h#https://}"
    h="${h%%/*}"
    echo "${h%:*}"
}

# Add NAS device to local Syncthing (if not already there) and vice versa.
pair_devices() {
    local local_cfg nas_cfg
    local_cfg="$(st_get local "/config/devices")" || fatal "Could not read local devices"
    nas_cfg="$(st_get nas "/config/devices")"     || fatal "Could not read NAS devices"

    local local_hostname nas_hostname
    local_hostname="$(hostname -s 2>/dev/null || hostname)"
    # Use a heuristic NAS hostname — the user can rename in the GUI later.
    nas_hostname="NAS-Syncthing"

    # Pin the NAS to its known LAN address on port 22000 so local Syncthing
    # doesn't fall back to public relay servers (slow, WAN-typed connection).
    # Keep "dynamic" as a fallback so global discovery still works.
    local nas_host
    nas_host="$(nas_host_from_url)"
    local nas_addresses_json
    nas_addresses_json="$(jq -n --arg h "$nas_host" \
        --arg tcp "$NAS_SYNC_TCP_PORT" \
        --arg udp "$NAS_SYNC_UDP_PORT" \
        '["tcp://" + $h + ":" + $tcp, "quic://" + $h + ":" + $udp, "dynamic"]')"

    # If local Syncthing doesn't know about NAS device, add it.
    if ! echo "$local_cfg" | jq -e --arg id "$NAS_DEVICE_ID" '.[] | select(.deviceID==$id)' >/dev/null; then
        info "Adding NAS device to local Syncthing…"
        local nas_device_json
        nas_device_json="$(jq -n \
            --arg id   "$NAS_DEVICE_ID" \
            --arg name "$nas_hostname" \
            --argjson addrs "$nas_addresses_json" \
            '{deviceID:$id, name:$name, addresses:$addrs, compression:"metadata", introducer:false, paused:false}')"
        st_post local "/config/devices" "$nas_device_json" >/dev/null \
            || fatal "Failed to add NAS device on local Syncthing"
        success "  NAS device added on local Syncthing (direct: tcp://${nas_host}:${NAS_SYNC_TCP_PORT})"
    else
        # Device already known - update addresses so previously-relay-only
        # entries get the direct LAN address pinned.
        verbose "NAS device already known to local Syncthing - updating addresses"
        local existing updated
        existing="$(echo "$local_cfg" | jq --arg id "$NAS_DEVICE_ID" '.[] | select(.deviceID==$id)')"
        updated="$(echo "$existing" | jq --argjson addrs "$nas_addresses_json" '.addresses = $addrs')"
        if st_put local "/config/devices/${NAS_DEVICE_ID}" "$updated" >/dev/null 2>&1; then
            verbose "  pinned NAS direct address ${nas_host} (TCP ${NAS_SYNC_TCP_PORT}, UDP ${NAS_SYNC_UDP_PORT})"
        else
            verbose "  (couldn't update existing device addresses; leaving as-is)"
        fi
    fi

    # If NAS Syncthing doesn't know about local device, add it.
    if ! echo "$nas_cfg" | jq -e --arg id "$LOCAL_DEVICE_ID" '.[] | select(.deviceID==$id)' >/dev/null; then
        info "Adding this device to NAS Syncthing…"
        local local_device_json
        local_device_json="$(jq -n \
            --arg id   "$LOCAL_DEVICE_ID" \
            --arg name "$local_hostname" \
            '{deviceID:$id, name:$name, addresses:["dynamic"], compression:"metadata", introducer:false, paused:false}')"
        st_post nas "/config/devices" "$local_device_json" >/dev/null \
            || fatal "Failed to add local device on NAS Syncthing"
        success "  This device (${local_hostname}) added on NAS Syncthing"
    else
        verbose "Local device already known to NAS Syncthing"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 5: sync scope selection
# ─────────────────────────────────────────────────────────────────────────────

# Each entry: "key|label|local_subpath|nas_subpath"
# local_subpath is relative to FRONTEND_BASE (or absolute if starts with /)
# nas_subpath is relative to NAS_BASE_DIR/USERNAME/
SYNC_SCOPE_DEFINITIONS=()

build_sync_scope_definitions() {
    # Folder keys: roms / bios stay bare so a RetroBat and a RetroDECK device
    # pointing at the same NAS share the same Syncthing folder ID. The
    # frontend-specific scopes use rd-* prefixed keys here; the PowerShell
    # script uses rb-* for the equivalent RetroBat scopes. Different keys
    # means different Syncthing folder IDs, so a cross-frontend setup just
    # doesn't try to share these structurally-incompatible scopes
    # (RetroDECK's states/ contains every emulator's states while RetroBat's
    # RetroArch-only states folder is a subset; RetroDECK splits gamelists
    # and downloaded_media into separate dirs while RetroBat keeps them
    # combined under .emulationstation/).
    #
    # Same-frontend (RetroDECK<->RetroDECK) sync is unaffected since both
    # ends use the same prefixed keys.
    if [[ "$FRONTEND" == "custom" ]]; then
        # Custom mode: local_sub is the user-supplied absolute path. Only
        # include scopes the user actually entered a path for. step_apply_all
        # detects the absolute path (starts with /) and skips the
        # FRONTEND_BASE join.
        SYNC_SCOPE_DEFINITIONS=()
        [[ -n "$CUSTOM_ROMS_PATH"      ]] && SYNC_SCOPE_DEFINITIONS+=("roms|ROMs|${CUSTOM_ROMS_PATH}|roms")
        [[ -n "$CUSTOM_BIOS_PATH"      ]] && SYNC_SCOPE_DEFINITIONS+=("bios|BIOS|${CUSTOM_BIOS_PATH}|bios")
        [[ -n "$CUSTOM_STATES_PATH"    ]] && SYNC_SCOPE_DEFINITIONS+=("custom-states|Save states (custom)|${CUSTOM_STATES_PATH}|states/custom")
        [[ -n "$CUSTOM_GAMELISTS_PATH" ]] && SYNC_SCOPE_DEFINITIONS+=("custom-gamelists|ES-DE gamelists (custom)|${CUSTOM_GAMELISTS_PATH}|gamelists/custom")
        [[ -n "$CUSTOM_MEDIA_PATH"     ]] && SYNC_SCOPE_DEFINITIONS+=("custom-media|ES-DE downloaded media (custom)|${CUSTOM_MEDIA_PATH}|media/custom")
        return 0
    fi

    SYNC_SCOPE_DEFINITIONS=(
        "roms|ROMs|${RD_ROMS_SUB}|roms"
        "bios|BIOS|${RD_BIOS_SUB}|bios"
        "rd-states|Save states (RetroDECK-only - all emulators)|${RD_STATES_SUB}|states/retrodeck"
        "rd-gamelists|ES-DE gamelists (RetroDECK-only)|${RD_GAMELISTS_SUB}|gamelists/retrodeck"
        "rd-media|ES-DE downloaded media (RetroDECK-only)|${RD_MEDIA_SUB}|media/retrodeck"
    )
}

# Selected scope keys, populated from prompts.
SELECTED_SCOPES=()
SAVES_SELECTED=0

step_sync_scope() {
    build_sync_scope_definitions

    if [[ "$FRONTEND" == "custom" ]]; then
        # In custom mode the paths the user entered already declared what to
        # sync — re-asking "ROMs? y/n" right after they typed the ROMs path
        # would be confusing. Auto-include every scope with a non-empty path.
        local entry key
        for entry in "${SYNC_SCOPE_DEFINITIONS[@]}"; do
            IFS='|' read -r key _ _ _ <<< "$entry"
            SELECTED_SCOPES+=("$key")
        done
        if (( ${#CUSTOM_SAVE_PATHS[@]} > 0 )); then
            SAVES_SELECTED=1
        fi
        return 0
    fi

    echo
    echo "What would you like to sync?"
    echo

    local entry key label
    for entry in "${SYNC_SCOPE_DEFINITIONS[@]}"; do
        IFS='|' read -r key label _ _ <<< "$entry"
        # Pre-fill from saved profile if updating.
        local default_yn="y"
        if [[ -n "${EXISTING_PROFILE:-}" ]]; then
            if echo "$EXISTING_PROFILE" | jq -e --arg id "$(folder_id_for "$key")" \
                '.folders[] | select(.id==$id)' >/dev/null 2>&1; then
                default_yn="y"
            else
                default_yn="n"
            fi
        fi
        if prompt_yn "  ${label}" "$default_yn"; then
            SELECTED_SCOPES+=("$key")
        fi
    done

    if prompt_yn "  Saves (per-emulator)" "y"; then
        SAVES_SELECTED=1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 5b: ROMs console picker
# ─────────────────────────────────────────────────────────────────────────────

# After this runs, ROMS_EXCLUDED is a space-separated list of console subdirs
# to add to .stignore for the ROMs folder on this device only.
ROMS_INCLUDED=()
ROMS_EXCLUDED=()

is_large_rom_console() {
    local target="$1" entry id
    for entry in "${LARGE_ROM_CONSOLES[@]}"; do
        IFS='|' read -r id _ _ <<< "$entry"
        [[ "$id" == "$target" ]] && return 0
    done
    return 1
}

large_rom_message() {
    local target="$1" entry id size desc
    for entry in "${LARGE_ROM_CONSOLES[@]}"; do
        IFS='|' read -r id size desc <<< "$entry"
        if [[ "$id" == "$target" ]]; then
            echo "${desc} (${size})"
            return 0
        fi
    done
    echo ""
}

step_roms_picker() {
    # Only run if 'roms' is in SELECTED_SCOPES.
    if ! printf '%s\n' "${SELECTED_SCOPES[@]}" | grep -qx "roms"; then
        return 0
    fi

    local roms_dir
    if [[ "$FRONTEND" == "custom" ]]; then
        roms_dir="$CUSTOM_ROMS_PATH"
    else
        roms_dir="${FRONTEND_BASE}/${RD_ROMS_SUB}"
    fi
    if [[ ! -d "$roms_dir" ]]; then
        warn "ROMs directory not found: $roms_dir"
        warn "Skipping per-console picker. All console subdirs will sync once they exist."
        return 0
    fi

    # Discover console subdirs (one level deep, dirs only).
    local consoles=()
    while IFS= read -r d; do
        consoles+=("$(basename "$d")")
    done < <(find "$roms_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if (( ${#consoles[@]} == 0 )); then
        info "No console subdirectories yet in $roms_dir — all will sync as they appear."
        return 0
    fi

    echo
    echo "Found ${#consoles[@]} console directories on this device."
    echo
    if prompt_yn "Sync ALL consoles to NAS?" "y"; then
        ROMS_INCLUDED=("${consoles[@]}")
        success "Syncing all ${#consoles[@]} consoles."
        return 0
    fi

    echo
    echo "Pick which consoles to sync. Excluded ones go to .stignore on THIS"
    echo "device only — your NAS still gets them from your other devices."
    echo "Some systems show a [!] size warning, but the default is still 'y' so"
    echo "you don't accidentally skip them by pressing Enter."
    echo
    local c warn_text
    for c in "${consoles[@]}"; do
        if is_large_rom_console "$c"; then
            warn_text="  $(printf '%s⚠ %s%s' "$C_YELLOW" "$(large_rom_message "$c")" "$C_RESET")"
        else
            warn_text=""
        fi
        if prompt_yn "    ${c}${warn_text}" "y"; then
            ROMS_INCLUDED+=("$c")
        else
            ROMS_EXCLUDED+=("$c")
        fi
    done

    if (( ${#ROMS_EXCLUDED[@]} > 0 )); then
        info "Excluded on this device: ${ROMS_EXCLUDED[*]}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 5c: ES-DE media console picker
# ─────────────────────────────────────────────────────────────────────────────

MEDIA_EXCLUDED=()

step_media_picker() {
    # Custom mode doesn't tie media to a RetroDECK-style ROM layout, so the
    # "limit media to the same consoles you chose for ROMs" filter doesn't
    # apply — the custom-media folder syncs as-is.
    if [[ "$FRONTEND" == "custom" ]]; then
        return 0
    fi
    if ! printf '%s\n' "${SELECTED_SCOPES[@]}" | grep -qx "rd-media"; then
        return 0
    fi

    if (( ${#ROMS_INCLUDED[@]} == 0 )) && (( ${#ROMS_EXCLUDED[@]} == 0 )); then
        # No console picker was run — sync all media.
        return 0
    fi

    echo
    info "ES-DE media will be limited to the same consoles you chose for ROMs."
    info "Excluding from media: ${ROMS_EXCLUDED[*]:-none}"
    MEDIA_EXCLUDED=("${ROMS_EXCLUDED[@]}")
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 5d: per-emulator saves picker
# ─────────────────────────────────────────────────────────────────────────────

# Each selected save entry: "label|console|local_path|nas_subpath"
SELECTED_SAVES=()

step_saves_picker() {
    if [[ $SAVES_SELECTED -eq 0 ]]; then
        return 0
    fi

    if [[ "$FRONTEND" == "custom" ]]; then
        # Paths were collected up front. Look up the human label for each
        # console_id from RETRODECK_SAVE_LOCATIONS, then push straight into
        # SELECTED_SAVES with the standard NAS subpath convention.
        local entry console_id path label r r_label r_console nas_sub
        for entry in "${CUSTOM_SAVE_PATHS[@]}"; do
            IFS='|' read -r console_id path <<< "$entry"
            label="$console_id"
            for r in "${RETRODECK_SAVE_LOCATIONS[@]}"; do
                IFS='|' read -r r_label r_console _ _ _ <<< "$r"
                if [[ "$r_console" == "$console_id" ]]; then
                    label="$r_label"
                    break
                fi
            done

            nas_sub="saves/${console_id}"
            [[ "$console_id" == "retroarch"   ]] && nas_sub="saves/retroarch"
            [[ "$console_id" == "ps3-trophy"  ]] && nas_sub="saves/ps3/trophy"
            [[ "$console_id" == "ps3"         ]] && nas_sub="saves/ps3/savedata"

            if [[ ! -d "$path" ]] && [[ $DRY_RUN -eq 0 ]]; then
                if ! mkdir -p "$path" 2>/dev/null; then
                    warn "  Couldn't create $path — skipping ${label}."
                    continue
                fi
            fi

            SELECTED_SAVES+=("${label}|${console_id}|${path}|${nas_sub}")
        done
        return 0
    fi

    echo
    echo "Scanning for emulator save locations on this device…"
    echo

    # Build candidate list. Each entry has a primary path (under the user's
    # data dir, e.g. ~/retrodeck/saves/...) and a sandbox fallback path
    # (under ~/.var/app/...). We prefer the primary because that's where
    # RetroDECK keeps user save data; the sandbox path is only meaningful
    # for emulators that haven't been redirected yet.
    local entry label console_id primary_sub sandbox_sub notes
    local primary_path sandbox_path local_path status
    local found=()
    for entry in "${RETRODECK_SAVE_LOCATIONS[@]}"; do
        IFS='|' read -r label console_id primary_sub sandbox_sub notes <<< "$entry"
        primary_path=""
        sandbox_path=""
        [[ -n "$primary_sub" ]] && primary_path="${FRONTEND_BASE}/${primary_sub}"
        [[ -n "$sandbox_sub" ]] && sandbox_path="${RETRODECK_SANDBOX}/${sandbox_sub}"

        if [[ -n "$primary_path" ]] && [[ -d "$primary_path" ]]; then
            local_path="$primary_path"
            status="found"
        elif [[ -n "$sandbox_path" ]] && [[ -d "$sandbox_path" ]]; then
            local_path="$sandbox_path"
            status="found"
        elif [[ -n "$primary_path" ]]; then
            local_path="$primary_path"
            status="missing"
        else
            local_path="$sandbox_path"
            status="missing"
        fi
        found+=("${status}|${label}|${console_id}|${local_path}|${notes}")
    done

    local has_ps1_standalone=0 has_ps1_retroarch=0
    local rec status path
    for rec in "${found[@]}"; do
        IFS='|' read -r status label console_id path notes <<< "$rec"
        case "$console_id" in
            ps1)        [[ "$status" == "found" ]] && has_ps1_standalone=1 ;;
            retroarch)  [[ "$status" == "found" ]] && has_ps1_retroarch=1  ;;
        esac
    done

    # PS1 dual-emulator warning.
    if [[ $has_ps1_standalone -eq 1 ]] && [[ $has_ps1_retroarch -eq 1 ]]; then
        warn "Both standalone PS1 saves (DuckStation) AND RetroArch PS1 saves (PCSX-ReARMed/SwanStation)
   were found on this device. These formats are NOT cross-compatible —
   a save from one cannot be loaded in the other. Make sure all your
   devices use the same PS1 emulator."
        echo
    fi

    # Present the picker.
    echo "Select which saves to sync. Locations that don't exist yet will ask"
    echo "if you want to sync them anyway — say yes if you might install that"
    echo "emulator later, and the saves will start syncing automatically as"
    echo "soon as the directory appears."
    echo
    for rec in "${found[@]}"; do
        IFS='|' read -r status label console_id path notes <<< "$rec"
        local short_path="${path/#$HOME/~}"
        local should_add=0
        if [[ "$status" == "found" ]]; then
            if prompt_yn "  ${label}  (${short_path})" "y"; then
                should_add=1
            fi
        else
            printf '  %s%s — directory does not exist yet (%s)%s\n' \
                "$C_GREY" "$label" "$short_path" "$C_RESET"
            if prompt_yn "    Sync anyway? (auto-syncs once you install this emulator)" "y"; then
                if [[ $DRY_RUN -eq 0 ]]; then
                    if ! mkdir -p "$path" 2>/dev/null; then
                        warn "    Couldn't create $path"
                        continue
                    fi
                fi
                should_add=1
            fi
        fi
        [[ $should_add -eq 0 ]] && continue

        local nas_sub="saves/${console_id}"
        [[ "$console_id" == "retroarch"   ]] && nas_sub="saves/retroarch"
        [[ "$console_id" == "ps3-trophy"  ]] && nas_sub="saves/ps3/trophy"
        [[ "$console_id" == "ps3"         ]] && nas_sub="saves/ps3/savedata"
        SELECTED_SAVES+=("${label}|${console_id}|${path}|${nas_sub}")

        case "$console_id" in
            ps3)
                info "  RPCS3: only savedata/ will sync (NOT installed game data — too large)."
                ;;
            wii)
                info "  Dolphin: full Wii NAND will sync (includes Mii data RFL_DB.dat)."
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Interactive flow — Step 6: sync direction
# ─────────────────────────────────────────────────────────────────────────────

# DEFAULT_DIRECTION is one of: sendreceive, sendonly, receiveonly
DEFAULT_DIRECTION="sendreceive"
PER_FOLDER_DIRECTION=()  # entries: "folder_key|direction"
IGNORE_PERMS=1  # set by step_ignore_perms; folded into folder JSON

choose_direction_for() {
    # IMPORTANT: this function is called via $(...) so its stdout is captured
    # into a variable. The menu MUST go to stderr (so the user sees it but
    # the caller doesn't capture it); only the final direction string goes
    # to stdout. Mixing the two pollutes DEFAULT_DIRECTION and propagates
    # garbage into every later use (apply summary, .stversions setup, etc.).
    local label="$1" default_mode="${2:-sendreceive}" default_choice
    case "$default_mode" in
        sendreceive) default_choice="1" ;;
        sendonly)    default_choice="2" ;;
        receiveonly) default_choice="3" ;;
        *)           default_choice="1" ;;
    esac
    {
        echo
        echo "Sync direction for ${label}:"
        echo "    [1] Two-way   — changes go both directions (recommended for primary device)"
        echo "    [2] Send only — push to NAS only, never pull"
        echo "    [3] Receive only — pull from NAS only, never push"
    } >&2
    local choice
    choice="$(prompt "Choice" "$default_choice")"
    case "$choice" in
        1) echo "sendreceive" ;;
        2) echo "sendonly" ;;
        3) echo "receiveonly" ;;
        *) echo "$default_mode" ;;
    esac
}

step_ignore_perms() {
    if [[ -n "${EXISTING_PROFILE:-}" ]]; then
        local saved
        saved="$(echo "$EXISTING_PROFILE" | jq -r '.ignore_perms // empty')"
        if [[ -n "$saved" ]]; then
            if [[ "$saved" == "true" ]]; then
                IGNORE_PERMS=1
            else
                IGNORE_PERMS=0
            fi
            local state
            state="$([[ $IGNORE_PERMS -eq 1 ]] && echo on || echo off)"
            info "Ignore permissions: ${state} (from saved profile)"
            return 0
        fi
    fi

    echo
    cat <<EOF
Ignore file permissions on synced folders?

  Recommended: yes. Cross-OS sync (e.g. Windows -> ZFS on TrueNAS,
  exFAT cards, Synology, Android) frequently stalls with
  'Out of Sync' because the receiver can't apply the Unix mode
  bits the sender reports. Turning this on tells Syncthing to
  compare/sync content only, not permission bits. ROMs/saves/
  configs don't need permission-bit fidelity.

  Same-OS Linux <-> Linux usually works without this, but
  turning it on is harmless and avoids edge cases (Flatpak
  sandbox UIDs, NFSv4 ACLs on ZFS datasets, etc.).
EOF
    if prompt_yn "Ignore permissions? (recommended)" "y"; then
        IGNORE_PERMS=1
    else
        IGNORE_PERMS=0
    fi
}

step_sync_direction() {
    local mode_default="sendreceive"

    if [[ -n "${EXISTING_PROFILE:-}" ]]; then
        # Re-run on a saved profile: the first-vs-adding distinction was
        # answered last time. Re-asking it would be confusing (e.g. a user
        # who picked "Adding" originally would have to lie and pick
        # "First device" just to flip to two-way). Skip straight to the
        # direction picker.
        DEFAULT_DIRECTION="$(choose_direction_for "all folders (default)" "sendreceive")"
    else
        echo
        cat <<EOF
Is this your first device, or are you adding this device to an
existing NAS-based RetroSync setup?

    [1] First device — the NAS is empty, or this device's files
        should be the starting copy that other devices pull from.
        Default sync direction: Two-way.

    [2] Adding to an existing setup — the NAS already has data from
        another device. Pull NAS data DOWN first; do NOT push this
        device's existing files up. Default direction: Receive only.
        After the first full sync completes, you'll need to flip
        folders to Two-way so future edits go both ways. Two ways
        to do that:
          - In the Syncthing web UI: open each folder -> Edit ->
            Folder Type -> 'Send & Receive' -> Save.
          - Or re-run this script (it skips this question on
            re-runs and goes straight to the direction picker).
EOF
        local mode_choice
        mode_choice="$(prompt "Choice" "1")"

        if [[ "$mode_choice" == "2" ]]; then
            # "Adding to existing setup" already implies receive-only — asking
            # for a direction next would just contradict the choice the user
            # already made. Lock it in and move on.
            DEFAULT_DIRECTION="receiveonly"
            mode_default="receiveonly"
            echo
            info "Sync direction set to Receive only (matches 'Adding' choice)."
        else
            mode_default="sendreceive"
            DEFAULT_DIRECTION="$(choose_direction_for "all folders (default)" "$mode_default")"
        fi
    fi

    if prompt_yn "Apply this direction to ALL folders?" "y"; then
        if [[ "$DEFAULT_DIRECTION" == "receiveonly" ]]; then
            echo
            info "Reminder: after the first full sync finishes (watch progress at"
            info "  ${SYNCTHING_LOCAL_DEFAULT}), flip folders to Two-way. Either:"
            info "    - Web UI: each folder -> Edit -> Folder Type -> 'Send & Receive'."
            info "    - Or re-run this script: pick [1] Update at the profile"
            info "      prompt, then pick [1] Two-way at the direction prompt."
        fi
        return 0
    fi

    # Per-folder override.
    local entry key label
    for entry in "${SYNC_SCOPE_DEFINITIONS[@]}"; do
        IFS='|' read -r key label _ _ <<< "$entry"
        printf '%s\n' "${SELECTED_SCOPES[@]}" | grep -qx "$key" || continue
        local d
        d="$(choose_direction_for "$label" "$mode_default")"
        PER_FOLDER_DIRECTION+=("${key}|${d}")
    done

    local sentry slabel sconsole spath snas_sub
    for sentry in "${SELECTED_SAVES[@]}"; do
        IFS='|' read -r slabel sconsole spath snas_sub <<< "$sentry"
        local d
        d="$(choose_direction_for "${slabel}" "$mode_default")"
        PER_FOLDER_DIRECTION+=("save-${sconsole}|${d}")
    done
}

direction_for() {
    local key="$1" entry k v
    for entry in "${PER_FOLDER_DIRECTION[@]:-}"; do
        IFS='|' read -r k v <<< "$entry"
        if [[ "$k" == "$key" ]]; then
            echo "$v"
            return 0
        fi
    done
    echo "$DEFAULT_DIRECTION"
}

# ─────────────────────────────────────────────────────────────────────────────
# 11. Conflict detection
# ─────────────────────────────────────────────────────────────────────────────

# Echoes "files|bytes" for the given folder by polling the NAS.
nas_folder_status() {
    local folder_id="$1"
    local elapsed=0 status local_files local_bytes
    while (( elapsed < NAS_FOLDER_POLL_TIMEOUT )); do
        if status="$(st_get nas "/db/status?folder=${folder_id}" 2>/dev/null)"; then
            local_files="$(echo "$status" | jq -r '.localFiles // 0')"
            local_bytes="$(echo "$status" | jq -r '.localBytes // 0')"
            if [[ "$local_files" -gt 0 ]] || (( elapsed >= 6 )); then
                echo "${local_files}|${local_bytes}"
                return 0
            fi
        fi
        sleep $NAS_FOLDER_POLL_INTERVAL
        elapsed=$(( elapsed + NAS_FOLDER_POLL_INTERVAL ))
    done
    echo "0|0"
}

local_path_file_count() {
    local path="$1"
    [[ -d "$path" ]] || { echo 0; return 0; }
    find "$path" -type f 2>/dev/null | wc -l
}

local_path_size_bytes() {
    local path="$1"
    [[ -d "$path" ]] || { echo 0; return 0; }
    du -sb "$path" 2>/dev/null | awk '{print $1}'
}

human_bytes() {
    local b="$1"
    if (( b < 1024 ));        then echo "${b} B"
    elif (( b < 1048576 ));   then awk -v b="$b" 'BEGIN{printf "%.1f KB", b/1024}'
    elif (( b < 1073741824 ));then awk -v b="$b" 'BEGIN{printf "%.1f MB", b/1048576}'
    else                           awk -v b="$b" 'BEGIN{printf "%.2f GB", b/1073741824}'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 12. Folder application — idempotent create-or-update on both sides
# ─────────────────────────────────────────────────────────────────────────────

# folder_exists <local|nas> <folder_id>
remove_peer_device_if_unused() {
    # Remove a peer device entry from a Syncthing instance, but only if no
    # remaining folder still references it. Echoes "removed", "in-use", or
    # "failed". Avoids breaking unrelated Syncthing folders the user may have
    # set up between the same two devices.
    local target="$1" device_id="$2"
    if [[ -z "$device_id" ]]; then echo "failed"; return; fi

    local folders refs
    if ! folders="$(syncthing_request "$target" GET "/config/folders" 2>/dev/null)"; then
        echo "failed"; return
    fi

    refs="$(echo "$folders" | jq --arg id "$device_id" \
        '[.[]? | .devices[]? | select(.deviceID==$id)] | length')"
    if (( refs > 0 )); then
        echo "in-use"; return
    fi

    if syncthing_request "$target" DELETE "/config/devices/${device_id}" >/dev/null 2>&1; then
        echo "removed"
    else
        echo "failed"
    fi
}

remove_retrosync_folders() {
    # Remove (or unshare) a set of folder IDs from a Syncthing instance.
    #
    # Modes:
    #   unshare_only=0 - DELETE the folder entirely. Use on the device whose
    #                    participation in sync is being torn down.
    #   unshare_only=1 - Remove just $LOCAL_DEVICE_ID from each folder's
    #                    device list. If no other peers remain, also DELETE.
    #                    Otherwise leave the folder intact and ACTIVE
    #                    (NOT paused) so remaining peers keep syncing.
    #
    # Uses PATCH for surgical updates - PATCH only touches the fields in
    # the body, which avoids two failure modes we hit with full PUT:
    #   1. Full PUT round-trip occasionally dropped/mangled the updated
    #      `devices` field, so paused was applied but our deviceID stayed.
    #   2. Always pausing the folder broke the remaining peers (e.g. when
    #      removing PC, the laptop's folder went paused on NAS, so laptop
    #      had nothing to sync against).
    #
    # Two-pass: PATCH first (fast), then a 1s pause, then DELETE for
    # folders that have no peers left.
    #
    # Returns 0 if cleanup verified, 1 if anything remained problematic.
    local target="$1"
    local unshare_only="$2"
    shift 2
    local ids=("$@")
    local id
    if (( ${#ids[@]} == 0 )); then return 0; fi

    local -a to_delete=()

    # Pass 1: PATCH each folder.
    for id in "${ids[@]}"; do
        local cfg
        if ! cfg="$(syncthing_request "$target" GET "/config/folders/${id}" 2>/dev/null)"; then
            continue
        fi

        local delete_this=0
        local patch_body=""

        if [[ "$unshare_only" == "1" ]]; then
            local remaining_devices peer_count
            remaining_devices="$(echo "$cfg" | jq --arg me "$LOCAL_DEVICE_ID" \
                '[.devices[] | select(.deviceID != $me)]')"
            peer_count="$(echo "$remaining_devices" | jq --arg nas "$NAS_DEVICE_ID" \
                '[.[] | select(.deviceID != $nas)] | length')"

            if (( peer_count == 0 )); then
                # Last peer leaving - pause too so DELETE in pass 2 is fast.
                delete_this=1
                patch_body="$(jq -n --argjson devs "$remaining_devices" \
                    '{devices: $devs, paused: true}')"
            else
                # Other peers still need this folder ACTIVE. No pause.
                patch_body="$(jq -n --argjson devs "$remaining_devices" \
                    '{devices: $devs}')"
            fi
        else
            # Full delete - pause first.
            delete_this=1
            patch_body='{"paused":true}'
        fi

        if syncthing_request "$target" PATCH "/config/folders/${id}" "$patch_body" >/dev/null 2>&1; then
            if [[ "$unshare_only" == "1" ]]; then
                verbose "  ${target}: unshared $id"
            else
                verbose "  ${target}: paused $id"
            fi
        else
            warn "  ${target}: PATCH of $id failed"
        fi

        if (( delete_this == 1 )); then to_delete+=("$id"); fi
    done

    sleep 1

    # Pass 2: DELETE folders that should be gone.
    for id in "${to_delete[@]}"; do
        if syncthing_request "$target" DELETE "/config/folders/${id}" >/dev/null 2>&1; then
            verbose "  ${target}: deleted $id"
        else
            warn "  ${target}: DELETE of $id failed"
            if [[ "$unshare_only" == "1" ]]; then
                warn "  ${target}: folder is unshared and paused (no peers); delete via web UI if you want it gone"
            fi
        fi
    done

    sleep 0.5

    # Verify. Unshare mode: success means we're not in any folder's device
    # list. Default mode: success means folder is gone.
    local after
    local -a still_problem=()
    if after="$(syncthing_request "$target" GET "/config/folders" 2>/dev/null)"; then
        for id in "${ids[@]}"; do
            local folder
            folder="$(echo "$after" | jq --arg id "$id" '.[] | select(.id==$id)')"
            if [[ -z "$folder" ]] || [[ "$folder" == "null" ]]; then
                continue
            fi
            if [[ "$unshare_only" == "1" ]]; then
                if echo "$folder" | jq -e --arg me "$LOCAL_DEVICE_ID" \
                    '.devices[] | select(.deviceID==$me)' >/dev/null 2>&1; then
                    still_problem+=("$id")
                fi
            else
                still_problem+=("$id")
            fi
        done
    else
        verbose "  ${target}: couldn't verify - assuming success"
        return 0
    fi

    if (( ${#still_problem[@]} > 0 )); then
        warn "  ${target}: ${#still_problem[@]} folder(s) STILL reference this device:"
        for id in "${still_problem[@]}"; do
            warn "    - $id"
        done
        return 1
    fi
    if [[ "$unshare_only" == "1" ]]; then
        verbose "  ${target}: this device removed from ${#ids[@]} folder(s)"
    else
        verbose "  ${target}: removed ${#ids[@]} folder(s)"
    fi
    return 0
}

folder_exists() {
    local target="$1" id="$2"
    st_get "$target" "/config/folders/${id}" >/dev/null 2>&1
}

# Build the JSON payload for a Syncthing folder.
build_folder_json() {
    local id="$1" label="$2" path="$3" type="$4" peer_device_id="$5" \
          versioning="${6:-false}"

    local versioning_block='{"type":"","params":{}}'
    if [[ "$versioning" == "true" ]]; then
        versioning_block='{"type":"simple","params":{"keep":"5"}}'
    fi

    # ignorePerms: skip permission bit syncing - controlled by step_ignore_perms.
    # Cross-OS retro setups (Windows <-> ZFS on TrueNAS, exFAT cards, Synology,
    # Android) routinely stall on "Out of Sync" because the receiver can't
    # apply Unix mode bits the sender reports. Equivalent to flipping
    # "Ignore Permissions" in the web UI's Advanced folder settings.
    local ignore_perms_json
    ignore_perms_json="$([[ ${IGNORE_PERMS:-1} -eq 1 ]] && echo true || echo false)"
    jq -n \
        --arg id    "$id" \
        --arg label "$label" \
        --arg path  "$path" \
        --arg type  "$type" \
        --arg peer  "$peer_device_id" \
        --argjson v "$versioning_block" \
        --argjson ip "$ignore_perms_json" '
        {
            id: $id,
            label: $label,
            path: $path,
            type: $type,
            rescanIntervalS: 3600,
            fsWatcherEnabled: true,
            fsWatcherDelayS: 10,
            ignorePerms: $ip,
            autoNormalize: true,
            devices: [
                {deviceID: "__SELF__"},
                {deviceID: $peer}
            ],
            versioning: $v,
            paused: false
        }'
}

# Resolve __SELF__ to the actual device ID for the target side.
finalize_folder_json() {
    local target="$1" json="$2" self_id
    case "$target" in
        local) self_id="$LOCAL_DEVICE_ID" ;;
        nas)   self_id="$NAS_DEVICE_ID"   ;;
    esac
    echo "$json" | jq --arg self "$self_id" \
        '(.devices[] | select(.deviceID=="__SELF__")).deviceID = $self'
}

# Create or update a folder on a given side.
apply_folder() {
    local target="$1" id="$2" label="$3" path="$4" type="$5" peer="$6" \
          versioning="${7:-false}"
    local self_id
    case "$target" in
        local) self_id="$LOCAL_DEVICE_ID" ;;
        nas)   self_id="$NAS_DEVICE_ID"   ;;
    esac

    if ! folder_exists "$target" "$id"; then
        local json final
        json="$(build_folder_json "$id" "$label" "$path" "$type" "$peer" "$versioning")"
        final="$(finalize_folder_json "$target" "$json")"
        verbose "Folder $id new on $target — creating"
        st_post "$target" "/config/folders" "$final" >/dev/null \
            || { err "Create of folder $id on $target failed"; return 1; }
        return 0
    fi

    # Folder exists — MERGE the devices list rather than replace it.
    # Replacing is destructive: e.g. when a laptop joins later, the NAS-side
    # folder originally had devices [NAS, PC]; a naive PUT with [NAS, Laptop]
    # silently dropped the PC, and Syncthing then refused to sync from PC
    # until the user clicked "device wants to share" in the web UI.
    local existing devices_json versioning_block ignore_perms_json final
    existing="$(st_get "$target" "/config/folders/${id}")" || {
        err "Couldn't fetch existing folder $id on $target"
        return 1
    }
    devices_json="$(echo "$existing" | jq --arg self "$self_id" --arg peer "$peer" '
        (.devices // []) as $existing
        | ($existing | map(.deviceID)) as $ids
        | $existing
        + (if ($ids | index($self)) then [] else [{deviceID: $self}] end)
        + (if ($ids | index($peer)) then [] else [{deviceID: $peer}] end)
    ')"

    if [[ "$versioning" == "true" ]]; then
        versioning_block='{"type":"simple","params":{"keep":"5"}}'
    else
        versioning_block='{"type":"","params":{}}'
    fi
    ignore_perms_json="$([[ ${IGNORE_PERMS:-1} -eq 1 ]] && echo true || echo false)"

    final="$(jq -n \
        --arg id    "$id" \
        --arg label "$label" \
        --arg path  "$path" \
        --arg type  "$type" \
        --argjson devices "$devices_json" \
        --argjson v "$versioning_block" \
        --argjson ip "$ignore_perms_json" '
        {
            id: $id,
            label: $label,
            path: $path,
            type: $type,
            rescanIntervalS: 3600,
            fsWatcherEnabled: true,
            fsWatcherDelayS: 10,
            ignorePerms: $ip,
            autoNormalize: true,
            devices: $devices,
            versioning: $v,
            paused: false
        }')"

    verbose "Folder $id exists on $target — updating ($(echo "$devices_json" | jq length) device(s) in list)"
    st_put "$target" "/config/folders/${id}" "$final" >/dev/null \
        || { err "Update of folder $id on $target failed"; return 1; }
    return 0
}

# Write .stignore patterns for a folder on local Syncthing.
apply_ignores() {
    local id="$1"
    shift
    local patterns=("$@")
    if (( ${#patterns[@]} == 0 )); then
        return 0
    fi
    # Build an .stignore body. Comment header + one pattern per line.
    local body
    body="$(printf '// Auto-generated by %s — do not edit manually\n// To update, re-run %s\n' \
        "$RETROSYNC_NAME" "$(basename "$0")")"
    local p
    for p in "${patterns[@]}"; do
        body+=$'\n'"/${p}"
    done

    local json
    json="$(jq -n --arg ignore "$body" '{ignore: ($ignore | split("\n"))}')"
    if [[ $DRY_RUN -eq 1 ]]; then
        dry "Would write .stignore for $id with patterns: ${patterns[*]}"
        return 0
    fi
    st_post local "/db/ignores?folder=${id}" "$json" >/dev/null \
        || warn "Failed to write .stignore for $id"
}

# Mirror the folder onto NAS at the given NAS path, then on local at the given
# local path. Handles versioning toggle.
provision_folder() {
    local key="$1" label="$2" local_path="$3" nas_path="$4" \
          versioning="${5:-false}" ignore_patterns_csv="${6:-}"

    local id
    id="$(folder_id_for "$key")"
    local direction
    direction="$(direction_for "$key")"

    # Conflict detection: count local files + poll NAS.
    local lf nf nb
    lf="$(local_path_file_count "$local_path")"
    info "Provisioning ${label} (id: ${id})"
    info "  local: ${local_path/#$HOME/~}  (${lf} file(s))"
    info "  NAS:   ${nas_path}"

    # Apply on NAS first so we can poll its file count.
    if ! apply_folder nas "$id" "$label" "$nas_path" "$direction" "$LOCAL_DEVICE_ID" "$versioning"; then
        err "Skipping ${label} — NAS apply failed"
        return 1
    fi
    if ! apply_folder local "$id" "$label" "$local_path" "$direction" "$NAS_DEVICE_ID" "$versioning"; then
        err "Skipping ${label} — local apply failed"
        return 1
    fi

    # Write ignores (local side only).
    if [[ -n "$ignore_patterns_csv" ]]; then
        IFS=',' read -ra _pats <<< "$ignore_patterns_csv"
        apply_ignores "$id" "${_pats[@]}"
    fi

    success "  → ${label} configured (${direction}${versioning:+, 5-version retention})"

    # Append to APPLIED_FOLDERS for the summary + profile.
    APPLIED_FOLDERS+=("${id}|${label}|${local_path}|${nas_path}|${direction}|${versioning}|${ignore_patterns_csv}")
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 8 driver — apply all selected folders
# ─────────────────────────────────────────────────────────────────────────────

APPLIED_FOLDERS=()

step_apply_all() {
    echo
    hr
    info "Applying configuration…"
    hr

    local entry key label local_sub nas_sub
    local user_root
    user_root="$(nas_user_root)"

    for entry in "${SYNC_SCOPE_DEFINITIONS[@]}"; do
        IFS='|' read -r key label local_sub nas_sub <<< "$entry"
        printf '%s\n' "${SELECTED_SCOPES[@]}" | grep -qx "$key" || continue

        local lp np
        # Custom mode emits absolute paths in the local_sub field — detect
        # that and skip the FRONTEND_BASE join (which would produce //foo).
        if [[ "$local_sub" == /* ]]; then
            lp="$local_sub"
        else
            lp="${FRONTEND_BASE}/${local_sub}"
        fi
        np="${user_root}/${nas_sub}"

        local versioning="false"
        # Save states get versioning. Match anything containing "states"
        # so the prefixed keys (rd-states, rb-retroarch-states) still work.
        [[ "$key" == *"states"* ]] && versioning="true"

        local ignores=""
        if [[ "$key" == "roms" ]] && (( ${#ROMS_EXCLUDED[@]} > 0 )); then
            ignores="$(IFS=','; echo "${ROMS_EXCLUDED[*]}")"
        elif [[ "$key" == "rd-media" ]] && (( ${#MEDIA_EXCLUDED[@]} > 0 )); then
            ignores="$(IFS=','; echo "${MEDIA_EXCLUDED[*]}")"
        fi

        provision_folder "$key" "$label" "$lp" "$np" "$versioning" "$ignores" || true
    done

    # Per-emulator saves.
    local sentry slabel sconsole spath snas_sub
    for sentry in "${SELECTED_SAVES[@]}"; do
        IFS='|' read -r slabel sconsole spath snas_sub <<< "$sentry"
        local np="${user_root}/${snas_sub}"
        # All saves get versioning.
        provision_folder "save-${sconsole}" "${slabel}" "$spath" "$np" "true" "" || true
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 13. Summary printer + profile build
# ─────────────────────────────────────────────────────────────────────────────

direction_arrow() {
    case "$1" in
        sendreceive) echo "⟷ two-way" ;;
        sendonly)    echo "⟶ send" ;;
        receiveonly) echo "⟵ receive" ;;
        *)           echo "?" ;;
    esac
}

print_summary() {
    echo
    hr
    printf '%s%s Setup Complete%s\n' "$C_BOLD" "$RETROSYNC_NAME" "$C_RESET"
    hr
    echo
    printf '  Device:    %s\n' "$(hostname -s 2>/dev/null || hostname)"
    printf '  Frontend:  %s\n' "$FRONTEND"
    if [[ $MULTI_USER -eq 1 ]]; then
        printf '  Mode:      multi-user (username: %s)\n' "$USERNAME"
    else
        printf '  Mode:      single-user\n'
    fi
    printf '  NAS:       %s\n' "$SYNCTHING_NAS_URL"
    printf '  NAS root:  %s\n' "$(nas_user_root)"
    echo
    echo "  Synced folders:"
    printf '    %-22s %-12s %-12s %s\n' "Name" "Direction" "Versioning" "Local Path"
    printf '    %s\n' "──────────────────────────────────────────────────────────────────────"

    local entry id label lp np dir ver _ign
    for entry in "${APPLIED_FOLDERS[@]:-}"; do
        IFS='|' read -r id label lp np dir ver _ign <<< "$entry"
        local v="off"
        [[ "$ver" == "true" ]] && v="5 versions"
        printf '    %-22s %-12s %-12s %s\n' \
            "$label" "$(direction_arrow "$dir")" "$v" "${lp/#$HOME/~}"
    done

    if (( ${#ROMS_EXCLUDED[@]} > 0 )); then
        echo
        echo "  ROM consoles excluded on this device:"
        printf '    %s\n' "${ROMS_EXCLUDED[*]}"
    fi

    echo
    echo "  Syncthing is now syncing in the background."
    echo "  Monitor at: ${SYNCTHING_LOCAL_DEFAULT}"
    echo
    echo "  Profile saved: $(profile_file)"
    echo
    echo "  To add more consoles or change settings, run this script again."
    hr
}

build_profile_json() {
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local hostname
    hostname="$(hostname -s 2>/dev/null || hostname)"

    # Build folders array.
    local folders_json="[]" entry id label lp np dir ver ignores
    for entry in "${APPLIED_FOLDERS[@]:-}"; do
        IFS='|' read -r id label lp np dir ver ignores <<< "$entry"
        local ign_arr
        if [[ -n "$ignores" ]]; then
            ign_arr="$(echo "$ignores" | jq -R 'split(",")')"
        else
            ign_arr="[]"
        fi
        folders_json="$(echo "$folders_json" | jq \
            --arg id "$id" --arg label "$label" \
            --arg lp "$lp" --arg np "$np" \
            --arg dir "$dir" --argjson ver "$([[ "$ver" == "true" ]] && echo true || echo false)" \
            --argjson ign "$ign_arr" \
            '. + [{id:$id, name:$label, local_path:$lp, nas_path:$np,
                   type:$dir, versioning:$ver, ignore_patterns:$ign}]')"
    done

    local multi_json ignore_perms_json stored_key
    multi_json="$([[ $MULTI_USER -eq 1 ]] && echo true || echo false)"
    ignore_perms_json="$([[ ${IGNORE_PERMS:-1} -eq 1 ]] && echo true || echo false)"
    # Convert the in-memory raw key into whatever form profile.json should
    # hold (plaintext, empty for libsecret/prompt, etc.). For libsecret this
    # also writes the secret into the keyring as a side effect.
    stored_key="$(protect_api_key_for_storage "${API_KEY_STORAGE_MODE:-plaintext}" "$SYNCTHING_NAS_KEY")"
    jq -n \
        --arg version "1.0" \
        --arg device "$hostname" \
        --arg fe "$FRONTEND" \
        --arg fbp "$FRONTEND_BASE" \
        --arg user "$USERNAME" \
        --argjson multi "$multi_json" \
        --argjson iperms "$ignore_perms_json" \
        --arg now "$now" \
        --arg lurl "$SYNCTHING_LOCAL_DEFAULT" \
        --arg lid "$LOCAL_DEVICE_ID" \
        --arg nurl "$SYNCTHING_NAS_URL" \
        --arg nbase "$NAS_BASE_DIR" \
        --arg nid "$NAS_DEVICE_ID" \
        --arg nkey "$stored_key" \
        --arg nkeystorage "${API_KEY_STORAGE_MODE:-plaintext}" \
        --argjson ntcp "${NAS_SYNC_TCP_PORT:-22000}" \
        --argjson nudp "${NAS_SYNC_UDP_PORT:-22000}" \
        --argjson folders "$folders_json" '
        {
            version: $version,
            device_name: $device,
            frontend: $fe,
            frontend_base_path: $fbp,
            multi_user: $multi,
            username: $user,
            ignore_perms: $iperms,
            created_at: $now,
            updated_at: $now,
            local_syncthing: {
                address: $lurl,
                device_id: $lid
            },
            nas_syncthing: {
                url: $nurl,
                address: ($nurl | sub("^https?://"; "") | sub("/rest$"; "")),
                api_key_storage: $nkeystorage,
                api_key: $nkey,
                nas_base: $nbase,
                device_id: $nid,
                sync_tcp_port: $ntcp,
                sync_udp_port: $nudp
            },
            folders: $folders
        }'
}

# ─────────────────────────────────────────────────────────────────────────────
# 13b. Remove-device flow
# ─────────────────────────────────────────────────────────────────────────────

step_remove_device() {
    echo
    hr
    printf '%s%s%s\n' "$C_BOLD" "Remove this device from RetroSync" "$C_RESET"
    hr

    # Use saved NAS connection from the profile - no re-prompting.
    SYNCTHING_NAS_URL="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.url')"
    SYNCTHING_NAS_KEY="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.api_key')"
    local nas_base
    nas_base="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.nas_base')"

    # Load device IDs - the unshare logic NEEDS these to identify "us" and
    # the NAS in folder device lists. If they're empty, the jq selects all
    # silently match nothing, devices stay unfiltered, and the script
    # falsely reports success while NAS keeps everything intact.
    LOCAL_DEVICE_ID="$(echo "$EXISTING_PROFILE" | jq -r '.local_syncthing.device_id // empty')"
    NAS_DEVICE_ID="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.device_id // empty')"
    if [[ -z "$LOCAL_DEVICE_ID" ]]; then
        local local_status
        if local_status="$(syncthing_request local GET "/system/status" 2>/dev/null)"; then
            LOCAL_DEVICE_ID="$(echo "$local_status" | jq -r '.myID // empty')"
        fi
    fi

    echo
    info "Checking NAS reachability..."
    local nas_reachable=0
    if verify_nas_reachable; then
        nas_reachable=1
        success "NAS reachable - we can remove configs from both sides."
        if [[ -z "$NAS_DEVICE_ID" ]]; then
            local nas_status
            if nas_status="$(syncthing_request nas GET "/system/status" 2>/dev/null)"; then
                NAS_DEVICE_ID="$(echo "$nas_status" | jq -r '.myID // empty')"
            fi
        fi
    else
        warn "NAS unreachable. Local cleanup will proceed but you'll need to"
        warn "remove folder configs from the NAS Syncthing manually."
    fi

    if [[ -z "$LOCAL_DEVICE_ID" ]]; then
        err "Couldn't determine this device's Syncthing ID - aborting cleanup."
        err "  Restart Syncthing locally and try again, or remove folders via web UI."
        return 1
    fi

    local folder_count
    folder_count="$(echo "$EXISTING_PROFILE" | jq -r '.folders | length')"
    if [[ "$folder_count" -eq 0 ]]; then
        warn "No folders in profile. Just deleting profile.json."
        [[ $DRY_RUN -eq 0 ]] && rm -f "$(profile_file)"
        success "Profile removed."
        return 0
    fi

    echo
    echo "The following ${folder_count} folder(s) are configured for sync:"
    echo
    local rows
    rows="$(echo "$EXISTING_PROFILE" | jq -r '.folders[] | "  - \(.id)\n      local: \(.local_path)\n      NAS:   \(.nas_path)"')"
    echo "$rows"
    echo
    echo "Removing the configs un-pairs the folders. The actual data files are"
    echo "left in place by default - you can optionally delete them below."

    # Q1: delete server data?
    echo
    local delete_nas=0
    if prompt_yn "Delete the synced data files on the NAS too?" "n"; then
        echo
        warn "Heads up: this script CANNOT directly delete files on the NAS through
   Syncthing's REST API - the API only manages folder configs, not file
   contents. After this script finishes you'll need to SSH or file-manager
   into your NAS and remove the data directory yourself. Suggested:
       rm -rf ${nas_base}
   (That's the path Syncthing sees inside its container. If you mounted
    a host directory into the container, delete the host-side directory
    instead - same effect, no permissions surprises.)"
        echo
        local confirm
        confirm="$(prompt "Type 'yes' to acknowledge you'll handle NAS cleanup manually")"
        if [[ "$confirm" == "yes" ]]; then
            delete_nas=1
        else
            info "OK, skipping the NAS-deletion reminder."
        fi
    fi

    # Q2: delete device data?
    echo
    local delete_local=0
    if prompt_yn "Delete the synced data files on THIS device?" "n"; then
        echo
        warn "This will permanently delete the following directories from this device:"
        echo "$EXISTING_PROFILE" | jq -r '.folders[] | "      \(.local_path)"' | while read -r line; do
            printf '%s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"
        done
        echo
        local confirm
        confirm="$(prompt "Type 'yes' to confirm permanent deletion")"
        if [[ "$confirm" == "yes" ]]; then
            delete_local=1
        else
            info "OK, keeping local data files."
        fi
    fi

    # Action: remove folder configs.
    echo
    info "Removing folder configurations from Syncthing..."
    local -a ids_arr=()
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids_arr+=("$id")
    done < <(echo "$EXISTING_PROFILE" | jq -r '.folders[].id')

    # On THIS device: always full delete.
    # On the NAS: full delete if we're the last peer (no point keeping
    # orphan folders); otherwise unshare-only so other devices keep their
    # sync. The full-delete path only PATCHes {"paused":true} (single
    # scalar field, reliably applied) before DELETE - which avoids the
    # multi-field PATCH that proved flaky in the unshare path's
    # peer-count==0 corner case.
    local is_last_peer=0
    if [[ $nas_reachable -eq 1 ]]; then
        is_last_peer=1
        local _id _cfg _other_peer_count
        for _id in "${ids_arr[@]}"; do
            if _cfg="$(syncthing_request nas GET "/config/folders/${_id}" 2>/dev/null)"; then
                _other_peer_count="$(echo "$_cfg" | jq --arg me "$LOCAL_DEVICE_ID" --arg nas "$NAS_DEVICE_ID" \
                    '[.devices[] | select(.deviceID != $me and .deviceID != $nas)] | length')"
                if (( _other_peer_count > 0 )); then
                    is_last_peer=0
                    break
                fi
            fi
        done
    fi

    if [[ $nas_reachable -eq 1 ]]; then
        if [[ $is_last_peer -eq 1 ]]; then
            info "  Last peer - folders will be removed entirely from NAS."
        else
            info "  Other devices still use these folders - unsharing only on NAS."
        fi
    fi

    local local_ok=1 nas_ok=1
    remove_retrosync_folders local 0 "${ids_arr[@]}" || local_ok=0
    if [[ $nas_reachable -eq 1 ]]; then
        if [[ $is_last_peer -eq 1 ]]; then
            remove_retrosync_folders nas 0 "${ids_arr[@]}" || nas_ok=0
        else
            remove_retrosync_folders nas 1 "${ids_arr[@]}" || nas_ok=0
        fi
    fi

    if [[ $local_ok -eq 1 ]] && [[ $nas_ok -eq 1 ]]; then
        success "Folder configs cleaned up:"
        echo  "    - this device: configs deleted"
        if [[ $nas_reachable -eq 1 ]]; then
            if [[ $is_last_peer -eq 1 ]]; then
                echo "    - NAS:         folders deleted (no other devices were using them)"
            else
                echo "    - NAS:         this device unshared (folders kept active for"
                echo "                   the remaining devices)"
            fi
        fi
    else
        echo
        warn "Some folder configs could not be removed automatically."
        warn "Profile NOT deleted - re-run [3] Remove to retry, or remove the"
        warn "remaining folders via the Syncthing web UI."
        hr
        return 0
    fi

    # Action: remove device pairings, but only if no other folder still
    # references them - so unrelated Syncthing setups between the same two
    # devices don't get broken.
    echo
    info "Cleaning up device pairings (only if unused by other folders)..."
    local peer_nas_on_local peer_local_on_nas r
    peer_nas_on_local="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.device_id // empty')"
    peer_local_on_nas="$(echo "$EXISTING_PROFILE" | jq -r '.local_syncthing.device_id // empty')"

    if [[ -n "$peer_nas_on_local" ]]; then
        r="$(remove_peer_device_if_unused local "$peer_nas_on_local")"
        case "$r" in
            removed) success "  local: NAS device pairing removed" ;;
            in-use)  info    "  local: NAS device kept (still used by other folders)" ;;
            failed)  warn    "  local: couldn't remove NAS device pairing - remove via web UI if you want it gone" ;;
        esac
    fi
    if [[ $nas_reachable -eq 1 ]] && [[ -n "$peer_local_on_nas" ]]; then
        r="$(remove_peer_device_if_unused nas "$peer_local_on_nas")"
        case "$r" in
            removed) success "  NAS:   this device's pairing removed" ;;
            in-use)  info    "  NAS:   this device kept (still used by other folders)" ;;
            failed)  warn    "  NAS:   couldn't remove this device's pairing - remove via web UI if you want it gone" ;;
        esac
    fi

    # Action: delete local data
    if [[ $delete_local -eq 1 ]]; then
        echo
        info "Deleting local data files..."
        local path
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            if [[ -d "$path" ]]; then
                if [[ $DRY_RUN -eq 1 ]]; then
                    dry "rm -rf ${path}"
                else
                    if rm -rf -- "$path" 2>/dev/null; then
                        success "  deleted: $path"
                    else
                        err "  failed: $path"
                    fi
                fi
            else
                verbose "  (already absent) $path"
            fi
        done < <(echo "$EXISTING_PROFILE" | jq -r '.folders[].local_path')
    fi

    # Action: delete profile + any keyring entry that referenced it.
    echo
    local saved_mode
    saved_mode="$(echo "$EXISTING_PROFILE" | jq -r '.nas_syncthing.api_key_storage // "plaintext"')"
    if [[ "$saved_mode" == "libsecret" ]] && [[ $DRY_RUN -eq 0 ]]; then
        clear_api_key_from_keyring
        verbose "Cleared NAS API key from system keyring"
    fi
    [[ $DRY_RUN -eq 0 ]] && rm -f "$(profile_file)"
    success "Profile deleted: $(profile_file)"

    echo
    hr
    printf '%s%s removed from this device%s\n' "$C_BOLD" "$RETROSYNC_NAME" "$C_RESET"
    hr
    if [[ $delete_nas -eq 1 ]]; then
        echo
        info "REMINDER - delete the NAS data manually:"
        echo "    Container-internal path: ${nas_base}"
        echo "    SSH or file-manager into your NAS and remove that directory."
        echo "    Example: rm -rf ${nas_base}"
    fi
    if [[ $nas_reachable -eq 0 ]]; then
        echo
        warn "NAS was unreachable - the folder configs may still exist on it."
        warn "Remove them via the NAS Syncthing web UI when you can reach it."
    fi
    echo
    echo "  You can now re-run this script for a fresh setup."
    hr
}

# ─────────────────────────────────────────────────────────────────────────────
# 14. Main entry
# ─────────────────────────────────────────────────────────────────────────────

main() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo
        printf '%s═══ DRY RUN MODE — no changes will be made ═══%s\n' "$C_CYAN" "$C_RESET"
        echo
    fi

    printf '%s%s v%s%s\n' "$C_BOLD" "$RETROSYNC_NAME" "$RETROSYNC_VERSION" "$C_RESET"
    printf '%sTip: prompts show [defaults] in brackets — press Enter to accept the default.%s\n\n' "$C_GREY" "$C_RESET"

    # Pre-flight.
    check_bash_version
    check_required_tools
    preflight_local_syncthing

    # Interactive flow.
    PROFILE_MODE="fresh"
    EXISTING_PROFILE=""
    step_profile_detection

    if [[ "$PROFILE_MODE" == "remove" ]]; then
        step_remove_device
        return 0
    fi

    step_frontend_selection
    step_nas_connection
    step_nas_layout
    step_sync_scope
    step_roms_picker
    step_media_picker
    step_saves_picker
    step_ignore_perms
    step_sync_direction

    # Summary of intent before applying.
    echo
    info "About to configure $((${#SELECTED_SCOPES[@]} + ${#SELECTED_SAVES[@]})) folder(s) on both devices."
    if [[ $DRY_RUN -eq 0 ]] && ! prompt_yn "Proceed?" "y"; then
        fatal "Cancelled."
    fi

    # Apply.
    step_apply_all

    # Save profile.
    if (( ${#APPLIED_FOLDERS[@]} > 0 )); then
        save_profile "$(build_profile_json)"
    else
        warn "No folders were configured — profile not saved."
    fi

    # Done.
    print_summary
}

main "$@"
