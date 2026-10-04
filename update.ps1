param(
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
    Write-Output "HATA: '$RepoPath' bir git deposu degil."
    exit 2
}

Set-Location $RepoPath

git fetch origin 2>&1 | Out-Null
$local  = (git rev-parse HEAD).Trim()
$remote = (git rev-parse "@{u}").Trim()

if ($local -eq $remote) {
    Write-Output "UP_TO_DATE"
    exit 0
}

if ($CheckOnly) {
    Write-Output "UPDATE_AVAILABLE"
    exit 0
}

Write-Output "Guncelleme bulundu, indiriliyor..."
git pull --autostash 2>&1
if ($LASTEXITCODE -ne 0) { Write-Output "HATA: git pull basarisiz."; exit 3 }

pnpm install --frozen-lockfile 2>&1
if ($LASTEXITCODE -ne 0) { Write-Output "HATA: pnpm install basarisiz."; exit 4 }

pnpm build 2>&1
if ($LASTEXITCODE -ne 0) { Write-Output "HATA: pnpm build basarisiz."; exit 5 }

Write-Output "UPDATED"
exit 0
