# stop.ps1 - BlockMouseToEdge.ps1 の常駐プロセスを停止する
$ErrorActionPreference = 'SilentlyContinue'

$targets = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match '-File\s+.*BlockMouseToEdge\.ps1' -and $_.ProcessId -ne $PID }

if ($targets) {
    foreach ($p in $targets) {
        Stop-Process -Id $p.ProcessId -Force -Confirm:$false
    }
    Write-Host ("停止しました (プロセス数: {0})" -f @($targets).Count)
} else {
    Write-Host "起動中のブロックプロセスは見つかりませんでした。"
}
