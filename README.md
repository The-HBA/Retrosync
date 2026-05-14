# Retrosync
Retrosync is a script that automates the process of creating syncthing connections to sync/backup your roms, bios, saves, states, ES-DE gamelists and media.

> **Note:** To be fully transperent, this project is made using artificial intelligence, I welcome any help or even taking over the project. Currently the project depends on the user already having syncthing running in the background, and it only designed with RetroDECK and RetroBat file structure in mind. In the future it could be a full on app and container stack.

Configure [Syncthing](https://syncthing.net) to keep your retro gaming files —
ROMs, BIOS, saves, save states, and ES-DE metadata — in sync between your
client devices and a central NAS hub. One interactive setup, idempotent
re-runs, and the GUI stays untouched.

> **Status:** v0.3.1 — Windows ↔ Windows (RetroBat) syncing is stable. Linux ↔ Linux (RetroDECK) and cross-OS sync are in testing.

---

## Why I made it?

I have:

- A Steam Deck running RetroDECK
- An HTPC running RetroDECK on Bazzite
- A Windows PC running RetroBat
- A TrueNAS Scale server running a [Syncthing](https://syncthing.net) instance

I want all those clients to sync ROMs, saves, and ES-DE artwork through the
NAS — so a save I made on the Deck is already on my HTPC when I sit down to play,
and a ROM I added on Windows shows up on the Deck without doing anything.

# What it does?

RetroSync configures Syncthing on **both** the client device **and** the NAS at
the same time, via Syncthing's REST API. You answer a few prompts, it sets up
all the folders, device pairings, ignore rules, and versioning policies, then
gets out of the way. Re-running the script is safe — it updates rather than
duplicates.

---

## v0.3.0 scope

| Frontend | Status |
|---|---|
| RetroBat (Windows)                     | ✅ Supported (Stable) |
| RetroDECK (Linux Flatpak)              | ✅ Supported (Testing) |
| **Custom locations (any frontend, any layout)** | ✅ **New in v0.3.0** |
| EmuDeck (Linux)                        | 🔜 Planned (works today via custom mode) |
| EmuDeck (Windows)                      | 🔜 Planned (works today via custom mode) |
| Standalone ES-DE                       | ✅ Works via custom mode |
| Batocera, Lakka, RecalBox              | ✅ Works via custom mode |

**Custom mode** lets you manually enter the absolute path for each thing
you want to sync (ROMs, BIOS, save states, ES-DE gamelists, ES-DE media,
plus per-emulator save folders). Leave a prompt blank to skip that entry.
This makes RetroSync work with any frontend, any folder layout, or no
frontend at all — at the cost of typing the paths yourself instead of
having them auto-detected. Pick option `[2] Custom locations` when the
script asks which frontend you're using.

---

## Cross-OS sync: what works, what doesn't

**Same-frontend** (RetroBat ↔ RetroBat, or RetroDECK ↔ RetroDECK): everything
works as designed. ROMs, BIOS, saves, save states, ES-DE metadata, all of it.
This is the supported, tested path.

**Cross-frontend** (RetroBat ↔ RetroDECK): *partially* works, and the script
is now honest about which parts.

| Scope | Cross-frontend? | Why |
|---|---|---|
| **ROMs** | ✅ yes, with care | Both frontends use `roms/<console>/`. Watch out for filename case collisions between Linux (case-sensitive) and Windows (case-insensitive). |
| **BIOS** | ✅ yes, with care | Same files on both. Same casing caveat. |
| **Per-emulator saves (PCSX2, DuckStation)** | ✅ yes | Both frontends use the same `<emulator>/memcards/<file>` leaf structure. |
| **Per-emulator saves (Dolphin, Cemu, RPCS3, Ryujinx/RyuBing)** | ⚠️ no | Same emulator binaries, but each frontend reorganizes the surrounding folder structure differently. |
| **RetroArch saves** | ⚠️ no | RetroBat sorts by core; RetroDECK puts everything at the saves root. |
| **Save states** | ⚠️ no | Emulator-build-specific; unreliable cross-OS or even cross-version. |
| **ES-DE gamelists / media** | ⚠️ no | RetroBat combines them under `.emulationstation/`, RetroDECK splits into `ES-DE/gamelists/` + `ES-DE/downloaded_media/`. Embedded media paths in gamelist.xml differ. |
| **Themes / controller configs** | ❌ no | Frontend-specific. |

To prevent the broken combinations from even being tried, the script uses
different Syncthing folder IDs per frontend for the structurally-incompatible
scopes (`rb-*` for RetroBat-only, `rd-*` for RetroDECK-only). ROMs and BIOS
keep generic IDs so they're shared cross-frontend by default.

**Filename case collisions.** Linux ext4/btrfs are case-sensitive; Windows
NTFS isn't. If your Linux device has both `data/PET/` and `data/pet/` (real
example from a RetroArch BIOS install), or `Bully (USA).iso` and
`bully (usa).iso`, Syncthing can't send both to Windows — only one name can
exist at that path. Fix: pick one casing on the Linux side, delete or merge
the duplicate.

---

## Prerequisites

1. **Syncthing installed and started at least once** on every device,
   including the NAS. The script reads the local API key from Syncthing's
   `config.xml` — that file only exists after the first run.
2. **NAS storage path mounted into the Syncthing container** (TrueNAS Scale /
   Docker / Unraid). The script asks for the path Syncthing sees *inside*
   the container, not the host path. If you skip this step, Syncthing will
   create the folder inside its own container filesystem and your storage
   pool stays empty.
3. **Syncthing data ports exposed** for direct LAN sync, not relay:
   - 8384/tcp (Web UI / REST API)
   - 22000/tcp (data, TCP)
   - 22000/udp (data, QUIC)

   On TrueNAS Scale these have to be exposed in the Syncthing app's container
   config. Without 22000 open, Syncthing falls back to public relay servers —
   it works, but at single-digit megabits even on a gigabit LAN.
4. **Your NAS Syncthing API key** — from the NAS Syncthing web UI:
   *Actions → Settings → API Key*.
5. **Bash 4.0+** with `curl`, `jq`, and `openssl` (Linux), or
   **PowerShell 5.1+** (Windows).

### Installing Syncthing
> Please check their official website for up to date download guides

| Platform | How |
|---|---|
| Steam Deck (Game Mode) | [Decky Plugin: Syncthing](https://github.com/theCapypara/steamdeck-decky-syncthing) or Flatpak via Discover in Desktop Mode |
| Windows / Linux | <https://syncthing.net/downloads/> — installer |
| TrueNAS SCALE | Apps → Discover → Syncthing → add a Storage entry mounting your data path into the container at e.g. `/Retrosync`, expose ports 22000 tcp+udp |
| Unraid | Community Apps → Syncthing |
| Synology | Package Center (third-party source) or Docker |

### Installing required tools (Linux)

```bash
# SteamOS
sudo steamos-readonly disable
sudo pacman -Sy curl jq openssl libsecret
sudo steamos-readonly enable

# Bazzite / Fedora Atomic
rpm-ostree install curl jq openssl libsecret
systemctl reboot

# Ubuntu / Debian
sudo apt install curl jq openssl libsecret-tools

# Arch
sudo pacman -S curl jq openssl libsecret
```

`openssl` is used for machine-bound API key encryption (the DPAPI-equivalent
on Linux). `libsecret` is optional — enables encrypted API-key storage in
the desktop's keyring.

---

## Usage

⚠️ ALERT!

**Do not run any script you find on the internet unless you verify it is safe to run.**

Running unverified scripts (like .sh, .ps1, .bat, or .py files) gives third-party code direct permission to execute commands on your machine. Malicious scripts can easily:
- Steal personal data, credentials, and API keys.
- Install ransomware or background malware.
- Delete or permanently corrupt your files.
- Silently compromise your entire home network.

> RetroSync is currently in an alpha testing state. While the scripts are available for use and review, expect bugs, edge cases, and potential instability. Use at your own risk, and please back up your data before testing!

### Linux (RetroDECK)

```bash
# Download
curl -LO https://raw.githubusercontent.com/The-HBA/Retrosync/main/retrosync-setup.sh
chmod +x retrosync-setup.sh

# Dry-run first to see what it WOULD do
./retrosync-setup.sh --dry-run

# Real run
./retrosync-setup.sh
```

Run the script with `bash` or via `./` — not `sh retrosync-setup.sh`. It
uses bashisms throughout and refuses to run under dash.

### Windows (RetroBat)

```powershell
# Download
Invoke-WebRequest -Uri https://raw.githubusercontent.com/The-HBA/Retrosync/main/retrosync-setup.ps1 -OutFile retrosync-setup.ps1

# Dry-run first
.\retrosync-setup.ps1 -DryRun

# Real run
.\retrosync-setup.ps1
```

If you see an execution policy error on Windows:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Flags

| Linux | Windows | What it does |
|---|---|---|
| `--dry-run` | `-DryRun` | Print every action without making changes. Use this first. |
| `--verbose` | `-VerboseLog` | Print every API request/response. Use when debugging. |
| `--no-color` | `-NoColor` | Disable ANSI colors. |
| `--profile PATH` | `-ProfilePath PATH` | Use a custom profile file. |
| `-h`, `--help` | `Get-Help .\retrosync-setup.ps1 -Detailed` | Show usage. |
| `-V`, `--version` | `-Version` | Show version. |

---

## How it works

1. **Pre-flight.** Checks shell version, required tools, Syncthing reachable
   on `localhost:8384`, and auto-extracts your local Syncthing API key from
   `config.xml`.
2. **Profile detection.** If you've run RetroSync before, four options:
   - `[1] Update` — add/change folders, keep existing config
   - `[2] Start fresh` — delete profile, reconfigure from scratch
   - `[3] Remove this device from sync` — clean up Syncthing configs on this
     device and on the NAS (unshares from other devices if any still use the
     folders, otherwise fully deletes); optionally delete local data and/or
     point you at the NAS data to delete manually
   - `[4] Exit`
3. **Frontend selection.** Pick `[1]` for RetroDECK (Linux) or RetroBat
   (Windows) — the script auto-detects the install path (parses
   `retrodeck.cfg` on Linux to find custom `rdhome=` locations) and lets
   you confirm or override. Pick `[2] Custom locations` for any other
   layout — the script then asks for the absolute path to each thing you
   want to sync (ROMs, BIOS, states, gamelists, media, then per-emulator
   save folders); leave a prompt blank to skip that entry.
4. **NAS connection.** Address (port defaults to 8384 if omitted), API key,
   ping check, device-ID exchange, and pairs the devices on both sides. Pins
   the NAS device's address to `tcp://<host>:22000` so future connects don't
   fall back to public relay servers.
5. **API key storage.** First-time setup: choose how to persist the NAS API
   key. The script picks the strongest available option as the default:
   - **Windows DPAPI** — encrypted with your Windows user account.
     Decryptable only on this machine, by you. No extra deps.
   - **Linux libsecret** — encrypted by your desktop's keyring (GNOME
     Keyring, KWallet, etc.). Needs `secret-tool` and a running keyring
     agent.
   - **Linux openssl-machine** — AES-256-CBC encrypted with a key derived
     from `/etc/machine-id` + your UID. Equivalent guarantee to DPAPI on
     Windows: portable only to *this user on this machine*. Works even on
     headless boxes and Steam Deck Game Mode where no keyring agent runs.
   - **Plaintext** — raw key in profile.json. File is chmod 600 on Linux,
     in per-user APPDATA on Windows. Simple; risk is accidental upload.
   - **Don't store** — re-prompted every run. Most secure, least convenient.
6. **Multi-user / single-user.** Single-user (recommended for personal
   setups) puts everything directly under `{nas_base}/`. Multi-user prompts
   for a username and your data lives at `{nas_base}/{username}/`. Folder
   IDs reflect the choice so different users on the same NAS don't collide.
7. **Sync scope.** Pick what to sync: ROMs, BIOS, save states, ES-DE
   metadata, and per-emulator saves (PCSX2, DuckStation, RPCS3, Dolphin
   GC/Wii, Cemu, RyuBing, Azahar, Vita3K, xemu, Flycast, melonDS, MAME,
   Ruffle, PrimeHack). Save options are filtered to only emulators actually
   present on this device, but locations that don't exist yet still get a
   "sync anyway?" prompt so future installs are picked up automatically.
8. **Per-console picker for ROMs.** First asks "Sync ALL consoles?" — if
   yes, skip the picker. Otherwise lists every ROM subfolder and lets you
   exclude consoles per-device (e.g. skip PS3 ROMs on the Steam Deck — too
   big). Excluded consoles go into `.stignore` on this device only — the
   NAS still gets all your ROMs from your other devices.
9. **Ignore permissions** toggle (default on). Cross-OS sync (Windows → ZFS
   on TrueNAS, exFAT cards, Android) often stalls because the receiver
   can't apply Unix mode bits. Default-on avoids that.
10. **Sync direction.** First device or adding to existing? Adding defaults
    to receive-only with a reminder to flip to two-way after first sync
    completes. First-device picks Two-way / Send only / Receive only and
    can apply per-folder.
11. **Apply.** Idempotent create-or-update on both local and NAS Syncthing.
    Versioning automatically enabled on saves/states (5 versions kept).
    Existing device lists on folders are *merged*, not replaced, so adding
    a new device doesn't accidentally unshare existing ones.
12. **Profile saved** to `~/.config/retrosync/profile.json` (Linux, chmod
    600) or `%APPDATA%\RetroSync\profile.json` (Windows, per-user APPDATA).

---

## Multi-user

Each user just runs the script with a different username. Their data lives
in its own subfolder on the NAS:

```text
/mnt/tank/emulation/
├── alice/
│   ├── roms/
│   ├── saves/
│   └── …
└── bob/
    ├── roms/
    └── …
```

Users do not share folders unless they explicitly add each other in the
Syncthing GUI — RetroSync only pairs your client with the NAS.

For single-user (the default), data goes directly under `{nas_base}/`
without a username layer, and folder IDs are just `retrosync-<scope>`.

---

## Re-running

Re-run the script any time you want to:

- Add or remove consoles
- Add a newly installed emulator's saves
- Connect a new client device (run the script on the new device)
- Change sync direction for a folder (e.g. flip "Adding" device to two-way
  after first sync completes)

The script remembers your previous answers via the profile JSON. The
existing-profile path skips the questions whose answers are already known
(frontend, NAS address, multi-user choice, API-key storage method) and only
re-asks the things that might change (sync scopes, direction).

---

## Special handling

- **Cross-OS Permissions:** RetroSync automatically configures Syncthing to
  ignore file permissions by default. This prevents "Out of Sync" stalls
  when moving files between Windows (NTFS), Linux (ext4/btrfs), and NAS
  systems (ZFS).
- **Secure Key Storage:** Both scripts default to encrypting your NAS API
  key at rest. Windows uses DPAPI; Linux uses libsecret if your desktop's
  keyring is reachable, otherwise falls back to a DPAPI-equivalent
  machine-bound AES-256 encryption via openssl.
- **PS3 (RPCS3)** — Only `savedata/` and `trophy/` sync. Installed game
  data (`dev_hdd0/game/`) does not — it's too large and device-specific.
  You install PS3 games separately on each device.
- **Wii (Dolphin)** — The full Wii NAND syncs, including your Mii
  characters (`RFL_DB.dat`).
- **PS1 dual-emulator warning** — If both DuckStation/SwanStation saves
  *and* RetroArch PCSX-ReARMed saves exist on the same device, the script
  warns that the formats are not cross-compatible. Pick one PS1 emulator
  and stick with it across devices.
- **Save versioning** — All saves and save states get Simple Versioning
  (5 versions kept) on the NAS side. If a save gets corrupted, you can
  recover the previous version from the NAS Syncthing GUI under that
  folder's "Versions".
- **Large console warnings** — PS3, Switch, Wii, Wii U, original Xbox, and
  Xbox 360 are flagged at the per-console picker with their estimated
  per-game sizes. The warning is informational; defaults still favor
  syncing so you don't accidentally skip them by pressing Enter.
- **"Adding a device" mode** — If you pick `[2] Adding to existing setup`,
  the script auto-locks the direction to Receive only so this device
  pulls from the NAS without overwriting it. After the first full sync,
  re-run the script and pick a Two-way direction at the prompt to enable
  bidirectional sync.

---

## Profile JSON

```json
{
  "version": "1.0",
  "device_name": "htpc",
  "frontend": "retrodeck",
  "frontend_base_path": "/home/user/retrodeck",
  "multi_user": false,
  "username": "",
  "ignore_perms": true,
  "created_at": "2026-01-15T10:00:00Z",
  "updated_at": "2026-01-15T10:00:00Z",
  "local_syncthing": {
    "address": "http://localhost:8384",
    "device_id": "AAAAAAA-..."
  },
  "nas_syncthing": {
    "url": "http://192.168.1.50:8384/rest",
    "address": "192.168.1.50:8384",
    "api_key_storage": "openssl-machine",
    "api_key": "U2FsdGVkX1+...",
    "nas_base": "/Retrosync",
    "device_id": "BBBBBBB-...",
    "sync_tcp_port": 22000,
    "sync_udp_port": 22000
  },
  "folders": [
    {
      "id": "retrosync-roms",
      "name": "ROMs",
      "local_path": "/home/user/retrodeck/roms",
      "nas_path": "/Retrosync/roms",
      "type": "sendreceive",
      "versioning": false,
      "ignore_patterns": ["/ps3", "/wii"]
    }
  ]
}
```

The `api_key` field depends on `api_key_storage`:

| Storage | `api_key` value | Cross-machine portable? |
|---|---|---|
| `plaintext` | raw key | yes (anyone with the file can read it) |
| `dpapi` (Windows) | DPAPI blob | no — decryptable only by the same Windows user on the same machine |
| `libsecret` (Linux) | empty; key lives in keyring | no — keyring is per-machine, per-user |
| `openssl-machine` (Linux) | base64 AES-256 blob | no — decryptable only by the same UID on the same `/etc/machine-id` |
| `prompt` | empty | trivially yes; you re-type each run anyway |

**Treat this file like a password.** Don't commit it to git. Don't share
screenshots. The Linux script `chmod 600`s it on save; on Windows it sits
in your per-user APPDATA which other accounts can't read by default.

---

## Troubleshooting

**"Could not find Syncthing config.xml"**
Syncthing has never been started on this device. Start it once, wait for it
to generate `config.xml`, then re-run.

**"Local Syncthing is not responding"**
Check that the Syncthing service is running. On Linux:
`systemctl --user status syncthing.service`. On Windows, check the system
tray for the Syncthing icon.

**"NAS connection failed - couldn't talk to Syncthing"**
Most common cause: wrong port. Use the Syncthing Web UI port (default
8384), *not* the data-transfer port 22000. Also verify the address is
reachable, the NAS firewall allows inbound 8384, and the API key was
copied correctly from the NAS Syncthing web UI.

**Folders sync via "relay" (single-digit Mbps on a gigabit LAN)**
Means ports 22000/tcp + 22000/udp aren't reachable to the NAS Syncthing
process. On TrueNAS Scale, add those port mappings in the Syncthing app's
config. The script pins the NAS's direct LAN address, so as soon as the
ports are reachable the connection switches to `tcp-lan` or `quic-lan`.

**"Out of Sync" stuck forever**
Open the folder in the Syncthing Web UI and check "Failed items." Two
common causes:
- **Mode-bit conflicts** — the `ignore_perms: true` toggle (default on)
  prevents this. If you turned it off, turn it back on.
- **Case collisions** — Linux has two files differing only in capitals,
  Windows can't hold both. Rename one of them on the Linux side.

**"pull: no such file" errors**
Usually a side effect of a previous case-collision or path mismatch.
After fixing the underlying issue, force a rescan or click "Override
Changes" on the receive-only side.

**"Permission denied" on the NAS path**
The Syncthing process inside the NAS container needs write access to the
mounted path. Check that the container's user has read+write on the
storage location.

**Setup script reports "DELETE returned HTTP 0" or hangs**
This was a bug in pre-v0.2.0 versions when removing a device. v0.2.0+
uses a two-pass PATCH-then-DELETE that handles the timeout case
gracefully. If you're on an older version, upgrade and re-run.

---

## Known limitations

- v0.3 supports RetroDECK and RetroBat with auto-detection, plus a
  custom-locations mode for any other frontend (EmuDeck, standalone ES-DE,
  Batocera, Lakka, plain RetroArch, custom layouts). First-class support
  for EmuDeck with auto-detection is planned.
- In custom mode, re-running the script does not re-prompt for paths or
  let you add new emulator save folders interactively — it re-applies the
  paths from the saved profile. To add a new path, either edit
  `profile.json` directly or use `[3] Remove this device from sync` and
  re-setup.
- The script does not install Syncthing for you. It assumes Syncthing is
  already running.
- The script does not create the NAS-side mount path. You must mount your
  host storage into the Syncthing container first (TrueNAS Scale / Docker
  / Unraid). The script only configures Syncthing folders relative to that
  mount.
- Game-specific data outside save files (PS3 game installs, Wii U installed
  games, Switch firmware) is not synced — too big, often legally
  encumbered, and device-specific.
- Cross-frontend sync (RetroBat ↔ RetroDECK) supports a subset of scopes
  only — see the "Cross-OS sync" table above.
- The Steam Deck Game Mode integration depends on a working Syncthing
  service — see the [Decky Loader Syncthing
  plugin](https://github.com/theCapypara/steamdeck-decky-syncthing) for
  the easiest setup.

---

## Contributing

PRs and issues welcome. Particularly useful would be:

- EmuDeck (Linux) and EmuDeck (Windows) directory trees from a real install
- Standalone ES-DE directory tree
- Confirmed save paths for emulators not yet in `consols-info.json`
- Bug reports from devices we haven't tested
- A cross-frontend path-translation layer built on top of `consols-info.json`

---

## License

[MIT](LICENSE)
