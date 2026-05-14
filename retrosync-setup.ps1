<#
.SYNOPSIS
    Configure Syncthing for retro-gaming sync between this Windows device
    (running RetroBat) and a central NAS hub via the Syncthing REST API.

.DESCRIPTION
    Supports: RetroBat on Windows, and a "custom locations" mode where the
    user enters absolute paths manually for each thing to sync (works with
    any frontend or no frontend at all).
    Project: https://github.com/<owner>/retrosync
    License: GPL-3.0

.PARAMETER DryRun
    Print every action without making API calls or filesystem changes.

.PARAMETER VerboseLog
    Print every API request URL, body, and response (use -VerboseLog to avoid
    clashing with PowerShell's built-in -Verbose preference).

.PARAMETER NoColor
    Disable colored output.

.PARAMETER ProfilePath
    Use a custom profile file (default: %APPDATA%\RetroSync\profile.json).

.EXAMPLE
    .\retrosync-setup.ps1

.EXAMPLE
    .\retrosync-setup.ps1 -DryRun -VerboseLog
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$VerboseLog,
    [switch]$NoColor,
    [string]$ProfilePath = "",
    [switch]$Version,
    [Alias('?')]
    [switch]$ShowHelp
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 1. Banner & version
# -----------------------------------------------------------------------------
$Script:RetroSyncVersion = '0.3.1'
$Script:RetroSyncName    = 'RetroSync'
$Script:FolderIdPrefix   = 'retrosync'

if ($Version) {
    Write-Host "$Script:RetroSyncName $Script:RetroSyncVersion"
    exit 0
}

if ($ShowHelp) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

# -----------------------------------------------------------------------------
# 2. PowerShell version + execution policy guards
# -----------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5 -or
    ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "$Script:RetroSyncName requires PowerShell 5.1 or later." -ForegroundColor Red
    Write-Host "  You have: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 1
}

$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq 'Restricted') {
    Write-Host "X PowerShell execution policy is Restricted. Run this first:" -ForegroundColor Red
    Write-Host "    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

# -----------------------------------------------------------------------------
# 3. Universal constants
# -----------------------------------------------------------------------------
$Script:SyncthingConfigCandidates = @(
    [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Syncthing', 'config.xml'),
    [System.IO.Path]::Combine($env:APPDATA,      'Syncthing', 'config.xml')
)

$Script:SyncthingLocalDefault = 'http://localhost:8384'
$Script:DefaultProfileDir     = [System.IO.Path]::Combine($env:APPDATA, 'RetroSync')
$Script:DefaultProfileFile    = [System.IO.Path]::Combine($Script:DefaultProfileDir, 'profile.json')
$Script:NasFolderPollTimeout  = 15
$Script:NasFolderPollInterval = 3

# -----------------------------------------------------------------------------
# 4. Frontend definitions - RetroBat (Windows)
# -----------------------------------------------------------------------------
# Paths verified against captured RetroBat directory tree.
# RetroBat is monolithic: everything lives under one root. The documented
# default install location is C:\RetroBat - we suggest that and let the user
# override at the prompt if they installed it elsewhere.
#
# Conventional RetroBat layout (relative to install root):
#   roms\<console>\
#   bios\
#   saves\<console>\<emulator>\
#   emulators\retroarch\saves\
#   emulators\retroarch\states\
#   emulationstation\.emulationstation\
$Script:RetrobatDefaultRoot = 'C:\RetroBat'

$Script:RB_ROMS_SUB           = 'roms'
$Script:RB_BIOS_SUB           = 'bios'
$Script:RB_SAVES_GENERAL_SUB  = 'saves'
$Script:RB_RA_SAVES_SUB       = 'emulators\retroarch\saves'
$Script:RB_RA_STATES_SUB      = 'emulators\retroarch\states'
$Script:RB_GAMELISTS_SUB      = 'emulationstation\.emulationstation'
# RetroBat has no separate downloaded_media root by default - ES-DE media lives
# inside the .emulationstation folder. We sync the whole ES folder for both.
$Script:RB_MEDIA_SUB          = 'emulationstation\.emulationstation'

# Per-emulator save subpaths relative to the install root.
# Format: PSCustomObject { Label; ConsoleId; SubPath; Notes }
# Verified against the captured RetroBat tree where present; others use
# RetroBat's documented saves\<system>\<emulator>\ convention.
$Script:RetrobatSaveLocations = @(
    [PSCustomObject]@{Label='RetroArch (all RA cores)'; ConsoleId='retroarch'; SubPath='emulators\retroarch\saves';        Notes='All RetroArch core saves'},
    [PSCustomObject]@{Label='PCSX2 (PS2)';              ConsoleId='ps2';       SubPath='saves\ps2\pcsx2\memcards';        Notes='PS2 memory cards'},
    [PSCustomObject]@{Label='DuckStation (PS1)';        ConsoleId='ps1';       SubPath='saves\psx\duckstation\memcards';  Notes='PS1 standalone memory cards'},
    [PSCustomObject]@{Label='RPCS3 savedata (PS3)';     ConsoleId='ps3';       SubPath='saves\ps3\rpcs3\dev_hdd0\home\00000001\savedata'; Notes='PS3 game saves only'},
    [PSCustomObject]@{Label='RPCS3 trophy (PS3)';       ConsoleId='ps3-trophy';SubPath='saves\ps3\rpcs3\dev_hdd0\home\00000001\trophy';   Notes='PS3 trophies'},
    [PSCustomObject]@{Label='Dolphin GC';               ConsoleId='gamecube';  SubPath='saves\gc\dolphin-emu\User\GC';    Notes='GameCube memory cards'},
    [PSCustomObject]@{Label='Dolphin Wii NAND';         ConsoleId='wii';       SubPath='saves\wii\dolphin-emu\User\Wii';  Notes='Full Wii NAND incl. Miis'},
    [PSCustomObject]@{Label='Cemu (Wii U)';             ConsoleId='wiiu';      SubPath='saves\wiiu\cemu\mlc01';            Notes='Cemu Wii U save data'},
    [PSCustomObject]@{Label='Ryujinx (Switch)';         ConsoleId='switch';    SubPath='saves\switch\ryujinx\portable';   Notes='Switch user data'},
    [PSCustomObject]@{Label='Flycast VMU (Dreamcast)';  ConsoleId='dreamcast'; SubPath='saves\dreamcast\flycast\vmu';     Notes='Dreamcast VMU saves'},
    [PSCustomObject]@{Label='melonDS (NDS)';            ConsoleId='nds';       SubPath='saves\nds\melonds';               Notes='NDS standalone saves'},
    [PSCustomObject]@{Label='Citra (3DS)';              ConsoleId='n3ds';      SubPath='saves\3ds\Citra';                 Notes='3DS Citra saves'}
)

# -----------------------------------------------------------------------------
# 4b. Custom-mode state - paths supplied by the user instead of a frontend layout
# -----------------------------------------------------------------------------
# In custom mode the user enters an absolute path for each thing they want to
# sync (blank = skip). Scope keys 'roms' and 'bios' stay bare so a custom-mode
# device can share those Syncthing folders with a RetroBat device on the same
# NAS. States/gamelists/media use custom-* keys because their on-disk layout
# is unknown and almost certainly won't match RetroBat's. Per-emulator saves
# reuse the same saves\<console_id> NAS subpath convention as RetroBat so
# format-compatible save folders (PCSX2 memcards, DuckStation memcards, etc.)
# can cross-sync between custom and RetroBat devices.
$Script:CustomRomsPath      = ''
$Script:CustomBiosPath      = ''
$Script:CustomStatesPath    = ''
$Script:CustomGamelistsPath = ''
$Script:CustomMediaPath     = ''
# Per-emulator saves in custom mode. Array of PSCustomObject {ConsoleId, LocalPath}.
$Script:CustomSavePaths     = @()

# -----------------------------------------------------------------------------
# 5. Console metadata - large-rom warnings, save incompatibilities
# -----------------------------------------------------------------------------
$Script:LargeRomConsoles = @(
    [PSCustomObject]@{Id='ps3';     Size='20-50GB per game'; Desc='very large'},
    [PSCustomObject]@{Id='switch';  Size='5-15GB per game';  Desc='large'},
    [PSCustomObject]@{Id='ps2';     Size='2-8GB per game';   Desc='medium-large'},
    [PSCustomObject]@{Id='wii';     Size='4-8GB per game';   Desc='large'},
    [PSCustomObject]@{Id='wiiu';    Size='10-25GB per game'; Desc='large'},
    [PSCustomObject]@{Id='xbox';    Size='4-8GB per game';   Desc='large'},
    [PSCustomObject]@{Id='xbox360'; Size='8-15GB per game';  Desc='large'}
)

# -----------------------------------------------------------------------------
# 6. Output helpers
# -----------------------------------------------------------------------------
$Script:UseColor = -not $NoColor -and -not [Console]::IsOutputRedirected

function Write-Color {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::White)
    if ($Script:UseColor) { Write-Host $Text -ForegroundColor $Color }
    else                  { Write-Host $Text }
}

function Write-Success { param([string]$M) Write-Color "[OK]  $M"  Green   }
function Write-Info    { param([string]$M) Write-Color "[i]   $M"  Cyan    }
function Write-Warn    { param([string]$M) Write-Color "[!]   $M"  DarkYellow }
function Write-WarnBlock {
    param([string[]]$Lines)
    if (-not $Lines -or $Lines.Count -eq 0) { return }
    Write-Color "[!]   $($Lines[0])" DarkYellow
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        Write-Color "      $($Lines[$i])" DarkYellow
    }
}
function Write-Prereq {
    # Yellow informational block. Use for "PREREQUISITE" notes and other
    # explanatory passages the user must read but isn't an alert.
    param([string[]]$Lines)
    foreach ($l in $Lines) {
        if ($Script:UseColor) { Write-Host $l -ForegroundColor Yellow }
        else                  { Write-Host $l }
    }
}
function Write-Err     { param([string]$M) Write-Color "[X]   $M"  Red     }
function Write-Verb    { param([string]$M) if ($VerboseLog) { Write-Color "[v]   $M" DarkGray } }
function Write-Dry     { param([string]$M) Write-Color "[DRY] $M"  Magenta }
function Write-Hr      { Write-Color ('=' * 63) DarkGray }

function Read-Prompt {
    param([string]$Question, [string]$Default = '')
    if ($Default) {
        $reply = Read-Host "$Question [$Default]"
        if ([string]::IsNullOrEmpty($reply)) { return $Default }
        return $reply
    }
    return Read-Host $Question
}

function Read-PromptYn {
    param([string]$Question, [string]$Default = 'n')
    while ($true) {
        $yPart = if ($Default -eq 'y') { 'Y' } else { 'y' }
        $nPart = if ($Default -eq 'n') { 'N' } else { 'n' }
        $reply = Read-Host "$Question [$yPart/$nPart]"
        if ([string]::IsNullOrEmpty($reply)) { $reply = $Default }
        switch -Regex ($reply.ToLower()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Color "  Please answer y or n." Yellow }
        }
    }
}

