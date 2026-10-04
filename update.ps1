param(
    [string]$RepoPath,
    [switch]$CheckOnly
)

Add-Type -AssemblyName System.Windows.Forms

# Her zaman en ustte gorunmesi icin gorunmez bir owner form kullan
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$owner.WindowState = "Minimized"
$owner.Show()

$mode = if ($CheckOnly) { "CheckOnly" } else { "Update" }
[System.Windows.Forms.MessageBox]::Show(
    $owner,
    "selam`n`nMod: $mode`nRepoPath: $RepoPath",
    "Equicord AutoUpdater Test",
    "OK",
    "Information"
) | Out-Null

$owner.Dispose()

# Plugin'in tanidigi cikti; guncelleme dongusune girmesin diye
Write-Output "UP_TO_DATE"
exit 0
