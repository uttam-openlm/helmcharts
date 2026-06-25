<#
.SYNOPSIS
  install.ps1 — download and install the `openlm` OpenLM installer CLI on Windows.

.DESCRIPTION
  PowerShell counterpart to install.sh. Resolves the latest installer release
  (or a pinned version), downloads the Windows zip, verifies its checksum,
  extracts openlm.exe, installs it, and adds the install dir to the user PATH.

.EXAMPLE
  irm https://raw.githubusercontent.com/uttam-openlm/helmcharts/main/install.ps1 | iex

.NOTES
  Environment overrides (set before running):
    $env:OPENLM_REPO         GitHub owner/repo to download from (default: uttam-openlm/helmcharts)
    $env:OPENLM_VERSION      version to install, e.g. 1.2.3 (default: latest installer release)
    $env:OPENLM_INSTALL_DIR  install directory (default: $env:LOCALAPPDATA\openlm)
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Info($msg) { Write-Host $msg }
function Die($msg)  { Write-Error $msg; exit 1 }

$Repo       = if ($env:OPENLM_REPO)        { $env:OPENLM_REPO }        else { 'uttam-openlm/helmcharts' }
$InstallDir = if ($env:OPENLM_INSTALL_DIR) { $env:OPENLM_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'openlm' }
$Bin        = 'openlm.exe'

# --- Detect architecture (must match GoReleaser archive names) ---------------
# GoReleaser builds windows/amd64 only (windows/arm64 is ignored).
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { 'amd64' }
  'x86'   { 'amd64' }   # 32-bit shell on 64-bit Windows still runs the amd64 build
  default { Die "unsupported architecture '$($env:PROCESSOR_ARCHITECTURE)' (only amd64 is published for Windows)" }
}

# --- Resolve version ---------------------------------------------------------
$version = $env:OPENLM_VERSION
if (-not $version) {
  Info "Resolving latest openlm release from $Repo..."
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'openlm-install' }
  } catch {
    Die "could not query GitHub releases for $Repo (set `$env:OPENLM_VERSION to install a specific version): $($_.Exception.Message)"
  }
  $version = $rel.tag_name
  if (-not $version) { Die "could not find a release in $Repo (set `$env:OPENLM_VERSION to install a specific version)" }
}
$version = $version.TrimStart('v')   # tolerate a leading 'v'
$tag     = "v$version"

$asset = "openlm_${version}_windows_${arch}.zip"
$base  = "https://github.com/$Repo/releases/download/$tag"

Info "Installing openlm v$version (windows/$arch) from $Repo..."

# --- Download + verify + extract in a temp dir -------------------------------
$tmp = Join-Path $env:TEMP ("openlm-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  $zipPath = Join-Path $tmp $asset
  try {
    Invoke-WebRequest -Uri "$base/$asset" -OutFile $zipPath -UseBasicParsing
  } catch {
    Die "download failed: $base/$asset"
  }

  # Checksum verification (non-fatal if checksums.txt is unavailable)
  $sumsPath = Join-Path $tmp 'checksums.txt'
  try {
    Invoke-WebRequest -Uri "$base/checksums.txt" -OutFile $sumsPath -UseBasicParsing
  } catch {
    Info 'warn: checksums.txt unavailable — skipping verification'
  }
  if (Test-Path $sumsPath) {
    $want = (Select-String -Path $sumsPath -Pattern ([regex]::Escape($asset)) |
             Select-Object -First 1).Line -split '\s+' | Select-Object -First 1
    if ($want) {
      $got = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
      if ($got -ne $want.ToLower()) {
        Die "checksum mismatch for $asset (want $want, got $got)"
      }
      Info 'Checksum OK.'
    }
  }

  Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
  $extracted = Join-Path $tmp $Bin
  if (-not (Test-Path $extracted)) { Die "archive did not contain '$Bin'" }

  # --- Install ---------------------------------------------------------------
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $dest = Join-Path $InstallDir $Bin
  Move-Item -Path $extracted -Destination $dest -Force
  Info ''
  Info "Installed openlm to $dest"
}
finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

# --- Add install dir to user PATH if not already there -----------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($userPath -split ';') -contains $InstallDir
if (-not $onPath) {
  $newPath = if ([string]::IsNullOrEmpty($userPath)) { $InstallDir } else { "$userPath;$InstallDir" }
  [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
  $env:Path = "$env:Path;$InstallDir"   # make it usable in the current session too
  Info "Added $InstallDir to your user PATH (open a new terminal for it to persist)."
}

# --- Runtime prerequisites (non-fatal) + next steps --------------------------
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Info "note: 'kubectl' not found on PATH — openlm needs it at runtime (winget install Kubernetes.kubectl)"
}
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
  Info "note: 'helm' not found on PATH — openlm needs it at runtime (winget install Helm.Helm)"
}
Info ''
Info 'Next steps:'
Info '  openlm pull      # download the openlm_mono chart'
Info '  openlm setup     # run the interactive installer'
