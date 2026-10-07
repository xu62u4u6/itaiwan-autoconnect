$ErrorActionPreference='Stop'
. "$PSScriptRoot\AppCore.ps1"
$root=Join-Path $env:TEMP ('ITaiwanAdoptionTest-'+[guid]::NewGuid().ToString('N'))
$script:DataDir=$root;New-Item -ItemType Directory $root | Out-Null
$count=0;$worker=$null;$other=$null;$diagnostic=$null;$adopted=$null
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected $Expected, got $Actual"};$script:count++;Write-Host "PASS $Name"}
try{
    Complete-AppUi $false
    Check (Test-Path (Join-Path $root 'stop.flag')) $false 'Unexpected UI exit never disables native recovery'
    Complete-AppUi $true
    Check (Test-Path (Join-Path $root 'stop.flag')) $true 'Explicit user stop remains intentional'
    Remove-Item (Join-Path $root 'stop.flag')
    Set-Content (Join-Path $root 'ITaiwan.ps1') 'param([switch]$MonitorOnly,[string]$DataDirectory) Start-Sleep -Seconds 60'
    Set-Content (Join-Path $root 'Other.ps1') 'Start-Sleep -Seconds 60'
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $worker=Start-Process $exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'ITaiwan.ps1')+'"') -PassThru -WindowStyle Hidden
    $other=Start-Process $exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Other.ps1')+'"') -PassThru -WindowStyle Hidden
    $diagnostic=Start-Process $exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'ITaiwan.ps1')+'" -MonitorOnly -DataDirectory "'+$root+'"') -PassThru -WindowStyle Hidden
    $adopted=Find-ExistingAppWorker $root
    Check ($null -ne $adopted) $true 'Recover exact existing worker after UI ownership is lost'
    Check $adopted.Id $worker.Id 'Adoption matches script path, owner, session and creation time'
    Check ($null -eq (Find-ExistingAppWorker (Join-Path $root 'Different'))) $true 'Unrelated installation is never adopted'
    $now=$adopted.StartTime.ToUniversalTime().AddSeconds(125)
    Check (Stop-StalledWorker $adopted $null $now) $true 'Heartbeat watchdog can terminate adopted stalled worker'
    Check ($worker.WaitForExit(5000)) $true 'Adopted worker actually exits'
    Check $other.HasExited $false 'Unrelated child remains running'
    Check ($null -eq (Find-ExistingAppWorker $root)) $true 'Same-path diagnostic alone is never adopted'
    Check $diagnostic.HasExited $false 'Same-path MonitorOnly diagnostic survives recovery'
    Write-Host "$count recovery checks passed with harmless isolated children. Production untouched."
}finally{
    foreach($p in @($worker,$other,$diagnostic,$adopted)){if($null -ne $p){if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(5000)};$p.Dispose()}}
    Remove-Item $root -Recurse -Force
}