function Read-PromptSecret {
    param([string]$Question)
    $secure = Read-Host -Prompt $Question -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# -----------------------------------------------------------------------------
# API key storage (plaintext | dpapi | prompt)
#
# - plaintext: api_key is the raw key in profile.json. Simple, no extra deps.
#              File sits in %APPDATA%\RetroSync\ which is per-user already; the
#              real risk is accidental exposure (cloud sync, screenshot, git).
# - dpapi:     api_key is a DPAPI-encrypted blob. Decryptable only by the same
#              Windows user on the same machine - copying the file elsewhere
#              renders the blob useless. No extra deps; uses built-in cmdlets.
# - prompt:    nothing stored. We ask for the key on every run. Most secure,
#              least convenient.
# -----------------------------------------------------------------------------

function Read-ApiKeyStorageMode {
    Write-Host ""
    Write-Host "How should the NAS Syncthing API key be stored?"
    Write-Host ""
    Write-Host "    [1] Plaintext in profile.json"
    Write-Host "        Simple. The file is in your user's APPDATA so other"
    Write-Host "        Windows accounts can't read it. Risk: if you upload,"
    Write-Host "        commit, or share the file by accident, the key is"
    Write-Host "        visible."
    Write-Host ""
    Write-Host "    [2] Encrypted with DPAPI (recommended)"
    Write-Host "        Encrypted using your Windows user account. Decryptable"
    Write-Host "        only by you on this machine. profile.json holds an"
    Write-Host "        opaque blob; copying the file elsewhere makes it"
    Write-Host "        useless to whoever has it."
    Write-Host ""
    Write-Host "    [3] Don't store - prompt on every run"
    Write-Host "        Most secure. The key never touches disk. You'll re-type"
    Write-Host "        it each time the script runs."
    Write-Host ""
    while ($true) {
        $choice = Read-Prompt "Choice" "2"
        switch ($choice) {
            '1' { return 'plaintext' }
            '2' { return 'dpapi' }
            '3' { return 'prompt' }
            default { Write-Warn "Pick 1, 2, or 3." }
        }
    }
}

function Protect-ApiKeyForStorage {
    # Convert raw key into the form that should be written to profile.json.
    param([string]$Mode, [string]$Key)
    switch ($Mode) {
        'plaintext' { return $Key }
        'prompt'    { return '' }
        'dpapi' {
            $secure = ConvertTo-SecureString $Key -AsPlainText -Force
            return (ConvertFrom-SecureString $secure)
        }
        default { return $Key }
    }
}

function Unprotect-ApiKeyFromStorage {
    # Recover the raw key for use in this session, given the stored value.
    # Falls back to a fresh prompt if decryption fails (e.g. profile copied
    # from another machine/user).
    param([string]$Mode, [string]$Stored)
    switch ($Mode) {
        'plaintext' { return $Stored }
        'prompt'    { return (Read-PromptSecret "NAS Syncthing API key") }
        'dpapi' {
            try {
                $secure = ConvertTo-SecureString $Stored -ErrorAction Stop
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            } catch {
                Write-Warn "Couldn't decrypt the stored API key (was the profile copied"
                Write-Warn "from another user or machine?). Re-prompting..."
                return (Read-PromptSecret "NAS Syncthing API key")
            }
        }
        default { return $Stored }
    }
}

# -----------------------------------------------------------------------------
# 7. Syncthing API wrappers
# -----------------------------------------------------------------------------
# Globals consumed:
#   $Script:SyncthingLocalUrl, $Script:SyncthingLocalKey
#   $Script:SyncthingNasUrl,   $Script:SyncthingNasKey

function Invoke-SyncthingRequest {
    param(
        [Parameter(Mandatory)] [ValidateSet('local','nas')] [string]$Target,
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PUT','PATCH','DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Body = $null,
        [switch]$Silent
    )

    $url = if ($Target -eq 'local') { $Script:SyncthingLocalUrl } else { $Script:SyncthingNasUrl }
    $key = if ($Target -eq 'local') { $Script:SyncthingLocalKey } else { $Script:SyncthingNasKey }

    $fullUrl = "$url$Path"
    Write-Verb "$Method $fullUrl"
    if ($Body) { Write-Verb "  body: $($Body.Substring(0, [Math]::Min(120, $Body.Length)))" }

    if ($DryRun -and $Method -ne 'GET') {
        Write-Dry "$Method $fullUrl$(if ($Body) { ' (body: ' + $Body.Length + ' bytes)' })"
        return @{}
    }

    $headers = @{ 'X-API-Key' = $key }
    $params  = @{
        Uri             = $fullUrl
        Method          = $Method
        Headers         = $headers
        TimeoutSec      = 60
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }
    if ($Body) {
        $params['ContentType'] = 'application/json'
        $params['Body']        = $Body
    }

    try {
        $response = Invoke-RestMethod @params
        Write-Verb "  status: 2xx"
        return $response
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
        $msg = $_.Exception.Message
        if (-not $Silent) {
            Write-Err "Syncthing API $Method $Path failed (HTTP $status)"
            Write-Err "  $msg"
        } else {
            Write-Verb "  (silent) $Method $Path -> HTTP $status"
        }
        throw
    }
}

function Invoke-SyncthingGet    { param($T,$P,[switch]$Silent) Invoke-SyncthingRequest -Target $T -Method GET    -Path $P -Silent:$Silent }
function Invoke-SyncthingPost   { param($T,$P,$B)               Invoke-SyncthingRequest -Target $T -Method POST   -Path $P -Body $B }
function Invoke-SyncthingPut    { param($T,$P,$B,[switch]$Silent) Invoke-SyncthingRequest -Target $T -Method PUT    -Path $P -Body $B -Silent:$Silent }
function Invoke-SyncthingPatch  { param($T,$P,$B,[switch]$Silent) Invoke-SyncthingRequest -Target $T -Method PATCH  -Path $P -Body $B -Silent:$Silent }
function Invoke-SyncthingDelete { param($T,$P,[switch]$Silent) Invoke-SyncthingRequest -Target $T -Method DELETE -Path $P -Silent:$Silent }

# -----------------------------------------------------------------------------
# 8. Pre-flight checks
# -----------------------------------------------------------------------------

function Get-LocalSyncthingInfoFromConfig {
    # Walk SyncthingConfigCandidates. On the first readable config.xml,
    # extract the API key and the GUI <address> (port could be customised).
    # Returns a hashtable @{ Key=...; Address=... } or $null if no config found.
    foreach ($cfg in $Script:SyncthingConfigCandidates) {
        if (Test-Path -LiteralPath $cfg) {
            Write-Verb "Reading Syncthing config: $cfg"
            try {
                [xml]$xml = Get-Content -LiteralPath $cfg -ErrorAction Stop
                $key = $xml.configuration.gui.apikey
                if ($key) {
                    $addr = $xml.configuration.gui.address
                    if ($addr -is [array]) { $addr = $addr[0] }
                    return @{ Key = $key; Address = $addr }
                }
            } catch {
                Write-Verb "  failed to parse: $($_.Exception.Message)"
            }
        }
    }
    return $null
}

function Read-LocalSyncthingManual {
    # Fallback when auto-detect can't find config.xml. Asks for URL + API
    # key directly. Used for portable installs / custom ports / whatever.
    Write-Host ""
    Write-Host "You can still proceed by entering the connection details manually."
    Write-Host "Open Syncthing's Web UI (system tray icon or however you launch it)"
    Write-Host "and grab the URL bar + Actions -> Settings -> API Key."
    Write-Host ""

    $manualUrl = Read-Prompt "Local Syncthing Web UI address" "localhost:8384"
    if ($manualUrl -match '^https?://') {
        $Script:SyncthingLocalUrl = "$($manualUrl.TrimEnd('/'))/rest"
    } else {
        $Script:SyncthingLocalUrl = "http://$($manualUrl.TrimEnd('/'))/rest"
    }
    $Script:SyncthingLocalKey = Read-PromptSecret "Local Syncthing API key"
    if ([string]::IsNullOrEmpty($Script:SyncthingLocalKey)) {
        Write-Err "API key required. Aborting."
        exit 1
    }
}

function Test-LocalSyncthing {
    Write-Info "Checking local Syncthing..."
    $Script:SyncthingLocalUrl = $null
    $Script:SyncthingLocalKey = $null

    $info = Get-LocalSyncthingInfoFromConfig
    if ($info) {
        $Script:SyncthingLocalKey = $info.Key
        if ($info.Address) {
            $cleanAddr = ($info.Address -replace '0\.0\.0\.0','localhost')
            $Script:SyncthingLocalUrl = "http://$cleanAddr/rest"
        } else {
            $Script:SyncthingLocalUrl = "$Script:SyncthingLocalDefault/rest"
        }
    } else {
        # Auto-detect failed - fall back to manual entry rather than
        # hardcoding more search paths (portable installs etc.).
        Write-Warn "Could not find Syncthing config.xml in:"
        foreach ($p in $Script:SyncthingConfigCandidates) { Write-Warn "  - $p" }
        Write-Host ""
        Write-Host "Common reasons:"
        Write-Host "  - Syncthing hasn't been started yet on this machine"
        Write-Host "    (config.xml is created on first launch)."
        Write-Host "  - You're using a portable install whose config lives"
        Write-Host "    elsewhere."
        Write-Host "  - The GUI port was changed from 8384."
        Read-LocalSyncthingManual
    }

    # Verify connectivity. On failure, let the user fix the URL or key
    # without restarting the script.
    while ($true) {
        $ok = $false
        try {
            Invoke-SyncthingGet 'local' '/system/ping' | Out-Null
            $ok = $true
        } catch { $ok = $false }

        if ($ok) {
            $shownUrl = $Script:SyncthingLocalUrl -replace '/rest$',''
            Write-Success "Local Syncthing reachable at $shownUrl"
            return
        }

        $shownUrl = $Script:SyncthingLocalUrl -replace '/rest$',''
        Write-Host ""
        Write-Warn "Local Syncthing not responding at $shownUrl"
        Write-Host "  Check that:"
        Write-Host "    - Syncthing is running (system tray icon, or services.msc)"
        Write-Host "    - The URL above matches the address shown in Syncthing's Web UI"
        Write-Host "    - The API key matches Web UI -> Actions -> Settings -> API Key"
        Write-Host ""
        if (-not (Read-PromptYn "Retry with different connection details?" 'y')) {
            Write-Err "Cancelled."
            exit 1
        }
        $newUrl = Read-Prompt "Local Syncthing Web UI address" $shownUrl
        if ($newUrl -match '^https?://') {
            $Script:SyncthingLocalUrl = "$($newUrl.TrimEnd('/'))/rest"
        } else {
            $Script:SyncthingLocalUrl = "http://$($newUrl.TrimEnd('/'))/rest"
        }
        if (Read-PromptYn "Re-enter the API key too?" 'n') {
            $Script:SyncthingLocalKey = Read-PromptSecret "Local Syncthing API key"
        }
    }
}

# -----------------------------------------------------------------------------
# 9. Profile load/save
# -----------------------------------------------------------------------------

function Get-ProfileFile {
    if ($ProfilePath) { return $ProfilePath }
    return $Script:DefaultProfileFile
}

function Test-ProfileExists { Test-Path -LiteralPath (Get-ProfileFile) }

function Read-Profile {
    $file = Get-ProfileFile
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
}

function Save-Profile {
    param([Parameter(Mandatory)][object]$ProfileObj)
    $file = Get-ProfileFile
    $dir  = Split-Path -Parent $file

    if ($DryRun) {
        Write-Dry "Would save profile to $file"
        return
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $file) {
        Copy-Item -LiteralPath $file -Destination "$file.bak" -Force
    }
    $json = $ProfileObj | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $file -Value $json -Encoding UTF8
    Write-Success "Profile saved: $file"
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 1: profile detection
# -----------------------------------------------------------------------------

$Script:ExistingProfile = $null
$Script:ProfileMode     = 'fresh'

function Step-ProfileDetection {
    if (-not (Test-ProfileExists)) { return }

    $Script:ExistingProfile = Read-Profile

    while ($true) {
        Write-Host ""
        Write-Info "An existing $Script:RetroSyncName profile was found for this device:"
        Write-Host ("    Frontend:  {0}" -f $Script:ExistingProfile.frontend)
        if ($Script:ExistingProfile.username) {
            Write-Host ("    Username:  {0} (multi-user)" -f $Script:ExistingProfile.username)
        } else {
            Write-Host  "    Mode:      single-user"
        }
        Write-Host ("    NAS:       {0}" -f $Script:ExistingProfile.nas_syncthing.address)
        Write-Host ("    Folders:   {0} configured" -f $Script:ExistingProfile.folders.Count)
        Write-Host ""
        Write-Host "    [1] Show current configuration (read-only - what was set up last time)"
        Write-Host "    [2] Update - add or change folders (keeps existing config)"
        Write-Host "    [3] Start fresh - delete this device's profile and reconfigure"
        Write-Host "        (does NOT touch Syncthing on either side; pick [4] for that)"
        Write-Host "    [4] Remove this device from sync (clean up Syncthing on this"
        Write-Host "        device and on the NAS before re-running)"
        Write-Host "    [5] Exit"
        Write-Host ""
        $choice = Read-Prompt "Choice" "2"
        switch ($choice) {
            '1' { Show-CurrentConfig }
            '2' { $Script:ProfileMode = 'update'; return }
            '3' {
                if (Read-PromptYn "Really delete $Script:RetroSyncName profile and reconfigure?" 'n') {
                    if (-not $DryRun) { Remove-Item -LiteralPath (Get-ProfileFile) -Force }
                    $Script:ExistingProfile = $null
                    $Script:ProfileMode = 'fresh'
                    return
                }
            }
            '4' { $Script:ProfileMode = 'remove'; return }
            '5' { exit 0 }
            default { Write-Warn "Invalid choice: $choice" }
        }
    }
}

# Read-only dump of the saved profile, for users who pick option [1] at the
# re-run menu just to remember what they set up before deciding whether to
# update or remove. Touches no state and returns to the menu.
function Show-CurrentConfig {
    Write-Host ""
    Write-Hr
    Write-Color "$Script:RetroSyncName - Current Configuration" White
    Write-Hr
    Write-Host ""

    $p = $Script:ExistingProfile
    if ($p.frontend -eq 'custom') {
        Write-Host "  Frontend:        custom locations"
    } else {
        Write-Host ("  Frontend:        {0}" -f $p.frontend)
        Write-Host ("  Frontend base:   {0}" -f $p.frontend_base_path)
    }
    if ($p.multi_user) {
        Write-Host ("  Mode:            multi-user (username: {0})" -f $p.username)
    } else {
        Write-Host  "  Mode:            single-user"
    }
    Write-Host ("  NAS address:     {0}" -f $p.nas_syncthing.address)
    Write-Host ("  NAS base:        {0}" -f $p.nas_syncthing.nas_base)
    Write-Host ("  API key storage: {0}" -f $p.nas_syncthing.api_key_storage)
    $tcp = if ($p.nas_syncthing.sync_tcp_port) { $p.nas_syncthing.sync_tcp_port } else { 22000 }
    $udp = if ($p.nas_syncthing.sync_udp_port) { $p.nas_syncthing.sync_udp_port } else { 22000 }
    Write-Host ("  Sync ports:      {0}/tcp, {1}/udp" -f $tcp, $udp)
    Write-Host ("  Ignore perms:    {0}" -f $p.ignore_perms)
    Write-Host ("  Created:         {0}" -f $p.created_at)
    Write-Host ("  Updated:         {0}" -f $p.updated_at)
    Write-Host ("  Profile file:    {0}" -f (Get-ProfileFile))

    Write-Host ""
    $count = @($p.folders).Count
    Write-Host ("  Synced folders ({0}):" -f $count)
    if ($count -eq 0) {
        Write-Host "    (none)"
    } else {
        "{0,-26} {1,-14} {2,-12} {3}" -f 'Name','Direction','Versioning','Local Path' |
            ForEach-Object { Write-Host "    $_" }
        Write-Host ('    ' + ('-' * 70))
        foreach ($f in $p.folders) {
            $v = if ($f.versioning) { '5 versions' } else { 'off' }
            "{0,-26} {1,-14} {2,-12} {3}" -f $f.name, (Get-DirectionArrow $f.type), $v, $f.local_path |
                ForEach-Object { Write-Host "    $_" }
            Write-Host ("    {0,-26} {1,-14} {2,-12} NAS: {3}" -f '','','', $f.nas_path)
            $ign = @($f.ignore_patterns)
            if ($ign.Count -gt 0) {
                Write-Host ("    {0,-26} {1,-14} {2,-12} ignored: {3}" -f '','','', ($ign -join ','))
            }
        }
    }

    Write-Host ""
    Write-Hr
    Read-Prompt "Press Enter to return to the menu" '' | Out-Null
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 2: frontend selection
# -----------------------------------------------------------------------------

$Script:Frontend     = $null
$Script:FrontendBase = $null

function Step-FrontendSelection {
    if ($Script:ExistingProfile) {
        $Script:Frontend     = $Script:ExistingProfile.frontend
        $Script:FrontendBase = $Script:ExistingProfile.frontend_base_path
        if ($Script:Frontend -eq 'custom') {
            Write-Info "Using saved frontend: custom locations"
            Restore-CustomStateFromProfile
        } else {
            Write-Info "Using saved frontend: $Script:Frontend at $Script:FrontendBase"
        }
        return
    }

    Write-Host ""
    Write-Host "Which retro gaming frontend are you using on this device?"
    Write-Host ""
    Write-Host "    [1] RetroBat (Windows)"
    Write-Host "    [2] Custom locations  (manually enter the path for each thing to sync)"
    Write-Host ""
    Write-Host "  Pick [2] if you run any non-RetroBat frontend on Windows (EmuDeck,"
    Write-Host "  standalone ES-DE, LaunchBox, plain RetroArch, custom layouts) or"
    Write-Host "  if your save folders live somewhere other than the default"
    Write-Host "  RetroBat layout. RetroDECK users should use retrosync-setup.sh"
    Write-Host "  on Linux."
    Write-Host ""
    $choice = Read-Prompt "Choice" "1"
    switch ($choice) {
        '1' { $Script:Frontend = 'retrobat'; Find-RetrobatBase }
        '2' { $Script:Frontend = 'custom';   Read-CustomPaths }
        default {
            Write-Err "Invalid choice: $choice."
            exit 1
        }
    }
}

function Find-RetrobatBase {
    Write-Host ""
    Write-Host "RetroBat is typically installed at C:\RetroBat."
    Write-Host "If yours is elsewhere (D:\, another drive, custom path), enter the full path."
    $Script:FrontendBase = Read-Prompt "RetroBat install directory" $Script:RetrobatDefaultRoot

    if (-not (Test-Path -LiteralPath $Script:FrontendBase)) {
        Write-Warn "Path does not exist yet: $Script:FrontendBase"
        if (-not (Read-PromptYn "Continue anyway? (Syncthing will create it on first sync)" 'y')) {
            Write-Err "Cancelled."
            exit 1
        }
    }
    Write-Success "Using RetroBat base: $Script:FrontendBase"
}

# Custom mode: ask the user for an absolute path per scope (blank = skip),
# then for an absolute path per known emulator's save folder (blank = skip).
# Populates the $Script:Custom* state used by the scope builder and saves
# picker.
function Read-CustomPaths {
    Write-Host ""
    Write-Host "Custom locations mode."
    Write-Host ""
    Write-Host "Enter the absolute path for each thing you want to sync."
    Write-Host "Leave a prompt blank to skip that entry. Examples:"
    Write-Host "  D:\Games\ROMs"
    Write-Host "  $env:USERPROFILE\Emulation\BIOS"
    Write-Host ""
    Write-Info "Each path can point to anywhere - local drive, external drive,"
    Write-Info "network share. Only entries you fill in will be synced."
    Write-Host ""

    # Custom mode has no single root, so FrontendBase stays empty. The scope
    # builder emits absolute paths in the LocalSub field and Step-ApplyAll
    # detects that and skips the Join-Path.
    $Script:FrontendBase = ''

    $Script:CustomRomsPath      = Read-Prompt "Path to ROMs folder (blank to skip)"            ''
    $Script:CustomBiosPath      = Read-Prompt "Path to BIOS folder (blank to skip)"            ''
    $Script:CustomStatesPath    = Read-Prompt "Path to save states folder (blank to skip)"     ''
    $Script:CustomGamelistsPath = Read-Prompt "Path to ES-DE gamelists folder (blank to skip)" ''
    $Script:CustomMediaPath     = Read-Prompt "Path to ES-DE downloaded media (blank to skip)" ''

    # Strip trailing slashes/backslashes so subsequent joins don't end up with \\.
    $Script:CustomRomsPath      = $Script:CustomRomsPath.TrimEnd('\','/')
    $Script:CustomBiosPath      = $Script:CustomBiosPath.TrimEnd('\','/')
    $Script:CustomStatesPath    = $Script:CustomStatesPath.TrimEnd('\','/')
    $Script:CustomGamelistsPath = $Script:CustomGamelistsPath.TrimEnd('\','/')
    $Script:CustomMediaPath     = $Script:CustomMediaPath.TrimEnd('\','/')

    Write-Host ""
    Write-Host "Per-emulator save folders."
    Write-Host "Enter the absolute path to each emulator's save directory."
    Write-Host "Blank = skip that emulator."
    Write-Host ""

    foreach ($entry in $Script:RetrobatSaveLocations) {
        $path = Read-Prompt "  $($entry.Label)" ''
        $path = $path.TrimEnd('\','/')
        if (-not [string]::IsNullOrEmpty($path)) {
            $Script:CustomSavePaths += [PSCustomObject]@{
                ConsoleId = $entry.ConsoleId
                LocalPath = $path
            }
        }
    }

    $count = 0
    foreach ($p in @($Script:CustomRomsPath, $Script:CustomBiosPath,
                     $Script:CustomStatesPath, $Script:CustomGamelistsPath,
                     $Script:CustomMediaPath)) {
        if (-not [string]::IsNullOrEmpty($p)) { $count++ }
    }
    $count += $Script:CustomSavePaths.Count

    if ($count -eq 0) {
        Write-Err "No paths entered - nothing to sync. Re-run and supply at least one path."
        exit 1
    }

    Write-Host ""
    Write-Success "Collected $count custom path(s)."
}

# Re-run with Frontend=custom: rebuild $Script:Custom* state from the saved
# folders[] so the rest of the flow doesn't re-prompt for paths.
function Restore-CustomStateFromProfile {
    $savedUser = if ($Script:ExistingProfile.PSObject.Properties['username']) {
        $Script:ExistingProfile.username
    } else { '' }
    if ($null -eq $savedUser) { $savedUser = '' }

    foreach ($folder in @($Script:ExistingProfile.folders)) {
        $id = $folder.id
        $lp = $folder.local_path
        # Strip the universal "retrosync-" prefix.
        $key = $id
        if ($key.StartsWith("$Script:FolderIdPrefix-")) {
            $key = $key.Substring("$Script:FolderIdPrefix-".Length)
        }
        # Multi-user profiles also have the username prefix; drop that too.
        if (-not [string]::IsNullOrEmpty($savedUser) -and
            $key.StartsWith("$savedUser-")) {
            $key = $key.Substring("$savedUser-".Length)
        }
        switch -Regex ($key) {
            '^roms$'             { $Script:CustomRomsPath      = $lp; break }
            '^bios$'             { $Script:CustomBiosPath      = $lp; break }
            '^custom-states$'    { $Script:CustomStatesPath    = $lp; break }
            '^custom-gamelists$' { $Script:CustomGamelistsPath = $lp; break }
            '^custom-media$'     { $Script:CustomMediaPath     = $lp; break }
            '^save-(.+)$' {
                $Script:CustomSavePaths += [PSCustomObject]@{
                    ConsoleId = $Matches[1]
                    LocalPath = $lp
                }
                break
            }
        }
    }
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 3: NAS layout (multi-user + username + base dir)
# -----------------------------------------------------------------------------

$Script:MultiUser = $false
$Script:Username  = ''

function Get-FolderId {
    param([string]$Key)
    if ($Script:MultiUser) { return "$Script:FolderIdPrefix-$Script:Username-$Key" }
    return "$Script:FolderIdPrefix-$Key"
}

function Get-NasUserRoot {
    if ($Script:MultiUser) { return "$Script:NasBaseDir/$Script:Username" }
    return $Script:NasBaseDir
}

function Step-NasLayout {
    if ($Script:ExistingProfile) {
        $savedMulti = $Script:ExistingProfile.multi_user
        if ($null -eq $savedMulti) {
            # v0.1.0 profiles had no multi_user field; legacy behavior was always multi-user.
            $savedMulti = -not [string]::IsNullOrEmpty($Script:ExistingProfile.username)
        }
        $Script:MultiUser  = [bool]$savedMulti
        $Script:Username   = if ($Script:MultiUser) { $Script:ExistingProfile.username } else { '' }
        $Script:NasBaseDir = $Script:ExistingProfile.nas_syncthing.nas_base
        $modeLabel = if ($Script:MultiUser) { "multi-user (username: $Script:Username)" } else { 'single-user' }
        Write-Info "Using saved layout: $modeLabel"
        Write-Info "  NAS base: $Script:NasBaseDir"
        return
    }

    Write-Host ""
    Write-Host "Will more than one person share this NAS for retro-gaming sync?"
    Write-Host ""
    Write-Host "  [N] Single user (recommended for personal setups)"
    Write-Host "      Files go directly under your NAS base directory."
    Write-Host "      Example with base = /Retrosync:"
    Write-Host "          /Retrosync/roms/<console>/..."
    Write-Host "          /Retrosync/saves/..."
    Write-Host "          /Retrosync/bios/..."
    Write-Host ""
    Write-Host "  [Y] Multiple users (e.g. you and a partner share the NAS)"
    Write-Host "      Each person gets their own subfolder so saves stay separate."
    Write-Host "      Example with base = /Retrosync:"
    Write-Host "          /Retrosync/alice/roms/..."
    Write-Host "          /Retrosync/alice/saves/..."
    Write-Host "          /Retrosync/bob/roms/..."
    Write-Host "      You'll be asked to pick a username next."
    Write-Host ""
    $Script:MultiUser = Read-PromptYn "Multi-user setup?" 'n'

    if ($Script:MultiUser) {
        Write-Host ""
        Write-Host "Pick a name for your personal subfolder on the NAS."
        Write-Host "Letters, numbers, hyphens and underscores only. No spaces. Max 32 chars."
        while ($true) {
            $u = Read-Prompt "Username"
            if ([string]::IsNullOrEmpty($u))     { Write-Warn "Username cannot be empty."; continue }
            if ($u.Length -gt 32)                { Write-Warn "Username too long (max 32 chars)."; continue }
            if ($u -notmatch '^[A-Za-z0-9_-]+$') { Write-Warn "Letters, numbers, hyphens, underscores only."; continue }
            $Script:Username = $u
            break
        }
        Write-Success "Username set: $Script:Username"
    }

    Write-Host ""
    Write-Host "Enter the path Syncthing INSIDE the NAS will use for retro-data."
    Write-Host ""
    Write-Prereq @(
        "  Reminder: this is the path Syncthing's process sees, NOT the host",
        "  filesystem path. If your Syncthing runs in a container, this is the",
        "  container-internal mount path you chose during setup (per the",
        "  prerequisites above). Native install? Use any host path Syncthing",
        "  can write to."
    )
    Write-Host ""
    Write-Host "  Containerized examples:  /Retrosync   /data/emulation"
    Write-Host "  Native install examples: /mnt/tank/retro-data   /srv/sync"
    Write-Host ""
    Write-Host "If you enter /Retrosync, files will end up (as Syncthing sees them) at:"
    if ($Script:MultiUser) {
        Write-Host "    /Retrosync/$Script:Username/roms/<console>/..."
        Write-Host "    /Retrosync/$Script:Username/saves/..."
        Write-Host "    /Retrosync/$Script:Username/bios/..."
    } else {
        Write-Host "    /Retrosync/roms/<console>/..."
        Write-Host "    /Retrosync/saves/..."
        Write-Host "    /Retrosync/bios/..."
    }
    Write-Host ""
    while ($true) {
        $base = Read-Prompt "Base directory on NAS (container-internal)" "/Retrosync"
        if ([string]::IsNullOrEmpty($base) -or $base.Substring(0,1) -ne '/') {
            Write-Warn "Path must be absolute (start with /), as Syncthing sees it inside the container."
            continue
        }
        $Script:NasBaseDir = $base.TrimEnd('/')
        break
    }
    Write-Success "NAS base set: $(Get-NasUserRoot)"
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 4: NAS connection
# -----------------------------------------------------------------------------

$Script:SyncthingNasUrl     = $null
$Script:SyncthingNasKey     = $null  # raw key, in-memory only
$Script:ApiKeyStorageMode   = 'plaintext'  # plaintext | dpapi | prompt
$Script:NasBaseDir          = $null
$Script:LocalDeviceId       = $null
$Script:NasDeviceId         = $null
$Script:NasSyncTcpPort      = 22000
$Script:NasSyncUdpPort      = 22000

function Test-NasReachable {
    # Verify the endpoint is actually Syncthing's REST API (not a stray
    # web UI on port 80, etc.) by checking that ping returns {"ping":"pong"}.
    try {
        $resp = Invoke-SyncthingGet 'nas' '/system/ping'
        if ($resp -and $resp.ping -eq 'pong') { return $true }
        Write-Verb "  ping endpoint returned unexpected payload (not Syncthing?)"
        return $false
    } catch { return $false }
}

function Format-NasUrl {
    param([string]$RawAddr)
    # Accepts: "10.0.0.5", "10.0.0.5:8384", "http://nas.local:8384", "https://nas/"
    # Returns the canonical "<scheme>://<host>:<port>/rest" form.
    # Defaults the port to 8384 (Syncthing REST/WebUI), since users frequently
    # confuse it with 22000 (data transfer) or leave it off entirely.
    $scheme = 'http'
    $rest = $RawAddr
    if ($RawAddr -match '^(https?)://(.+)$') {
        $scheme = $matches[1]
        $rest = $matches[2]
    }
    $rest = $rest.TrimEnd('/')
    $hostPart = ($rest -split '/', 2)[0]
    if ($hostPart -notmatch ':\d+$') {
        $hostPart = "${hostPart}:8384"
    }
    return "${scheme}://${hostPart}/rest"
}

function Step-NasConnection {
    if ($Script:ExistingProfile -and $Script:ExistingProfile.nas_syncthing.url) {
        $Script:SyncthingNasUrl = $Script:ExistingProfile.nas_syncthing.url
        # Storage mode defaults to plaintext for older profiles that predate
        # this field, since that's how they were written.
        $savedMode = $Script:ExistingProfile.nas_syncthing.api_key_storage
        if (-not $savedMode) { $savedMode = 'plaintext' }
        $Script:ApiKeyStorageMode = $savedMode
        $storedValue = $Script:ExistingProfile.nas_syncthing.api_key
        $Script:SyncthingNasKey = Unprotect-ApiKeyFromStorage -Mode $savedMode -Stored $storedValue

        if ($Script:ExistingProfile.nas_syncthing.sync_tcp_port) {
            $Script:NasSyncTcpPort = [int]$Script:ExistingProfile.nas_syncthing.sync_tcp_port
        }
        if ($Script:ExistingProfile.nas_syncthing.sync_udp_port) {
            $Script:NasSyncUdpPort = [int]$Script:ExistingProfile.nas_syncthing.sync_udp_port
        }
        $modeLabel = switch ($savedMode) {
            'plaintext' { 'plaintext in profile' }
            'dpapi'     { 'DPAPI-encrypted' }
            'prompt'    { 're-prompted just now' }
            default     { $savedMode }
        }
        Write-Info "Using saved NAS connection: $Script:SyncthingNasUrl"
        Write-Info "  API key storage: $modeLabel"
        Write-Info "  Saved sync ports: TCP $Script:NasSyncTcpPort, UDP $Script:NasSyncUdpPort"
        if ($Script:SyncthingNasKey -and (Test-NasReachable)) {
            Set-DeviceIds
            Set-DevicePairing
            return
        }
        Write-Warn "Saved NAS connection failed - re-prompting."
    }

    Write-Host ""
    Write-Host "Before continuing, make sure you've prepared the NAS side:"
    Write-Host ""
    Write-Prereq @(
        "  PREREQUISITE - Syncthing running:",
        "    Syncthing is installed and started on your NAS, and you can",
        "    open its Web UI from a browser on this device."
    )
    Write-Host ""
    Write-Prereq @(
        "  PREREQUISITE - storage path:",
        "    Most NAS setups (TrueNAS Scale apps, Docker, Unraid, Synology)",
        "    run Syncthing in a container that can ONLY see paths mounted",
        "    into it. Before continuing:",
        "      1. Create a directory on your NAS storage pool (e.g.",
        "         /mnt/tank/retro-data on the host).",
        "      2. Mount that host directory into the Syncthing container",
        "         at a chosen path (e.g. /Retrosync), with read+write",
        "         permissions for the user Syncthing runs as.",
        "      3. Restart the Syncthing app so the mount is active.",
        "    Skip steps 2-3 if Syncthing is installed natively on the NAS -",
        "    any path the Syncthing user can write to will work."
    )
    Write-Host ""
    Write-Prereq @(
        "  PREREQUISITE - ports exposed (for direct LAN sync, not relay):",
        "    Make sure these ports are reachable from this device to the NAS",
        "    Syncthing process. On TrueNAS Scale / Docker / Unraid, these",
        "    must be exposed by the container to the host network:",
        "      - 8384/tcp   Web UI / REST API (you'll enter the address",
        "                   below).",
        "      - 22000/tcp  Sync data (TCP).  -- default; you'll be asked",
        "      - 22000/udp  Sync data (QUIC). -- to confirm the ports.",
        "    If you've kept Syncthing's defaults, you don't need to change",
        "    these numbers - just expose 22000/tcp and 22000/udp on your NAS.",
        "    If you customized them in the Syncthing config, the script will",
        "    ask for the actual ports next."
    )
    Write-Host ""
    Write-Prereq @(
        "  PREREQUISITE - API key:",
        "    Get your NAS Syncthing API key from the Syncthing Web UI:",
        "    Actions -> Settings -> API Key. You'll be prompted for it next."
    )
    Write-Host ""
    Read-Host "Press Enter when ready" | Out-Null

    while ($true) {
        Write-Host ""
        Write-Host "Enter the NAS Syncthing Web UI / REST API address."
        Write-Host "  Use the Web UI port (default 8384) - NOT the data-transfer port (22000)."
        Write-Host "  If you omit the port, 8384 is assumed."
        Write-Host "  Examples:  192.168.1.50:8384"
        Write-Host "             192.168.1.50          (port defaults to 8384)"
        Write-Host "             nas.local:8384"
        $addr = Read-Prompt "NAS address"
        if ([string]::IsNullOrEmpty($addr)) { Write-Warn "Address cannot be empty."; continue }
        $Script:SyncthingNasUrl = Format-NasUrl $addr
        Write-Verb "Resolved NAS URL: $Script:SyncthingNasUrl"

        $Script:SyncthingNasKey = Read-PromptSecret "NAS Syncthing API key"
        if ([string]::IsNullOrEmpty($Script:SyncthingNasKey)) { Write-Warn "API key cannot be empty."; continue }

        if (Test-NasReachable) { break }
        Write-Warn "NAS connection failed - couldn't talk to Syncthing at $Script:SyncthingNasUrl"
        Write-Host "  Check:"
        Write-Host "    - is the address correct and reachable from this machine?"
        Write-Host "    - is Syncthing running on the NAS?"
        Write-Host "    - is the port the Web UI port (default 8384), not 22000?"
        Write-Host "    - is the API key correct (web UI -> Actions -> Settings -> API Key)?"
        if (-not (Read-PromptYn "Retry?" 'y')) { Write-Err "Cancelled."; exit 1 }
    }

    Set-DeviceIds
    Write-Success "NAS reachable at $Script:SyncthingNasUrl"
    Write-Info "  Local device ID:  $($Script:LocalDeviceId.Substring(0,7))..."
    Write-Info "  NAS   device ID:  $($Script:NasDeviceId.Substring(0,7))..."

    # Ask how to persist the API key now that we know it works. (Asking before
    # would just waste a prompt if the key turned out to be wrong.)
    $Script:ApiKeyStorageMode = Read-ApiKeyStorageMode

    Write-Host ""
    Write-Host "NAS Syncthing sync data ports - the ones used for actual file transfer,"
    Write-Host "NOT the Web UI port. Defaults are 22000 for both TCP and UDP. If you"
    Write-Host "left Syncthing's listen settings at their defaults, just press Enter."
    while ($true) {
        $tcpStr = Read-Prompt "  NAS sync TCP port" "22000"
        if ($tcpStr -match '^\d+$' -and [int]$tcpStr -ge 1 -and [int]$tcpStr -le 65535) {
            $Script:NasSyncTcpPort = [int]$tcpStr
            break
        }
        Write-Warn "  Port must be a number between 1 and 65535."
    }
    while ($true) {
        $udpStr = Read-Prompt "  NAS sync UDP port (QUIC)" "22000"
        if ($udpStr -match '^\d+$' -and [int]$udpStr -ge 1 -and [int]$udpStr -le 65535) {
            $Script:NasSyncUdpPort = [int]$udpStr
            break
        }
        Write-Warn "  Port must be a number between 1 and 65535."
    }

    Set-DevicePairing
}

function Set-DeviceIds {
    try {
        $local = Invoke-SyncthingGet 'local' '/system/status'
        $nas   = Invoke-SyncthingGet 'nas'   '/system/status'
        $Script:LocalDeviceId = $local.myID
        $Script:NasDeviceId   = $nas.myID
    } catch {
        Write-Err "Could not query Syncthing device IDs: $($_.Exception.Message)"
        exit 1
    }
    if (-not $Script:LocalDeviceId) { Write-Err "Could not determine local device ID."; exit 1 }
    if (-not $Script:NasDeviceId) {
        Write-Err "Could not determine NAS device ID."
        Write-Err "  The NAS responded but didn't return a valid Syncthing identity."
        Write-Err "  Most common cause: wrong port. Use the Web UI port (default 8384),"
        Write-Err "  not the data-transfer port (22000)."
        exit 1
    }
}

function Get-NasHostFromUrl {
    # Extract bare host from $Script:SyncthingNasUrl (strips scheme, port, path).
    $h = $Script:SyncthingNasUrl -replace '^https?://', '' -replace '/.*$', ''
    return ($h -replace ':\d+$', '')
}

function Set-DevicePairing {
    $localCfg = Invoke-SyncthingGet 'local' '/config/devices'
    $nasCfg   = Invoke-SyncthingGet 'nas'   '/config/devices'

    $localHostname = [System.Environment]::MachineName
    $nasHostname   = 'NAS-Syncthing'
    # Pin the NAS to its known LAN address on port 22000 so local Syncthing
    # doesn't fall back to public relay servers (slow, WAN-typed connection).
    # Keep 'dynamic' as a fallback so global discovery still works if the IP
    # changes.
    $nasHost = Get-NasHostFromUrl
    $nasAddresses = @(
        "tcp://${nasHost}:$Script:NasSyncTcpPort",
        "quic://${nasHost}:$Script:NasSyncUdpPort",
        'dynamic'
    )

    if (-not ($localCfg | Where-Object { $_.deviceID -eq $Script:NasDeviceId })) {
        Write-Info "Adding NAS device to local Syncthing..."
        $body = @{
            deviceID    = $Script:NasDeviceId
            name        = $nasHostname
            addresses   = $nasAddresses
            compression = 'metadata'
            introducer  = $false
            paused      = $false
        } | ConvertTo-Json
        Invoke-SyncthingPost 'local' '/config/devices' $body | Out-Null
        Write-Success "  NAS device added on local Syncthing (direct: tcp://$nasHost`:$Script:NasSyncTcpPort)"
    } else {
        # Device already known - update its addresses so previously-relay-only
        # entries get the direct LAN address pinned.
        Write-Verb "NAS device already known to local Syncthing - updating addresses"
        $existing = $localCfg | Where-Object { $_.deviceID -eq $Script:NasDeviceId } | Select-Object -First 1
        $updated = $existing | Select-Object *
        $updated | Add-Member -NotePropertyName addresses -NotePropertyValue $nasAddresses -Force
        $updateBody = $updated | ConvertTo-Json -Depth 10
        try {
            Invoke-SyncthingPut 'local' "/config/devices/$($Script:NasDeviceId)" $updateBody | Out-Null
            Write-Verb "  pinned NAS direct address $nasHost (TCP $Script:NasSyncTcpPort, UDP $Script:NasSyncUdpPort)"
        } catch {
            Write-Verb "  (couldn't update existing device addresses; leaving as-is)"
        }
    }

    if (-not ($nasCfg | Where-Object { $_.deviceID -eq $Script:LocalDeviceId })) {
        Write-Info "Adding this device to NAS Syncthing..."
        $body = @{
            deviceID    = $Script:LocalDeviceId
            name        = $localHostname
            addresses   = @('dynamic')
            compression = 'metadata'
            introducer  = $false
            paused      = $false
        } | ConvertTo-Json
        Invoke-SyncthingPost 'nas' '/config/devices' $body | Out-Null
        Write-Success "  This device ($localHostname) added on NAS Syncthing"
    } else {
        Write-Verb "Local device already known to NAS Syncthing"
    }
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 5: sync scope
# -----------------------------------------------------------------------------

$Script:SyncScopeDefinitions = @()
$Script:SelectedScopes       = @()
$Script:SavesSelected        = $false

function Initialize-SyncScopeDefinitions {
    # Folder keys for the cross-frontend-shared scopes (roms, bios) stay
    # bare so a RetroBat and a RetroDECK device pointing at the same NAS
    # share the same Syncthing folder ID for those scopes.
    #
    # The frontend-specific scopes use rb-* prefixed keys here. The Bash
    # script uses rd-* for the equivalent RetroDECK scopes. Different keys
    # means different Syncthing folder IDs, which means a RetroBat<->RetroDECK
    # setup just doesn't try to share those structurally-incompatible
    # scopes (RetroBat's combined .emulationstation/ doesn't map cleanly to
    # RetroDECK's separate ES-DE/gamelists/ + ES-DE/downloaded_media/, and
    # RetroBat's RetroArch-only states folder doesn't map cleanly to
    # RetroDECK's all-emulator states/).
    #
    # Same-frontend (RetroBat<->RetroBat, RetroDECK<->RetroDECK) sync is
    # unaffected since both ends use the same prefixed keys.
    if ($Script:Frontend -eq 'custom') {
        # Custom mode: LocalSub is the user-supplied absolute path. Only
        # include scopes the user actually entered a path for. Step-ApplyAll
        # detects an absolute path and skips the Join-Path.
        $defs = @()
        if (-not [string]::IsNullOrEmpty($Script:CustomRomsPath)) {
            $defs += [PSCustomObject]@{Key='roms'; Label='ROMs'; LocalSub=$Script:CustomRomsPath; NasSub='roms'}
        }
        if (-not [string]::IsNullOrEmpty($Script:CustomBiosPath)) {
            $defs += [PSCustomObject]@{Key='bios'; Label='BIOS'; LocalSub=$Script:CustomBiosPath; NasSub='bios'}
        }
        if (-not [string]::IsNullOrEmpty($Script:CustomStatesPath)) {
            $defs += [PSCustomObject]@{Key='custom-states';    Label='Save states (custom)';            LocalSub=$Script:CustomStatesPath;    NasSub='states/custom'}
        }
        if (-not [string]::IsNullOrEmpty($Script:CustomGamelistsPath)) {
            $defs += [PSCustomObject]@{Key='custom-gamelists'; Label='ES-DE gamelists (custom)';        LocalSub=$Script:CustomGamelistsPath; NasSub='gamelists/custom'}
        }
        if (-not [string]::IsNullOrEmpty($Script:CustomMediaPath)) {
            $defs += [PSCustomObject]@{Key='custom-media';     Label='ES-DE downloaded media (custom)'; LocalSub=$Script:CustomMediaPath;     NasSub='media/custom'}
        }
        $Script:SyncScopeDefinitions = @($defs)
        return
    }

    $Script:SyncScopeDefinitions = @(
        [PSCustomObject]@{Key='roms';                Label='ROMs';                                  LocalSub=$Script:RB_ROMS_SUB;      NasSub='roms'},
        [PSCustomObject]@{Key='bios';                Label='BIOS';                                  LocalSub=$Script:RB_BIOS_SUB;      NasSub='bios'},
        [PSCustomObject]@{Key='rb-retroarch-states'; Label='RetroArch save states (RetroBat-only)'; LocalSub=$Script:RB_RA_STATES_SUB; NasSub='states/retrobat'},
        [PSCustomObject]@{Key='rb-emulationstation'; Label='ES-DE gamelists + media (RetroBat-only)'; LocalSub=$Script:RB_GAMELISTS_SUB; NasSub='emulationstation/retrobat'}
    )
}

function Step-SyncScope {
    Initialize-SyncScopeDefinitions

    if ($Script:Frontend -eq 'custom') {
        # In custom mode the paths the user entered already declared what to
        # sync - re-asking "ROMs? y/n" right after they typed the ROMs path
        # would be confusing. Auto-include every scope with a non-empty path.
        foreach ($entry in $Script:SyncScopeDefinitions) {
            $Script:SelectedScopes += $entry.Key
        }
        if ($Script:CustomSavePaths.Count -gt 0) {
            $Script:SavesSelected = $true
        }
        return
    }

    Write-Host ""
    Write-Host "What would you like to sync?"
    Write-Host ""

    foreach ($entry in $Script:SyncScopeDefinitions) {
        $defaultYn = 'y'
        if ($Script:ExistingProfile) {
            $existingId = Get-FolderId $entry.Key
            $hasIt = $Script:ExistingProfile.folders | Where-Object { $_.id -eq $existingId }
            if (-not $hasIt) { $defaultYn = 'n' }
        }
        if (Read-PromptYn "  $($entry.Label)" $defaultYn) {
            $Script:SelectedScopes += $entry.Key
        }
    }
    if (Read-PromptYn "  Saves (per-emulator)" 'y') {
        $Script:SavesSelected = $true
    }
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 5b: ROMs console picker
# -----------------------------------------------------------------------------

$Script:RomsIncluded = @()
$Script:RomsExcluded = @()

function Test-LargeRomConsole {
    param([string]$ConsoleId)
    return [bool]($Script:LargeRomConsoles | Where-Object { $_.Id -eq $ConsoleId })
}

function Get-LargeRomMessage {
    param([string]$ConsoleId)
    $entry = $Script:LargeRomConsoles | Where-Object { $_.Id -eq $ConsoleId } | Select-Object -First 1
    if ($entry) { return "$($entry.Desc) ($($entry.Size))" }
    return ''
}

function Step-RomsPicker {
    if ($Script:SelectedScopes -notcontains 'roms') { return }

    $romsDir = if ($Script:Frontend -eq 'custom') {
        $Script:CustomRomsPath
    } else {
        Join-Path $Script:FrontendBase $Script:RB_ROMS_SUB
    }
    if (-not (Test-Path -LiteralPath $romsDir)) {
        Write-Warn "ROMs directory not found: $romsDir"
        Write-Warn "Skipping per-console picker. All console subdirs will sync once they exist."
        return
    }

    $consoles = Get-ChildItem -LiteralPath $romsDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name |
                Select-Object -ExpandProperty Name

    if ($consoles.Count -eq 0) {
        Write-Info "No console subdirectories yet in $romsDir - all will sync as they appear."
        return
    }

    Write-Host ""
    Write-Host "Found $($consoles.Count) console directories on this device."
    Write-Host ""
    if (Read-PromptYn "Sync ALL consoles to NAS?" 'y') {
        $Script:RomsIncluded = @($consoles)
        Write-Success "Syncing all $($consoles.Count) consoles."
        return
    }

    Write-Host ""
    Write-Host "Pick which consoles to sync. Excluded ones go to .stignore on THIS"
    Write-Host "device only - your NAS still gets them from your other devices."
    Write-Host "Some systems show a [!] size warning, but the default is still 'y' so"
    Write-Host "you don't accidentally skip them by pressing Enter."
    Write-Host ""

    foreach ($c in $consoles) {
        $warnText  = ''
        if (Test-LargeRomConsole $c) {
            $warnText = "  [!] $(Get-LargeRomMessage $c)"
        }
        if (Read-PromptYn "    $c$warnText" 'y') {
            $Script:RomsIncluded += $c
        } else {
            $Script:RomsExcluded += $c
        }
    }

    if ($Script:RomsExcluded.Count -gt 0) {
        Write-Info "Excluded on this device: $($Script:RomsExcluded -join ', ')"
    }
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 5c: per-emulator saves picker
# -----------------------------------------------------------------------------

$Script:SelectedSaves = @()  # array of PSCustomObject {Label, ConsoleId, LocalPath, NasSub}

function Step-SavesPicker {
    if (-not $Script:SavesSelected) { return }

    if ($Script:Frontend -eq 'custom') {
        # Paths were collected up front. Look up the human label for each
        # console_id from RetrobatSaveLocations, then push straight into
        # SelectedSaves with the standard NAS subpath convention.
        foreach ($entry in $Script:CustomSavePaths) {
            $known = $Script:RetrobatSaveLocations |
                     Where-Object { $_.ConsoleId -eq $entry.ConsoleId } |
                     Select-Object -First 1
            $label = if ($known) { $known.Label } else { $entry.ConsoleId }

            $nasSub = switch ($entry.ConsoleId) {
                'retroarch'  { 'saves\retroarch' }
                'ps3'        { 'saves\ps3\savedata' }
                'ps3-trophy' { 'saves\ps3\trophy' }
                default      { "saves\$($entry.ConsoleId)" }
            }

            if (-not (Test-Path -LiteralPath $entry.LocalPath) -and -not $DryRun) {
                try {
                    New-Item -ItemType Directory -Path $entry.LocalPath -Force | Out-Null
                } catch {
                    Write-Warn "  Couldn't create $($entry.LocalPath) - skipping $label."
                    continue
                }
            }

            $Script:SelectedSaves += [PSCustomObject]@{
                Label     = $label
                ConsoleId = $entry.ConsoleId
                LocalPath = $entry.LocalPath
                NasSub    = $nasSub
            }
        }
        return
    }

    Write-Host ""
    Write-Host "Scanning for emulator save locations on this device..."
    Write-Host ""

    # Build candidate list with existence flag.
    $candidates = foreach ($entry in $Script:RetrobatSaveLocations) {
        $localPath = Join-Path $Script:FrontendBase $entry.SubPath
        [PSCustomObject]@{
            Found     = (Test-Path -LiteralPath $localPath)
            Label     = $entry.Label
            ConsoleId = $entry.ConsoleId
            LocalPath = $localPath
            Notes     = $entry.Notes
        }
    }

    # PS1 dual-emulator warning.
    $ps1Standalone = $candidates | Where-Object { $_.ConsoleId -eq 'ps1' -and $_.Found }
    $raSaves       = $candidates | Where-Object { $_.ConsoleId -eq 'retroarch' -and $_.Found }
    if ($ps1Standalone -and $raSaves) {
        Write-WarnBlock @(
            "Both standalone PS1 saves (DuckStation) AND RetroArch PS1 saves",
            "(PCSX-ReARMed/SwanStation) were found on this device. These formats",
            "are NOT cross-compatible. Make sure all your devices use the same PS1 emulator."
        )
        Write-Host ""
    }

    Write-Host "Select which saves to sync. Locations that don't exist yet will"
    Write-Host "ask if you want to sync them anyway - say yes if you might install"
    Write-Host "that emulator later, and the saves will start syncing automatically"
    Write-Host "as soon as the directory appears."
    Write-Host ""
    foreach ($c in $candidates) {
        $shortPath = $c.LocalPath.Replace($Script:FrontendBase, '<base>')
        $shouldAdd = $false
        if ($c.Found) {
            if (Read-PromptYn "  $($c.Label)  ($shortPath)" 'y') {
                $shouldAdd = $true
            }
        } else {
            Write-Color "  $($c.Label) - directory doesn't exist yet ($shortPath)" DarkGray
            if (Read-PromptYn "    Sync anyway? (auto-syncs once you install this emulator)" 'y') {
                if (-not $DryRun) {
                    try {
                        New-Item -ItemType Directory -Path $c.LocalPath -Force | Out-Null
                    } catch {
                        Write-Warn "    Couldn't create $($c.LocalPath): $($_.Exception.Message)"
                        continue
                    }
                }
                $shouldAdd = $true
            }
        }
        if (-not $shouldAdd) { continue }

        $nasSub = switch ($c.ConsoleId) {
            'retroarch'   { 'saves\retroarch' }
            'ps3'         { 'saves\ps3\savedata' }
            'ps3-trophy'  { 'saves\ps3\trophy' }
            default       { "saves\$($c.ConsoleId)" }
        }
        $Script:SelectedSaves += [PSCustomObject]@{
            Label     = $c.Label
            ConsoleId = $c.ConsoleId
            LocalPath = $c.LocalPath
            NasSub    = $nasSub
        }
        switch ($c.ConsoleId) {
            'ps3' { Write-Info "  RPCS3: only savedata\ will sync (NOT installed game data)." }
            'wii' { Write-Info "  Dolphin: full Wii NAND will sync (includes Mii data)." }
        }
    }
}

# -----------------------------------------------------------------------------
# 10. Interactive flow - Step 6: sync direction
# -----------------------------------------------------------------------------

$Script:DefaultDirection    = 'sendreceive'
$Script:IgnorePerms         = $true
$Script:PerFolderDirection  = @{}  # key -> direction

function Get-SyncDirection {
    param([string]$Label, [string]$DefaultMode = 'sendreceive')
    $defaultChoice = switch ($DefaultMode) {
        'sendreceive' { '1' }
        'sendonly'    { '2' }
        'receiveonly' { '3' }
        default       { '1' }
    }
    Write-Host ""
    Write-Host "Sync direction for ${Label}:"
    Write-Host "    [1] Two-way   - changes go both directions (recommended for primary device)"
    Write-Host "    [2] Send only - push to NAS only, never pull"
    Write-Host "    [3] Receive only - pull from NAS only, never push"
    $choice = Read-Prompt "Choice" $defaultChoice
    switch ($choice) {
        '1' { return 'sendreceive' }
        '2' { return 'sendonly' }
        '3' { return 'receiveonly' }
        default { return $DefaultMode }
    }
}

function Step-IgnorePerms {
    if ($Script:ExistingProfile -and $null -ne $Script:ExistingProfile.ignore_perms) {
        $Script:IgnorePerms = [bool]$Script:ExistingProfile.ignore_perms
        $state = if ($Script:IgnorePerms) { 'on' } else { 'off' }
        Write-Info "Ignore permissions: $state (from saved profile)"
        return
    }

    Write-Host ""
    Write-Host "Ignore file permissions on synced folders?"
    Write-Host ""
    Write-Host "  Recommended: yes. Cross-OS sync (e.g. Windows -> ZFS on TrueNAS,"
    Write-Host "  exFAT cards, Synology, Android) frequently stalls with"
    Write-Host "  'Out of Sync' because the receiver can't apply the Unix mode"
    Write-Host "  bits the sender reports. Turning this on tells Syncthing to"
    Write-Host "  compare/sync content only, not permission bits. ROMs/saves/"
    Write-Host "  configs don't need permission-bit fidelity."
    Write-Host ""
    Write-Host "  Same-OS Linux <-> Linux usually works without this, but"
    Write-Host "  turning it on is harmless and avoids edge cases (Flatpak"
    Write-Host "  sandbox UIDs, NFSv4 ACLs on ZFS datasets, etc.)."
    Write-Host ""
    $Script:IgnorePerms = Read-PromptYn "Ignore permissions? (recommended)" 'y'
}

function Step-SyncDirection {
    $modeDefault = 'sendreceive'

    if ($Script:ExistingProfile) {
        # Re-run on a saved profile: the first-vs-adding distinction was
        # answered last time. Re-asking it would be confusing (e.g. a user
        # who picked "Adding" originally would have to lie and pick
        # "First device" just to flip to two-way). Skip straight to the
        # direction picker.
        $Script:DefaultDirection = Get-SyncDirection 'all folders (default)' 'sendreceive'
    } else {
        Write-Host ""
        Write-Host "Is this your first device, or are you adding this device to an"
        Write-Host "existing NAS-based RetroSync setup?"
        Write-Host ""
        Write-Host "    [1] First device - the NAS is empty, or this device's files"
        Write-Host "        should be the starting copy that other devices pull from."
        Write-Host "        Default sync direction: Two-way."
        Write-Host ""
        Write-Host "    [2] Adding to an existing setup - the NAS already has data from"
        Write-Host "        another device. Pull NAS data DOWN first; do NOT push this"
        Write-Host "        device's existing files up. Default direction: Receive only."
        Write-Host "        After the first full sync completes, you'll need to flip"
        Write-Host "        folders to Two-way so future edits go both ways. Two ways"
        Write-Host "        to do that:"
        Write-Host "          - In the Syncthing web UI: open each folder -> Edit ->"
        Write-Host "            Folder Type -> 'Send & Receive' -> Save."
        Write-Host "          - Or re-run this script (it skips this question on"
        Write-Host "            re-runs and goes straight to the direction picker)."
        Write-Host ""
        $modeChoice = Read-Prompt "Choice" "1"

        if ($modeChoice -eq '2') {
            # "Adding to existing setup" already implies receive-only - asking
            # for a direction next would just contradict the choice the user
            # already made. Lock it in and move on.
            $Script:DefaultDirection = 'receiveonly'
            $modeDefault = 'receiveonly'
            Write-Host ""
            Write-Info "Sync direction set to Receive only (matches 'Adding' choice)."
        } else {
            $modeDefault = 'sendreceive'
            $Script:DefaultDirection = Get-SyncDirection 'all folders (default)' $modeDefault
        }
    }

    if (Read-PromptYn "Apply this direction to ALL folders?" 'y') {
        if ($Script:DefaultDirection -eq 'receiveonly') {
            Write-Host ""
            Write-Info "Reminder: after the first full sync finishes (watch progress at"
            Write-Info "  $Script:SyncthingLocalDefault), flip folders to Two-way. Either:"
            Write-Info "    - Web UI: each folder -> Edit -> Folder Type -> 'Send & Receive'."
            Write-Info "    - Or re-run this script: pick [1] Update at the profile"
            Write-Info "      prompt, then pick [1] Two-way at the direction prompt."
        }
        return
    }

    foreach ($entry in $Script:SyncScopeDefinitions) {
        if ($Script:SelectedScopes -notcontains $entry.Key) { continue }
        $Script:PerFolderDirection[$entry.Key] = Get-SyncDirection $entry.Label $modeDefault
    }
    foreach ($s in $Script:SelectedSaves) {
        $Script:PerFolderDirection["save-$($s.ConsoleId)"] = Get-SyncDirection $s.Label $modeDefault
    }
}

function Get-DirectionFor {
    param([string]$Key)
    if ($Script:PerFolderDirection.ContainsKey($Key)) {
        return $Script:PerFolderDirection[$Key]
    }
    return $Script:DefaultDirection
}

# -----------------------------------------------------------------------------
# 12. Folder application
# -----------------------------------------------------------------------------

function Test-FolderExists {
    param([string]$Target, [string]$Id)
    # 404 here just means "folder not configured yet" - that's expected and
    # not an error worth showing the user, so use -Silent to suppress noise.
    try {
        Invoke-SyncthingGet -T $Target -P "/config/folders/$Id" -Silent | Out-Null
        return $true
    } catch {
        return $false
    }
}

function New-FolderJson {
    param(
        [string]$Id, [string]$Label, [string]$Path, [string]$Type,
        [string]$SelfId, [string]$PeerId, [bool]$Versioning
    )
    $versioningBlock = if ($Versioning) {
        @{ type = 'simple'; params = @{ keep = '5' } }
    } else {
        @{ type = ''; params = @{} }
    }
    $obj = @{
        id              = $Id
        label           = $Label
        path            = $Path
        type            = $Type
        rescanIntervalS = 3600
        fsWatcherEnabled= $true
        fsWatcherDelayS = 10
        # Skip permission bit syncing - controlled by Step-IgnorePerms.
        # Cross-OS retro setups (Windows <-> ZFS on TrueNAS, exFAT cards,
        # Synology, Android) routinely stall on "Out of Sync" because the
        # receiver can't apply Unix mode bits the sender reports. Equivalent
        # to flipping "Ignore Permissions" in the web UI's Advanced settings.
        ignorePerms     = $Script:IgnorePerms
        autoNormalize   = $true
        devices         = @(
            @{ deviceID = $SelfId },
            @{ deviceID = $PeerId }
        )
        versioning      = $versioningBlock
        paused          = $false
    }
    return ($obj | ConvertTo-Json -Depth 10 -Compress)
}

function Remove-PeerDeviceIfUnused {
    # Remove a peer device entry from a Syncthing instance, but only if no
    # remaining folder still references it. Returns 'removed', 'in-use', or
    # 'failed'. Avoids breaking unrelated Syncthing folders the user may have
    # set up between the same two devices.
    param([string]$Target, [string]$DeviceId)

    if ([string]::IsNullOrEmpty($DeviceId)) { return 'failed' }

    try {
        $folders = @(Invoke-SyncthingGet -T $Target -P '/config/folders' -Silent)
    } catch {
        return 'failed'
    }

    foreach ($f in $folders) {
        if ($null -eq $f -or $null -eq $f.devices) { continue }
        foreach ($d in $f.devices) {
            if ($d.deviceID -eq $DeviceId) { return 'in-use' }
        }
    }

    try {
        Invoke-SyncthingDelete -T $Target -P "/config/devices/$DeviceId" -Silent | Out-Null
        return 'removed'
    } catch {
        $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($sc -eq 404) { return 'removed' }  # already gone
        return 'failed'
    }
}

function Remove-RetrosyncFolders {
    # Remove (or unshare) a set of folder IDs from a Syncthing instance.
    #
    # Modes:
    #   default       - DELETE the folder entirely. Use on the device whose
    #                   participation in sync is being torn down.
    #   -UnshareOnly  - Remove just $Script:LocalDeviceId from each folder's
    #                   device list. If no other peers remain, also DELETE
    #                   the folder. Otherwise leave it intact and ACTIVE
    #                   (NOT paused) so the remaining peers keep syncing.
    #
    # Uses PATCH for surgical updates - PATCH only touches the fields in
    # the body, which avoids two failure modes we hit with full PUT:
    #   1. PowerShell 5.1's PSCustomObject + ConvertTo-Json round-trip
    #      occasionally drops/mangles nested arrays, so the updated
    #      `devices` field never made it back to Syncthing - paused was
    #      applied but our deviceID stayed in the list.
    #   2. Always pausing the folder broke the remaining peers (e.g. when
    #      removing PC, the laptop's folder went paused on NAS too, so
    #      laptop had nothing to sync against).
    #
    # Two-pass: PATCH first (fast), then a 1s pause, then DELETE for
    # folders that have no peers left.
    #
    # Returns the array of IDs that couldn't be cleaned up.
    param(
        [string]$Target,
        [string[]]$IdsToRemove,
        [switch]$UnshareOnly
    )

    if ($IdsToRemove.Count -eq 0) { return @() }

    $toDelete = @()

    # Pass 1: PATCH each folder.
    foreach ($id in $IdsToRemove) {
        $cfg = $null
        try { $cfg = Invoke-SyncthingGet -T $Target -P "/config/folders/$id" -Silent } catch {}
        if ($null -eq $cfg) { continue }

        $deleteThis = -not $UnshareOnly
        $patchBody = $null

        if ($UnshareOnly) {
            # Build the new devices list. Manual JSON construction so PS5.1
            # can't collapse a single-element array into a non-array.
            $deviceEntries = @()
            $peerCount = 0
            foreach ($d in $cfg.devices) {
                if ($d.deviceID -eq $Script:LocalDeviceId) { continue }
                $h = @{}
                foreach ($prop in $d.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
                $deviceEntries += ($h | ConvertTo-Json -Depth 10 -Compress)
                if ($d.deviceID -ne $Script:NasDeviceId) { $peerCount++ }
            }
            $devicesJson = "[" + ($deviceEntries -join ",") + "]"

            if ($peerCount -eq 0) {
                # Last peer leaving - pause too so the upcoming DELETE is fast.
                $deleteThis = $true
                $patchBody = "{`"devices`":$devicesJson,`"paused`":true}"
            } else {
                # Other peers still using this folder - DON'T pause it; they
                # still need it active. Just remove our device from the list.
                $patchBody = "{`"devices`":$devicesJson}"
            }
        } else {
            # Full delete - pause first so DELETE doesn't have to wait for
            # the runner to drain.
            $patchBody = '{"paused":true}'
        }

        try {
            Invoke-SyncthingPatch -T $Target -P "/config/folders/$id" -B $patchBody -Silent | Out-Null
            if ($UnshareOnly) { Write-Verb "  ${Target}: unshared $id" }
            else              { Write-Verb "  ${Target}: paused $id" }
        } catch {
            Write-Warn "  ${Target}: PATCH of $id failed - $($_.Exception.Message)"
        }

        if ($deleteThis) { $toDelete += $id }
    }

    # Let Syncthing apply the config changes before DELETEs hit.
    Start-Sleep -Milliseconds 1000

    # Pass 2: DELETE folders that should be fully gone.
    foreach ($id in $toDelete) {
        try {
            Invoke-SyncthingDelete -T $Target -P "/config/folders/$id" -Silent | Out-Null
            Write-Verb "  ${Target}: deleted $id"
        } catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($sc -ne 404) {
                Write-Warn "  ${Target}: DELETE of $id returned HTTP $sc"
                if ($UnshareOnly) {
                    Write-Warn "  ${Target}: folder is unshared and paused (no peers); delete via web UI if you want it gone"
                }
            }
        }
    }

    Start-Sleep -Milliseconds 500

    # Verify. UnshareOnly success: we're no longer in any folder's device
    # list. Default success: folder is gone entirely.
    $stillProblem = @()
    try {
        $after = @(Invoke-SyncthingGet -T $Target -P '/config/folders' -Silent)
        foreach ($id in $IdsToRemove) {
            $folder = $after | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $folder) { continue }

            if ($UnshareOnly) {
                $stillThere = $false
                foreach ($d in $folder.devices) {
                    if ($d.deviceID -eq $Script:LocalDeviceId) { $stillThere = $true; break }
                }
                if ($stillThere) { $stillProblem += $id }
            } else {
                $stillProblem += $id
            }
        }
    } catch {
        Write-Verb "  ${Target}: couldn't verify - assuming success"
        return @()
    }

    if ($stillProblem.Count -gt 0) {
        Write-Warn "  ${Target}: $($stillProblem.Count) folder(s) STILL reference this device:"
        foreach ($id in $stillProblem) { Write-Warn "    - $id" }
    } elseif ($UnshareOnly) {
        Write-Verb "  ${Target}: this device removed from $($IdsToRemove.Count) folder(s)"
    } else {
        Write-Verb "  ${Target}: removed $($IdsToRemove.Count) folder(s)"
    }
    return $stillProblem
}

function Set-Folder {
    param(
        [string]$Target, [string]$Id, [string]$Label, [string]$Path,
        [string]$Type, [string]$PeerId, [bool]$Versioning
    )
    $selfId = if ($Target -eq 'local') { $Script:LocalDeviceId } else { $Script:NasDeviceId }

    if (-not (Test-FolderExists $Target $Id)) {
        $json = New-FolderJson -Id $Id -Label $Label -Path $Path -Type $Type `
                               -SelfId $selfId -PeerId $PeerId -Versioning $Versioning
        Write-Verb "Folder $Id new on $Target - creating"
        Invoke-SyncthingPost $Target '/config/folders' $json | Out-Null
        return
    }

    # Folder exists - MERGE the devices list rather than replace it.
    # Replacing is destructive: e.g. when a laptop joins later, the NAS-side
    # folder originally had devices [NAS, PC]; a naive PUT with [NAS, Laptop]
    # silently dropped the PC, and Syncthing then refused to sync from PC
    # until the user clicked "device wants to share" in the web UI.
    $existing = Invoke-SyncthingGet -T $Target -P "/config/folders/$Id" -Silent

    $deviceList = @()
    $seen = @{}
    if ($existing -and $existing.devices) {
        foreach ($d in $existing.devices) {
            if ($d.deviceID -and -not $seen.ContainsKey($d.deviceID)) {
                $deviceList += $d
                $seen[$d.deviceID] = $true
            }
        }
    }
    if (-not $seen.ContainsKey($selfId)) {
        $deviceList += @{ deviceID = $selfId }
        $seen[$selfId] = $true
    }
    if (-not $seen.ContainsKey($PeerId)) {
        $deviceList += @{ deviceID = $PeerId }
        $seen[$PeerId] = $true
    }

    $versioningBlock = if ($Versioning) {
        @{ type = 'simple'; params = @{ keep = '5' } }
    } else {
        @{ type = ''; params = @{} }
    }
    $obj = @{
        id              = $Id
        label           = $Label
        path            = $Path
        type            = $Type
        rescanIntervalS = 3600
        fsWatcherEnabled= $true
        fsWatcherDelayS = 10
        ignorePerms     = $Script:IgnorePerms
        autoNormalize   = $true
        devices         = $deviceList
        versioning      = $versioningBlock
        paused          = $false
    }
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    Write-Verb "Folder $Id exists on $Target - updating ($($deviceList.Count) device(s) in list)"
    Invoke-SyncthingPut $Target "/config/folders/$Id" $json | Out-Null
}

function Set-FolderIgnores {
    param([string]$Id, [string[]]$Patterns)
    if ($Patterns.Count -eq 0) { return }
    $body = @(
        "// Auto-generated by $Script:RetroSyncName - do not edit manually",
        "// To update, re-run $(Split-Path -Leaf $PSCommandPath)"
    )
    foreach ($p in $Patterns) { $body += "/$p" }
    $json = @{ ignore = $body } | ConvertTo-Json
    if ($DryRun) {
        Write-Dry "Would write .stignore for $Id with patterns: $($Patterns -join ', ')"
        return
    }
    try {
        Invoke-SyncthingPost 'local' "/db/ignores?folder=$Id" $json | Out-Null
    } catch {
        Write-Warn "Failed to write .stignore for $Id"
    }
}

$Script:AppliedFolders = @()  # array of PSCustomObject

function New-ProvisionedFolder {
    param(
        [string]$Key, [string]$Label, [string]$LocalPath, [string]$NasPath,
        [bool]$Versioning, [string[]]$IgnorePatterns
    )
    $id = Get-FolderId $Key
    $direction = Get-DirectionFor $Key
    $localFileCount = 0
    if (Test-Path -LiteralPath $LocalPath) {
        $localFileCount = (Get-ChildItem -LiteralPath $LocalPath -Recurse -File -ErrorAction SilentlyContinue).Count
    }
    Write-Info "Provisioning $Label (id: $id)"
    Write-Info "  local: $LocalPath  ($localFileCount files)"
    Write-Info "  NAS:   $NasPath"

    try {
        Set-Folder -Target 'nas'   -Id $id -Label $Label -Path $NasPath   -Type $direction -PeerId $Script:LocalDeviceId -Versioning $Versioning
        Set-Folder -Target 'local' -Id $id -Label $Label -Path $LocalPath -Type $direction -PeerId $Script:NasDeviceId   -Versioning $Versioning
    }
    catch {
        Write-Err "Skipping ${Label}: $($_.Exception.Message)"
        return
    }
    if ($IgnorePatterns -and $IgnorePatterns.Count -gt 0) {
        Set-FolderIgnores -Id $id -Patterns $IgnorePatterns
    }
    $extra = if ($Versioning) { ', 5-version retention' } else { '' }
    Write-Success "  -> $Label configured ($direction$extra)"
    $Script:AppliedFolders += [PSCustomObject]@{
        Id             = $id
        Label          = $Label
        LocalPath      = $LocalPath
        NasPath        = $NasPath
        Direction      = $direction
        Versioning     = $Versioning
        IgnorePatterns = $IgnorePatterns
    }
}

function Step-ApplyAll {
    Write-Host ""
    Write-Hr
    Write-Info "Applying configuration..."
    Write-Hr

    $nasUserRoot = Get-NasUserRoot

    foreach ($entry in $Script:SyncScopeDefinitions) {
        if ($Script:SelectedScopes -notcontains $entry.Key) { continue }
        # Custom mode emits absolute paths in LocalSub - detect that and
        # skip the Join-Path (which would prepend an empty FrontendBase
        # producing odd results).
        $localPath = if ([System.IO.Path]::IsPathRooted($entry.LocalSub)) {
            $entry.LocalSub
        } else {
            Join-Path $Script:FrontendBase $entry.LocalSub
        }
        $nasPath   = "$nasUserRoot/$($entry.NasSub)"
        $versioning = $false
        # Save states get versioning - they're easy to corrupt and the user
        # benefits from being able to roll back.
        if ($entry.Key -like '*states*') { $versioning = $true }
        $ignores = @()
        if ($entry.Key -eq 'roms' -and $Script:RomsExcluded.Count -gt 0) {
            $ignores = $Script:RomsExcluded
        }
        New-ProvisionedFolder -Key $entry.Key -Label $entry.Label `
                              -LocalPath $localPath -NasPath $nasPath `
                              -Versioning $versioning -IgnorePatterns $ignores
    }

    foreach ($s in $Script:SelectedSaves) {
        $nasPath = "$nasUserRoot/$($s.NasSub.Replace('\','/'))"
        New-ProvisionedFolder -Key "save-$($s.ConsoleId)" -Label $s.Label `
                              -LocalPath $s.LocalPath -NasPath $nasPath `
                              -Versioning $true -IgnorePatterns @()
    }
}

# -----------------------------------------------------------------------------
# 13. Summary + profile build
# -----------------------------------------------------------------------------

function Get-DirectionArrow {
    param([string]$D)
    switch ($D) {
        'sendreceive' { return '<-> two-way' }
        'sendonly'    { return ' -> send' }
        'receiveonly' { return ' <- receive' }
        default       { return '?' }
    }
}

function Write-Summary {
    Write-Host ""
    Write-Hr
    Write-Color "$Script:RetroSyncName Setup Complete" White
    Write-Hr
    Write-Host ""
    Write-Host "  Device:    $([System.Environment]::MachineName)"
    Write-Host "  Frontend:  $Script:Frontend"
    if ($Script:MultiUser) {
        Write-Host "  Mode:      multi-user (username: $Script:Username)"
    } else {
        Write-Host "  Mode:      single-user"
    }
    Write-Host "  NAS:       $Script:SyncthingNasUrl"
    Write-Host "  NAS root:  $(Get-NasUserRoot)"
    Write-Host ""
    Write-Host "  Synced folders:"
    "{0,-26} {1,-14} {2,-12} {3}" -f 'Name','Direction','Versioning','Local Path' | ForEach-Object { Write-Host "    $_" }
    Write-Host ('    ' + ('-' * 70))
    foreach ($f in $Script:AppliedFolders) {
        $v = if ($f.Versioning) { '5 versions' } else { 'off' }
        "{0,-26} {1,-14} {2,-12} {3}" -f $f.Label, (Get-DirectionArrow $f.Direction), $v, $f.LocalPath |
            ForEach-Object { Write-Host "    $_" }
    }
    if ($Script:RomsExcluded.Count -gt 0) {
        Write-Host ""
        Write-Host "  ROM consoles excluded on this device:"
        Write-Host "    $($Script:RomsExcluded -join ', ')"
    }
    Write-Host ""
    Write-Host "  Syncthing is now syncing in the background."
    Write-Host "  Monitor at: $Script:SyncthingLocalDefault"
    Write-Host ""
    Write-Host "  Profile saved: $(Get-ProfileFile)"
    Write-Host ""
    Write-Host "  To add more consoles or change settings, run this script again."
    Write-Hr
}

function New-ProfileObject {
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $hostname = [System.Environment]::MachineName

    $folders = foreach ($f in $Script:AppliedFolders) {
        [PSCustomObject]@{
            id              = $f.Id
            name            = $f.Label
            local_path      = $f.LocalPath
            nas_path        = $f.NasPath
            type            = $f.Direction
            versioning      = $f.Versioning
            ignore_patterns = @($f.IgnorePatterns)
        }
    }

    $nasAddr = ($Script:SyncthingNasUrl -replace '^https?://','' -replace '/rest$','')

    [PSCustomObject]@{
        version             = '1.0'
        device_name         = $hostname
        frontend            = $Script:Frontend
        frontend_base_path  = $Script:FrontendBase
        multi_user          = $Script:MultiUser
        username            = $Script:Username
        ignore_perms        = $Script:IgnorePerms
        created_at          = $now
        updated_at          = $now
        local_syncthing     = [PSCustomObject]@{
            address   = $Script:SyncthingLocalDefault
            device_id = $Script:LocalDeviceId
        }
        nas_syncthing       = [PSCustomObject]@{
            url               = $Script:SyncthingNasUrl
            address           = $nasAddr
            api_key_storage   = $Script:ApiKeyStorageMode
            api_key           = (Protect-ApiKeyForStorage -Mode $Script:ApiKeyStorageMode -Key $Script:SyncthingNasKey)
            nas_base          = $Script:NasBaseDir
            device_id         = $Script:NasDeviceId
            sync_tcp_port     = $Script:NasSyncTcpPort
            sync_udp_port     = $Script:NasSyncUdpPort
        }
        folders             = @($folders)
    }
}

# -----------------------------------------------------------------------------
# 13b. Remove-device flow
# -----------------------------------------------------------------------------

function Step-RemoveDevice {
    Write-Host ""
    Write-Hr
    Write-Color "Remove this device from RetroSync" White
    Write-Hr

    # Use the saved NAS connection from the profile - no re-prompting.
    $Script:SyncthingNasUrl = $Script:ExistingProfile.nas_syncthing.url
    $Script:SyncthingNasKey = $Script:ExistingProfile.nas_syncthing.api_key
    $nasBase                = $Script:ExistingProfile.nas_syncthing.nas_base

    # Load device IDs - the unshare logic NEEDS these to identify "us" and
    # the NAS in folder device lists. If they're null, the comparisons all
    # silently fail to match, devices stay unfiltered, and the script
    # falsely reports success while NAS keeps everything intact.
    $Script:LocalDeviceId = $Script:ExistingProfile.local_syncthing.device_id
    $Script:NasDeviceId   = $Script:ExistingProfile.nas_syncthing.device_id
    if ([string]::IsNullOrEmpty($Script:LocalDeviceId)) {
        try {
            $local = Invoke-SyncthingGet 'local' '/system/status'
            $Script:LocalDeviceId = $local.myID
        } catch {}
    }

    Write-Host ""
    Write-Info "Checking NAS reachability..."
    $nasReachable = $false
    try { $nasReachable = Test-NasReachable } catch { $nasReachable = $false }
    if ($nasReachable) {
        Write-Success "NAS reachable - we can remove configs from both sides."
        if ([string]::IsNullOrEmpty($Script:NasDeviceId)) {
            try {
                $nas = Invoke-SyncthingGet 'nas' '/system/status'
                $Script:NasDeviceId = $nas.myID
            } catch {}
        }
    } else {
        Write-Warn "NAS unreachable. Local cleanup will proceed but you'll need to"
        Write-Warn "remove folder configs from the NAS Syncthing manually."
    }

    if ([string]::IsNullOrEmpty($Script:LocalDeviceId)) {
        Write-Err "Couldn't determine this device's Syncthing ID - aborting cleanup."
        Write-Err "  Restart Syncthing locally and try again, or remove folders via web UI."
        return
    }

    $folders = @($Script:ExistingProfile.folders)
    if ($folders.Count -eq 0) {
        Write-Warn "No folders in profile. Just deleting profile.json."
        if (-not $DryRun) { Remove-Item -LiteralPath (Get-ProfileFile) -Force }
        Write-Success "Profile removed."
        return
    }

    Write-Host ""
    Write-Host "The following $($folders.Count) folder(s) are configured for sync:"
    Write-Host ""
    foreach ($f in $folders) {
        Write-Host "  - $($f.id)"
        Write-Host "      local: $($f.local_path)"
        Write-Host "      NAS:   $($f.nas_path)"
    }
    Write-Host ""
    Write-Host "Removing the configs un-pairs the folders. The actual data files are"
    Write-Host "left in place by default - you can optionally delete them below."

    # Q1: delete server data?
    Write-Host ""
    $deleteNas = $false
    if (Read-PromptYn "Delete the synced data files on the NAS too?" 'n') {
        Write-Host ""
        Write-WarnBlock @(
            "Heads up: this script CANNOT directly delete files on the NAS through",
            "Syncthing's REST API - the API only manages folder configs, not file",
            "contents. After this script finishes you'll need to SSH or file-manager",
            "into your NAS and remove the data directory yourself. Suggested:",
            "    rm -rf $nasBase",
            "(That's the path Syncthing sees inside its container. If you mounted",
            " a host directory into the container, delete the host-side directory",
            " instead - same effect, no permissions surprises.)"
        )
        Write-Host ""
        $confirm = Read-Prompt "Type 'yes' to acknowledge you'll handle NAS cleanup manually"
        if ($confirm -eq 'yes') {
            $deleteNas = $true
        } else {
            Write-Info "OK, skipping the NAS-deletion reminder."
        }
    }

    # Q2: delete device data?
    Write-Host ""
    $deleteLocal = $false
    if (Read-PromptYn "Delete the synced data files on THIS device?" 'n') {
        Write-Host ""
        Write-WarnBlock @(
            "This will permanently delete the following directories from this device:"
        )
        foreach ($f in $folders) {
            Write-Color "      $($f.local_path)" Yellow
        }
        Write-Host ""
        $confirm = Read-Prompt "Type 'yes' to confirm permanent deletion"
        if ($confirm -eq 'yes') {
            $deleteLocal = $true
        } else {
            Write-Info "OK, keeping local data files."
        }
    }

    # Action: remove folder configs.
    # On THIS device: always full delete.
    # On the NAS: full delete if we're the last peer (no point keeping
    # orphan folders); otherwise unshare-only so other devices keep their
    # sync. The full-delete path only PATCHes {"paused":true} (single
    # scalar field, reliably applied) before DELETE - which avoids the
    # multi-field PATCH that proved flaky in the unshare path's
    # peer-count==0 corner case.
    Write-Host ""
    $idsToRemove = @($folders | ForEach-Object { $_.id })

    $isLastPeer = $false
    if ($nasReachable) {
        $isLastPeer = $true
        foreach ($id in $idsToRemove) {
            try {
                $cfg = Invoke-SyncthingGet -T 'nas' -P "/config/folders/$id" -Silent
                if ($null -eq $cfg) { continue }
                foreach ($d in $cfg.devices) {
                    if ($d.deviceID -ne $Script:LocalDeviceId -and $d.deviceID -ne $Script:NasDeviceId) {
                        $isLastPeer = $false
                        break
                    }
                }
                if (-not $isLastPeer) { break }
            } catch {}
        }
    }

    Write-Info "Removing folder configurations from Syncthing..."
    if ($nasReachable) {
        if ($isLastPeer) {
            Write-Info "  Last peer - folders will be removed entirely from NAS."
        } else {
            Write-Info "  Other devices still use these folders - unsharing only on NAS."
        }
    }

    $localStillPresent = @(Remove-RetrosyncFolders -Target 'local' -IdsToRemove $idsToRemove)
    $nasStillPresent = @()
    if ($nasReachable) {
        if ($isLastPeer) {
            $nasStillPresent = @(Remove-RetrosyncFolders -Target 'nas' -IdsToRemove $idsToRemove)
        } else {
            $nasStillPresent = @(Remove-RetrosyncFolders -Target 'nas' -IdsToRemove $idsToRemove -UnshareOnly)
        }
    }
    $cleanupOk = ($localStillPresent.Count -eq 0) -and ($nasStillPresent.Count -eq 0)
    if ($cleanupOk) {
        Write-Success "Folder configs cleaned up:"
        Write-Host  "    - this device: configs deleted"
        if ($nasReachable) {
            if ($isLastPeer) {
                Write-Host "    - NAS:         folders deleted (no other devices were using them)"
            } else {
                Write-Host "    - NAS:         this device unshared (folders kept active for"
                Write-Host "                   the remaining devices)"
            }
        }
    } else {
        Write-Host ""
        Write-Warn "Some folder configs could not be removed automatically."
        Write-Warn "Profile NOT deleted - re-run [3] Remove to retry, or remove the"
        Write-Warn "remaining folders via the Syncthing web UI."
        Write-Hr
        return
    }

    # Action: remove device pairings, but only if no other folder still
    # references them - so unrelated Syncthing setups between the same two
    # devices don't get broken.
    Write-Host ""
    Write-Info "Cleaning up device pairings (only if unused by other folders)..."
    $peerNasOnLocal = $Script:ExistingProfile.nas_syncthing.device_id
    $peerLocalOnNas = $Script:ExistingProfile.local_syncthing.device_id

    if ($peerNasOnLocal) {
        $r = Remove-PeerDeviceIfUnused -Target 'local' -DeviceId $peerNasOnLocal
        switch ($r) {
            'removed' { Write-Success "  local: NAS device pairing removed" }
            'in-use'  { Write-Info  "  local: NAS device kept (still used by other folders)" }
            'failed'  { Write-Warn  "  local: couldn't remove NAS device pairing - remove via web UI if you want it gone" }
        }
    }
    if ($nasReachable -and $peerLocalOnNas) {
        $r = Remove-PeerDeviceIfUnused -Target 'nas' -DeviceId $peerLocalOnNas
        switch ($r) {
            'removed' { Write-Success "  NAS:   this device's pairing removed" }
            'in-use'  { Write-Info  "  NAS:   this device kept (still used by other folders)" }
            'failed'  { Write-Warn  "  NAS:   couldn't remove this device's pairing - remove via web UI if you want it gone" }
        }
    }

    # Action: delete local data
    if ($deleteLocal) {
        Write-Host ""
        Write-Info "Deleting local data files..."
        foreach ($f in $folders) {
            $path = $f.local_path
            if (Test-Path -LiteralPath $path) {
                if ($DryRun) {
                    Write-Dry "Remove-Item -Recurse $path"
                } else {
                    try {
                        Remove-Item -LiteralPath $path -Recurse -Force
                        Write-Success "  deleted: $path"
                    } catch {
                        Write-Err "  failed: $path - $($_.Exception.Message)"
                    }
                }
            } else {
                Write-Verb "  (already absent) $path"
            }
        }
    }

    # Action: delete profile
    Write-Host ""
    if (-not $DryRun) {
        Remove-Item -LiteralPath (Get-ProfileFile) -Force
    }
    Write-Success "Profile deleted: $(Get-ProfileFile)"

    Write-Host ""
    Write-Hr
    Write-Color "$Script:RetroSyncName removed from this device" White
    Write-Hr
    if ($deleteNas) {
        Write-Host ""
        Write-Info "REMINDER - delete the NAS data manually:"
        Write-Host  "    Container-internal path: $nasBase"
        Write-Host  "    SSH or file-manager into your NAS and remove that directory."
        Write-Host  "    Example: rm -rf $nasBase"
    }
    if (-not $nasReachable) {
        Write-Host ""
        Write-Warn "NAS was unreachable - the folder configs may still exist on it."
        Write-Warn "Remove them via the NAS Syncthing web UI when you can reach it."
    }
    Write-Host ""
    Write-Host "  You can now re-run this script for a fresh setup."
    Write-Hr
}

# -----------------------------------------------------------------------------
# 14. Main entry
# -----------------------------------------------------------------------------

function Invoke-Main {
    if ($DryRun) {
        Write-Host ""
        Write-Color "=== DRY RUN MODE - no changes will be made ===" Magenta
        Write-Host ""
    }

    Write-Color ("$Script:RetroSyncName v$Script:RetroSyncVersion") White
    Write-Color "Tip: prompts show [defaults] in brackets - press Enter to accept the default." DarkGray
    Write-Host ""

    Test-LocalSyncthing
    Step-ProfileDetection

    if ($Script:ProfileMode -eq 'remove') {
        Step-RemoveDevice
        return
    }

    Step-FrontendSelection
    Step-NasConnection
    Step-NasLayout
    Step-SyncScope
    Step-RomsPicker
    Step-SavesPicker
    Step-IgnorePerms
    Step-SyncDirection

    Write-Host ""
    $totalFolders = $Script:SelectedScopes.Count + $Script:SelectedSaves.Count
    Write-Info "About to configure $totalFolders folder(s) on both devices."
    if (-not $DryRun -and -not (Read-PromptYn "Proceed?" 'y')) {
        Write-Err "Cancelled."
        exit 1
    }

    Step-ApplyAll

    if ($Script:AppliedFolders.Count -gt 0) {
        Save-Profile (New-ProfileObject)
    } else {
        Write-Warn "No folders were configured - profile not saved."
    }

    Write-Summary
}

try {
    Invoke-Main
}
catch {
    Write-Err "Unexpected error: $($_.Exception.Message)"
    if ($VerboseLog) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
