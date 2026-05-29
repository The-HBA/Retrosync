<#
.SYNOPSIS
    Maintenance / cleanup tool for RetroSync.
.DESCRIPTION
    Removes RetroSync folder configs (and optionally unused device pairings)
    from a NAS Syncthing instance over its REST API. Use it to clean up
    "ghost users" (folders left behind after a directory was deleted by hand),
    remove a whole user, drop individual folders, or wipe every RetroSync
    folder for a fresh start.

    It only ever touches Syncthing *configuration* (folder + device entries
    whose folder id starts with "retrosync-"). It does NOT delete data files —
    delete those yourself on the NAS afterward if you want them gone.

    License: GPL-3.0   Project: https://github.com/The-HBA/Retrosync
.PARAMETER DryRun
    Show what would be removed without making changes.
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$Script:FolderIdPrefix = 'retrosync'
$Script:UseColor = -not [Console]::IsOutputRedirected

function Write-C { param([string]$T,[ConsoleColor]$Color=[ConsoleColor]::White) if ($Script:UseColor){Write-Host $T -ForegroundColor $Color}else{Write-Host $T} }
function Ok    { param([string]$M) Write-C "[OK]  $M" Green }
function Inf   { param([string]$M) Write-C "[i]   $M" Cyan }
function Wn    { param([string]$M) Write-C "[!]   $M" DarkYellow }
function Er    { param([string]$M) Write-C "[X]   $M" Red }
function Hr    { Write-C ('=' * 60) DarkGray }
function Ask   { param([string]$Q,[string]$D='') $r = if($D){Read-Host "$Q [$D]"}else{Read-Host $Q}; if([string]::IsNullOrEmpty($r)){return $D}; return $r }
function AskYn { param([string]$Q,[string]$D='n') while($true){ $y=if($D -eq 'y'){'Y'}else{'y'}; $n=if($D -eq 'n'){'N'}else{'n'}; $r=Read-Host "$Q [$y/$n]"; if([string]::IsNullOrEmpty($r)){$r=$D}; switch -Regex ($r.ToLower()){'^(y|yes)$'{return $true}'^(n|no)$'{return $false}default{Write-C '  y or n.' Yellow}} } }
function AskSecret { param([string]$Q) $s=Read-Host -Prompt $Q -AsSecureString; $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try{[Runtime.InteropServices.Marshal]::PtrToStringAuto($b)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)} }

$Script:NasUrl = $null
$Script:NasKey = $null

function ConvertTo-RestUrl {
    param([string]$Raw)
    $scheme='http'; $rest=$Raw
    if ($Raw -match '^(https?)://(.+)$'){ $scheme=$matches[1]; $rest=$matches[2] }
    $rest = $rest.TrimEnd('/'); $rest = $rest -replace '/rest$',''
    $hostPart = ($rest -split '/',2)[0]
    if ($hostPart -notmatch ':\d+$'){ $hostPart = "${hostPart}:8384" }
    return "${scheme}://${hostPart}/rest"
}

