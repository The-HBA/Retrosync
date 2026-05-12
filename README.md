# Retrosync
Retrosync is a script that automates the process of creating syncthing connections to sync/backup your roms, bios, saves, states, ES-DE gamelists and media.

> **Note:** To be fully transperent, this project is made using artificial intelligence, I welcome any help or even taking over the project. Currently the project depends on the user already having syncthing running in the background, and it only designed with RetroDECK and RetroBat file structure in mind. In the future it could be a full on app and container stack.

Configure [Syncthing](https://syncthing.net) to keep your retro gaming files —
ROMs, BIOS, saves, save states, and ES-DE metadata — in sync between your
client devices and a central NAS hub. One interactive setup, idempotent
re-runs, and the GUI stays untouched.

> **Status:** v0.2.0 — Windows ↔ Windows (RetroBat) syncing is stable. Currently testing Linux ↔ Linux (RetroDECK) and cross-OS syncing! Please open an issue if anything breaks. Feel free to contribute or build on the idea.

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

## v0.2.0 scope

| Frontend | Status |
|---|---|
| RetroBat (Windows)                     | ✅ Supported (Stable) |
| RetroDECK (Linux Flatpak)              | ✅ Supported (Testing) |
| EmuDeck (Linux)                        | 🔜 Planned |
| EmuDeck (Windows)                      | 🔜 Planned |
| Standalone ES-DE                       | ❓ Not on roadmap; PRs welcome |
| Batocera, Lakka, RecalBox              | ❓ Not on roadmap; PRs welcome |

---

## Prerequisites

1. **Syncthing installed and started at least once** on every device,
   including the NAS. The script reads the local API key from Syncthing's
   `config.xml` — that file only exists after the first run.
2. **One empty top-level directory** on your NAS to hold all synced data
   (e.g. `/mnt/tank/emulation`). The script will create everything underneath.
3. **Your NAS Syncthing API key** — copy it from the NAS Syncthing web UI:
   *Actions → Settings → API Key*.
4. **Bash 4.0+** with `curl` and `jq` (Linux), or **PowerShell 5.1+** (Windows).

### Installing Syncthing
> Please check their official website for up to date download guides

| Platform | How |
|---|---|
| Steam Deck (Game Mode) | [Decky Plugin: Syncthing](https://github.com/theCapypara/steamdeck-decky-syncthing) or Flatpak via Discover in Desktop Mode |
| Windows / Linux | <https://syncthing.net/downloads/> — installer |
| TrueNAS SCALE | Apps → Discover → Syncthing |
| Unraid | Community Apps → Syncthing |
| Synology | Package Center (third-party source) or Docker |


---

## Usage

⚠️ ALERT!

**Do not run any script you find on the internet unless you verify it is safe to run.**

Running unverified scripts (like .sh, .ps1, .bat, or .py files) gives third-party code direct permission to execute commands on your machine. Malicious scripts can easily:
- Steal personal data, credentials, and API keys.
- Install ransomware or background malware.
- Delete or permanently corrupt your files.
- Silently compromise your entire home network.

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

1. **Pre-flight.** Checks bash/PowerShell version, required tools, Syncthing
   reachable on `localhost:8384`, and auto-extracts your local Syncthing API key
   from `config.xml`.
2. **Profile detection.** If you've run RetroSync before, it offers to update
   or start fresh.
3. **Frontend selection.** RetroDECK or RetroBat. The script auto-detects the
   install path and lets you confirm or override.
4. **Username.** Your NAS subfolder will be `{nas_base}/{username}/`. Multiple
   users on the same NAS just pick different usernames.
5. **NAS connection.** Address, API key, base directory. The script verifies
   the connection, fetches both device IDs, and pairs the devices on both
   sides if they aren't already paired. API Keys can be securely stored using DPAPI (Windows) or `libsecret` keyring (Linux).
6. **Sync scope.** Pick what to sync: ROMs, BIOS, save states, ES-DE metadata,
   and per-emulator saves (PCSX2, DuckStation, Dolphin GC, Dolphin Wii NAND,
   RPCS3 savedata, etc.). Save options are filtered to only emulators
   actually present on this device.
7. **Per-console picker.** Lists every ROM subfolder and lets you exclude
   consoles per-device (e.g. skip PS3 ROMs on the Steam Deck — too big).
   Excluded consoles go into `.stignore` on this device only — the NAS still
   gets all your ROMs from your other devices.
8. **Sync direction.** Two-way (default), send-only (push only), or
   receive-only (pull only). Apply to all folders or per-folder.
9. **Apply.** Idempotent create-or-update on both local and NAS Syncthing.
   Versioning is automatically enabled on saves and save states (5 versions).
10. **Profile saved** to `~/.config/retrosync/profile.json`
    (`%APPDATA%\RetroSync\profile.json` on Windows).

---

## Multi-user

Each user just runs the script with a different username. Their data lives in
its own subfolder on the NAS:

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

---

## Re-running

Re-run the script any time you want to:

- Add or remove consoles
- Add a newly installed emulator's saves
- Connect a new client device (run the script on the new device)
- Change sync direction for a folder

The script remembers your previous answers via the profile JSON. It always
checks for existing folders by ID before adding — re-running will never create
duplicates.

---

## Special handling

- **Cross-OS Permissions:** RetroSync automatically configures Syncthing to ignore file permissions by default. This prevents "Out of Sync" stalls when moving files between Windows (NTFS), Linux (ext4/btrfs), and NAS systems (ZFS).
- **Secure Key Storage (Linux):** If you have `secret-tool` installed, the bash script can securely store your NAS API key in your desktop environment's system keyring instead of keeping it in plaintext.
- **PS3 (RPCS3)** — Only `savedata/` and `trophy/` sync. Installed game data
  (`dev_hdd0/game/`) does not — it's too large and device-specific. You install
  PS3 games separately on each device.
- **Wii (Dolphin)** — The full Wii NAND syncs, including your Mii characters
  (`RFL_DB.dat`).
- **PS1 dual-emulator warning** — If both DuckStation/SwanStation saves
  *and* RetroArch PCSX-ReARMed saves exist on the same device, the script warns
  that the formats are not cross-compatible. Pick one PS1 emulator and stick
  with it across devices.
- **Save versioning** — All saves and save states get Simple Versioning
  (5 versions kept) on the NAS side. If a save gets corrupted, you can recover
  the previous version from the NAS Syncthing GUI under that folder's "Versions".
- **Large console warnings** — PS3, Wii, Wii U, Switch, original Xbox, and
  Xbox 360 are flagged at the per-console picker; they default to *excluded*
  on each device because of ROM size.

---

## Profile JSON

```json
{
  "version": "1.0",
  "device_name": "htpc",
  "frontend": "retrodeck",
  "frontend_base_path": "/home/user/retrodeck",
  "username": "alice",
  "created_at": "2026-01-15T10:00:00Z",
  "updated_at": "2026-01-15T10:00:00Z",
  "local_syncthing": {
    "address": "http://localhost:8384",
    "device_id": "AAAAAAA-..."
  },
  "nas_syncthing": {
    "url": "[http://192.168.1.50:8384/rest](http://192.168.1.50:8384/rest)",
    "address": "192.168.1.50:8384",
    "api_key": "...",
    "nas_base": "/mnt/tank/emulation",
    "device_id": "BBBBBBB-..."
  },
  "folders": [
    {
      "id": "retrosync-alice-roms",
      "name": "ROMs",
      "local_path": "/home/user/retrodeck/roms",
      "nas_path": "/mnt/tank/emulation/alice/roms",
      "type": "sendreceive",
      "versioning": false,
      "ignore_patterns": ["/ps3", "/wii"]
    }
  ]
}
```

The profile contains your NAS API key. Treat it like a password — don't commit
it to git, don't share screenshots of it.

---

## Troubleshooting

**"Could not find Syncthing config.xml"**
Syncthing has never been started on this device. Start it once, wait for it
to generate `config.xml`, then re-run.

**"Local Syncthing is not responding"**
Check that the Syncthing service is running. On Linux:
`systemctl --user status syncthing.service`. On Windows, check the system
tray for the Syncthing icon.

**"NAS connection failed"**
Verify the NAS address (host:port) is correct, the NAS firewall allows
inbound connections on the Syncthing GUI port (8384 by default), and the API
key was copied correctly from the NAS Syncthing web UI. The script will let
you retry without restarting.

**Folders show up but nothing syncs**
Open the local Syncthing GUI (<http://localhost:8384>) and accept the
auto-shared folder if prompted. RetroSync configures sharing on both sides,
but the GUI sometimes needs a manual confirmation when a folder is first
introduced.

**"Permission denied" on the NAS path**
The NAS Syncthing process needs write access to your base directory. Check
ownership and permissions on the NAS side.

---

## Known limitations

- v0.2.x currently supports RetroDECK (Linux) and RetroBat (Windows).
- The script does not install Syncthing for you. It assumes Syncthing is
  already running.
- The script does not create the NAS base directory. Create one empty
  directory on your NAS first.
- Game-specific data outside save files (PS3 game installs, Wii U installed
  games, Switch firmware) is not synced.
- The Steam Deck Game Mode integration depends on a working Syncthing
  service — see the [Decky Loader Syncthing
  plugin](https://github.com/Maxraga/decky-syncthing) for the easiest
  setup.

---

## Contributing

PRs and issues welcome. Particularly useful would be:

- EmuDeck (Linux) and EmuDeck (Windows) directory trees from a real install
- Standalone ES-DE directory tree
- Confirmed paths for any frontend not yet supported
- Bug reports from devices we haven't tested

---

## License

[MIT](LICENSE)
