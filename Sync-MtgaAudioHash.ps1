<#
.SYNOPSIS
  Extrait le hash du manifest Audio MTGA depuis Player.log et le pousse dans un repo git.

.DESCRIPTION
  - Lit Player.log (puis Player-prev.log en secours), même si le jeu tourne (lecture partagée).
  - Récupère la dernière "Doorbell response" et en sort les hashes + la version du client.
  - N'écrit/commit/push QUE le petit fichier JSON (jamais le log complet : il contient
    des infos de compte).
  - Ne fait rien si le hash n'a pas changé.

.EXAMPLE
  # Installation de la tâche planifiée (une seule fois)
  .\Sync-MtgaAudioHash.ps1 -Install -RepoPath C:\Repos\mtga-audio-hash

.EXAMPLE
  # Test à blanc : affiche ce qui serait écrit, sans toucher à git
  .\Sync-MtgaAudioHash.ps1 -RepoPath C:\Repos\mtga-audio-hash -DryRun
#>
[CmdletBinding()]
param(
    # Clone local du repo qui reçoit le JSON
    [string]$RepoPath = (Join-Path $env:USERPROFILE 'mtga-audio-hash'),
    # Chemin du fichier dans le repo
    [string]$OutFile  = 'audio_manifest.json',
    [string]$Branch   = 'main',
    # Dossier du Player.log (le jeu l'écrit toujours ici, même installé via Steam sur E:)
    [string]$LogDir   = (Join-Path $env:USERPROFILE 'AppData\LocalLow\Wizards Of The Coast\MTGA'),
    # Pour tester sur un log précis
    [string]$LogPath,
    [switch]$DryRun,
    [switch]$Install,
    [int]$RepeatHours = 3
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $env:LOCALAPPDATA 'mtga-hash-sync.log'

function Write-Log([string]$msg) {
    $line = '{0:u}  {1}' -f (Get-Date), $msg
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line } catch {}
}

# ---------------------------------------------------------------------------
# Installation de la tâche planifiée
# ---------------------------------------------------------------------------
if ($Install) {
    $self = $MyInvocation.MyCommand.Path
    $arg  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -RepoPath `"$RepoPath`" -OutFile `"$OutFile`" -Branch `"$Branch`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
        # Relance périodique : récupère le hash après une session de jeu sans reboot
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
            -RepetitionInterval (New-TimeSpan -Hours $RepeatHours))
    )
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'MTGA Audio Hash Sync' -Action $action -Trigger $triggers `
        -Settings $settings -Description 'Pousse le hash du manifest audio MTGA vers git' -Force | Out-Null
    Write-Log "Tâche planifiée 'MTGA Audio Hash Sync' installée (logon + toutes les $RepeatHours h)."
    return
}

# ---------------------------------------------------------------------------
# Lecture du log (partagée : le jeu peut être ouvert)
# ---------------------------------------------------------------------------
function Read-SharedText([string]$path) {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        return $sr.ReadToEnd()
    } finally { $fs.Dispose() }
}

function Get-DoorbellInfo([string]$text) {
    $matches_ = [regex]::Matches($text, 'Doorbell response:\s*(\{.*\})')
    for ($i = $matches_.Count - 1; $i -ge 0; $i--) {      # la plus récente d'abord
        try { $json = $matches_[$i].Groups[1].Value | ConvertFrom-Json } catch { continue }
        $audio = $json.bundleManifests | Where-Object { $_.category -eq 'Audio' }        | Select-Object -First 1
        $loc   = $json.bundleManifests | Where-Object { $_.category -eq 'Localization' } | Select-Object -First 1
        if ($audio -and $audio.hash) {
            $ver = $null
            $vm = [regex]::Match($text, 'External_([0-9][0-9.]+)-windows\.mtga')
            if ($vm.Success) { $ver = $vm.Groups[1].Value }
            return [ordered]@{
                audio_manifest_hash        = $audio.hash
                localization_manifest_hash = $loc.hash
                client_version             = $ver
            }
        }
    }
    return $null
}

$candidates = if ($LogPath) { @($LogPath) } else {
    @((Join-Path $LogDir 'Player.log'), (Join-Path $LogDir 'Player-prev.log'))
}

$info = $null; $source = $null
foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    $info = Get-DoorbellInfo (Read-SharedText $c)
    if ($info) { $source = Split-Path $c -Leaf; break }
}
if (-not $info) {
    Write-Log "Aucune 'Doorbell response' trouvée dans $($candidates -join ', ') (jeu jamais lancé ?)."
    exit 0
}
Write-Log "Hash Audio trouvé ($source) : $($info.audio_manifest_hash)  version=$($info.client_version)"

# ---------------------------------------------------------------------------
# Comparaison avec ce qui est déjà dans le repo
# ---------------------------------------------------------------------------
$target = Join-Path $RepoPath $OutFile
if (-not $DryRun -and -not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Log "ERREUR : $RepoPath n'est pas un clone git. Fais d'abord : git clone <url> `"$RepoPath`""
    exit 1
}

if (Test-Path $target) {
    try {
        $old = Get-Content $target -Raw | ConvertFrom-Json
        if ($old.audio_manifest_hash -eq $info.audio_manifest_hash) {
            Write-Log 'Hash inchangé, rien à faire.'
            exit 0
        }
    } catch {}
}

$info['updated_utc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$info['source']      = $source
$jsonOut = ($info | ConvertTo-Json) + "`n"

if ($DryRun) {
    Write-Log 'DRY RUN - contenu qui serait commité :'
    Write-Host $jsonOut
    exit 0
}

# ---------------------------------------------------------------------------
# Commit + push
# ---------------------------------------------------------------------------
function Invoke-Git {
    $out = & git -C $RepoPath @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') a échoué : $out" }
    return $out
}

try {
    Invoke-Git pull --rebase --autostash origin $Branch | Out-Null
    [System.IO.File]::WriteAllText($target, $jsonOut, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Git add -- $OutFile | Out-Null
    $short = $info.audio_manifest_hash.Substring(0, 8)
    Invoke-Git commit -m "audio manifest $short (MTGA $($info.client_version))" | Out-Null
    Invoke-Git push origin $Branch | Out-Null
    Write-Log "Push OK : $($info.audio_manifest_hash)"
} catch {
    Write-Log "ERREUR : $_"
    exit 1
}
