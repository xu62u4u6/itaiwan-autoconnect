$ErrorActionPreference='Stop'
. "$PSScriptRoot\AppCore.ps1"
$count=0
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected $Expected, got $Actual"};$script:count++;Write-Host "PASS $Name"}
$start=[DateTime]::UtcNow.AddMinutes(-10)
$now=$start.AddMinutes(10)
$valid=[pscustomobject]@{WorkerPid=123;UpdatedUtc=$now.AddSeconds(-10).ToString('o');Stage='Idle'}
Check (Test-WorkerStalled 123 $start $valid $now) $false 'Recent heartbeat preserves worker'
$old=[pscustomobject]@{WorkerPid=123;UpdatedUtc=$now.AddSeconds(-121).ToString('o');Stage='MailDelivery'}
Check (Test-WorkerStalled 123 $start $old $now) $true 'Alive but stalled worker detected'
Check (Test-WorkerStalled 123 $now $null $now.AddSeconds(119)) $false 'Startup grace period'
Check (Test-WorkerStalled 123 $now $null $now.AddSeconds(120)) $true 'Missing heartbeat times out'
$wrong=[pscustomobject]@{WorkerPid=456;UpdatedUtc=$now.ToString('o')}
Check (Test-WorkerStalled 123 $start $wrong $now) $true 'Other process heartbeat cannot hide a hang'
$future=[pscustomobject]@{WorkerPid=123;UpdatedUtc=$now.AddDays(1).ToString('o')}
Check (Test-WorkerStalled 123 $start $future $now) $true 'Future timestamp cannot hide a hang'
$racing=[pscustomobject]@{WorkerPid=123;UpdatedUtc=$now.AddMilliseconds(1).ToString('o')}
Check (Test-WorkerStalled 123 $start $racing $now) $false 'Concurrent fresh heartbeat does not kill healthy worker'
$malformed=[pscustomobject]@{WorkerPid=123;UpdatedUtc='invalid'}
Check (Test-WorkerStalled 123 $start $malformed $now) $true 'Corrupt timestamp falls back to process start'
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$child=$null;$other=$null
try {
    $child=Start-Process $exe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru
    $other=Start-Process $exe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru
    $began=$child.StartTime.ToUniversalTime()
    $beat=[pscustomobject]@{WorkerPid=$child.Id;UpdatedUtc=$began.AddSeconds(4).ToString('o')}
    Check (Stop-StalledWorker $child $beat $began.AddSeconds(5) 2) $false 'Healthy live child is not killed'
    Check $child.HasExited $false 'Healthy child still running'
    Check (Stop-StalledWorker $child $beat $began.AddSeconds(7) 2) $true 'Terminate a real deliberately stalled child'
    Check ($child.WaitForExit(5000)) $true 'Stalled child actually exits'
    Check $other.HasExited $false 'Unrelated process remains running'
    Check (Stop-StalledWorker $child $beat $began.AddSeconds(9) 2) $false 'Already-exited child needs no termination'
    $child.Dispose();$child=$null
    $child=Start-Process $exe -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru
    Check $child.HasExited $false 'Replacement child starts successfully'
    Check (Test-WorkerStalled $child.Id $child.StartTime.ToUniversalTime() $beat ([DateTime]::UtcNow)) $false 'Previous instance heartbeat does not kill replacement during grace'
    Write-Host "$count watchdog checks passed. Production worker and networks untouched."
}finally{
    foreach($p in @($child,$other)){if($null -ne $p){if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(5000)};$p.Dispose()}}
}