function Invoke-Api {
    param([string]$Method,[string]$Path,[string]$Body)
    $headers = @{ 'X-API-Key' = $Script:NasKey }
    $uri = "$($Script:NasUrl)$Path"
    if ($Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body $Body
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Connect-Nas {
    $pf = [System.IO.Path]::Combine($env:APPDATA,'RetroSync','profile.json')
    $used = $false
    if (Test-Path -LiteralPath $pf) {
        try {
            $p = Get-Content -Raw -LiteralPath $pf | ConvertFrom-Json
            $storage = $p.nas_syncthing.api_key_storage
            if ($p.nas_syncthing.url -and $storage -eq 'plaintext' -and $p.nas_syncthing.api_key) {
                if (AskYn "Use NAS connection from $pf ?" 'y') {
                    $Script:NasUrl = $p.nas_syncthing.url
                    $Script:NasKey = $p.nas_syncthing.api_key
                    $used = $true
                }
            } elseif ($p.nas_syncthing.url) {
                Inf "Found a profile (NAS: $($p.nas_syncthing.url)) but its API key isn't plaintext - enter it manually."
            }
        } catch { }
    }
    if (-not $used) {
        $raw = Ask "NAS Syncthing address (e.g. 192.168.1.50:8384)"
        if ([string]::IsNullOrEmpty($raw)) { Er "No address given."; exit 1 }
        $Script:NasUrl = ConvertTo-RestUrl $raw
        $Script:NasKey = AskSecret "NAS Syncthing API key"
    }
    Inf "Connecting to $($Script:NasUrl) ..."
    try {
        $ping = Invoke-Api GET '/system/ping'
        if ($ping.ping -ne 'pong') { throw 'unexpected response' }
    } catch {
        Er "Couldn't reach Syncthing at $($Script:NasUrl) (check address + API key)."
        exit 1
    }
    Ok "Connected."
}

function Get-RetrosyncFolders {
    $all = Invoke-Api GET '/config/folders'
    return @($all | Where-Object { $_.id -like "$($Script:FolderIdPrefix)-*" })
}

# Infer the username segment from a folder id (mirrors retrosync-reset.sh).
function Get-UserFromId {
    param([string]$Id)
    $key = $Id -replace "^$($Script:FolderIdPrefix)-",''
    $scope0 = ($key -split '-')[0]
    if ($scope0 -in @('roms','bios','save','rd','rb','custom')) { return '(no username)' }
    return $scope0
}

function Remove-FolderConfig {
    param([string]$Id)
    if ($DryRun) { Write-C "[DRY] would DELETE folder $Id" Cyan; return }
    try { Invoke-Api DELETE "/config/folders/$Id" | Out-Null; Ok "removed folder $Id" }
    catch { Er "failed to remove $Id : $($_.Exception.Message)" }
}

function Remove-OrphanDevices {
    $myId = (Invoke-Api GET '/system/status').myID
    $devices = Invoke-Api GET '/config/devices'
    $folders = Invoke-Api GET '/config/folders'
    foreach ($d in $devices) {
        if ($d.deviceID -eq $myId) { continue }
        $refs = @($folders | ForEach-Object { $_.devices } | Where-Object { $_.deviceID -eq $d.deviceID }).Count
        if ($refs -eq 0) {
            if ($DryRun) { Write-C "[DRY] would remove unused device $($d.deviceID.Substring(0,7))..." Cyan }
            else { try { Invoke-Api DELETE "/config/devices/$($d.deviceID)" | Out-Null; Ok "removed unused device $($d.deviceID.Substring(0,7))..." } catch {} }
        }
    }
}

function Show-All {
    Write-Host ""; Hr; Write-C "All RetroSync folders on the NAS" White; Hr
    $folders = Get-RetrosyncFolders
    if ($folders.Count -eq 0) { Inf "No retrosync-* folders configured."; return }
    foreach ($f in $folders) { "{0,-36} {1}" -f $f.id, $f.path | ForEach-Object { Write-Host "  $_" } }
}

function Remove-User {
    Write-Host ""
    $folders = Get-RetrosyncFolders
    if ($folders.Count -eq 0) { Inf "No RetroSync users found."; return }
    $byUser = $folders | Group-Object { Get-UserFromId $_.id } | Sort-Object Name
    $names = @($byUser.Name)
    Write-Host "Users:"
    for ($i=0; $i -lt $names.Count; $i++) {
        $cnt = $byUser[$i].Count
        "    [{0}] {1,-24} ({2} folder(s))" -f ($i+1), $names[$i], $cnt | ForEach-Object { Write-Host $_ }
    }
    $sel = Ask "Remove which user (number, blank to cancel)"
    if ([string]::IsNullOrEmpty($sel)) { return }
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $names.Count) { Wn "Invalid choice."; return }
    $user = $names[[int]$sel - 1]
    $ids = @($folders | Where-Object { (Get-UserFromId $_.id) -eq $user } | Select-Object -ExpandProperty id)
    Write-Host ""; Wn "About to remove $($ids.Count) folder config(s) for user '$user':"
    $ids | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
    if (AskYn "Proceed? (configs only; data files are left untouched)" 'n') {
        foreach ($id in $ids) { Remove-FolderConfig $id }
        Remove-OrphanDevices
        Write-Host ""; Inf "Done. If you also want the DATA gone, delete that user's directory on the NAS."
    }
}

function Remove-Folders {
    Write-Host ""
    $folders = Get-RetrosyncFolders
    if ($folders.Count -eq 0) { Inf "No retrosync-* folders configured."; return }
    for ($i=0; $i -lt $folders.Count; $i++) { "    [{0}] {1}" -f ($i+1), $folders[$i].id | ForEach-Object { Write-Host $_ } }
    Write-Host "Enter numbers to remove, space-separated (e.g. '1 3 4'), blank to cancel:"
    $sel = Ask "Remove"
    if ([string]::IsNullOrEmpty($sel)) { return }
    $chosen = @()
    foreach ($n in ($sel -split '\s+')) { if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $folders.Count) { $chosen += $folders[[int]$n-1].id } }
    if ($chosen.Count -eq 0) { Wn "Nothing valid selected."; return }
    Write-Host ""; Wn "Will remove:"; $chosen | ForEach-Object { Write-Host "    $_" }; Write-Host ""
    if (AskYn "Proceed?" 'n') { foreach ($id in $chosen) { Remove-FolderConfig $id }; Remove-OrphanDevices }
}

function Clear-AllFolders {
    Write-Host ""
    $folders = Get-RetrosyncFolders
    if ($folders.Count -eq 0) { Inf "No retrosync-* folders configured."; return }
    Wn "This removes ALL $($folders.Count) retrosync-* folder config(s) from the NAS Syncthing."
    Wn "Data files are NOT deleted. Re-run setup to recreate folders."
    Write-Host ""
    if ((Ask "Type 'WIPE' to confirm") -ne 'WIPE') { Inf "Cancelled."; return }
    foreach ($f in $folders) { Remove-FolderConfig $f.id }
    Remove-OrphanDevices
}

function Main {
    $title = "RetroSync reset / cleanup"
    if ($DryRun) { $title += "  (dry run - no changes)" }
    Write-C $title White
    Connect-Nas
    while ($true) {
        Write-Host ""; Hr
        Write-Host "  [1] Show all RetroSync folders on the NAS"
        Write-Host "  [2] Remove a user (all their folders)"
        Write-Host "  [3] Remove specific folders"
        Write-Host "  [4] Wipe ALL RetroSync folders (fresh start)"
        Write-Host "  [5] Prune unused device pairings"
        Write-Host "  [6] Exit"
        Hr
        switch (Ask "Choice" "1") {
            '1' { Show-All }
            '2' { Remove-User }
            '3' { Remove-Folders }
            '4' { Clear-AllFolders }
            '5' { Remove-OrphanDevices }
            '6' { return }
            default { Wn "Pick 1-6." }
        }
    }
}
Main
