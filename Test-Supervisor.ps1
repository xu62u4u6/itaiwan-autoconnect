$ErrorActionPreference='Stop'
. "$PSScriptRoot\AppCore.ps1"
# Execute the actual supervisor function without starting the UI or production worker.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Tray.ps1'),[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-AppWorker'},$true)
Add-Type 'public class WatchdogTestProcess { public int Id; public System.DateTime StartTime; public bool HasExited; public bool Killed; public void Kill(){Killed=true;HasExited=true;} public void Dispose(){} }'
$script:count=0;$script:nextId=9000
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected $Expected, got $Actual"};$script:count++;Write-Host "PASS $Name"}
function Find-ExistingAppWorker {param($Root) return $null}
function Start-Process {param($FilePath,$ArgumentList,[switch]$PassThru,$WindowStyle)
    $script:nextId++;$p=[WatchdogTestProcess]::new();$p.Id=$script:nextId;$p.StartTime=[DateTime]::UtcNow;return $p
}
$script:DataDir=Join-Path $env:TEMP ('ITaiwanSupervisorTest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $script:DataDir | Out-Null
$isolatedFunction=Join-Path $script:DataDir "Supervisor.ps1"
Set-Content $isolatedFunction $fn.Extent.Text -Encoding UTF8
. $isolatedFunction
$SmokeTest=$false;$script:Worker=$null;$script:LastWorkerStart=[DateTime]::MinValue
$script:Restarts=[Collections.Generic.List[DateTime]]::new()
try {
    Start-AppWorker
    Check ($null -ne $script:Worker) $true 'Supervisor starts worker'
    $old=$script:Worker;$old.StartTime=[DateTime]::UtcNow.AddMinutes(-10)
    $script:LastWorkerStart=[DateTime]::UtcNow.AddMinutes(-10)
    Write-AppJson (Join-Path $script:DataDir 'heartbeat.json') @{WorkerPid=$old.Id;UpdatedUtc=[DateTime]::UtcNow.AddSeconds(-121).ToString('o');Stage='WifiSnapshot'}
    Set-AppPause 30
    $pause=Get-PauseUntil
    Start-AppWorker
    Check $old.Killed $true 'Supervisor terminates stalled worker'
    Check (Test-Path (Join-Path $script:DataDir 'watchdog.log')) $true 'Recovery records last stage'
    Start-AppWorker
    Check ($script:Worker.Id -ne $old.Id) $true 'Next supervisor tick starts replacement'
    Check (Get-PauseUntil) $pause 'Automatic restart preserves pause'
    Write-WorkerHeartbeat 'Test'
    Write-AppJson (Join-Path $script:DataDir 'heartbeat.json') @{WorkerPid=$script:Worker.Id;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
    Start-AppWorker
    Check $script:Worker.Killed $false 'Fresh replacement remains running'
    $script:Worker.StartTime=[DateTime]::UtcNow.AddMinutes(-10)
    Remove-Item (Join-Path $script:DataDir 'heartbeat.json')
    Set-Content (Join-Path $script:DataDir 'stop.flag') 'stop'
    Start-AppWorker
    Check $script:Worker.Killed $false 'Stop flag prevents watchdog termination'
    $script:Worker.HasExited=$true;$prior=$script:Worker.Id
    Start-AppWorker
    Check $script:Worker.Id $prior 'Stop flag prevents restart'
    Remove-Item (Join-Path $script:DataDir 'stop.flag')
    Start-AppWorker
    Check $script:Worker.Id $prior 'Restart throttle prevents rapid restart'
    $script:LastWorkerStart=[DateTime]::UtcNow.AddSeconds(-31)
    $script:Restarts.Clear();1..3|ForEach-Object{$script:Restarts.Add([DateTime]::UtcNow.AddSeconds(-60))}
    Start-AppWorker
    Check $script:Worker.Id $prior 'Restart budget limits repeated failures'
    $script:Restarts.Clear();$script:Restarts.Add([DateTime]::UtcNow.AddMinutes(-11))
    Start-AppWorker
    Check ($script:Worker.Id -ne $prior) $true 'Restart resumes after budget window expires'
    Write-Host "$count supervisor checks passed with mock processes; production untouched."
} finally {Remove-Item $script:DataDir -Recurse -Force}
