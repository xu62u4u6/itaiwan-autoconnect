$ErrorActionPreference='Stop'
. "$PSScriptRoot\AppCore.ps1"
$script:DataDir=Join-Path $env:TEMP ('ITaiwanUnit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $script:DataDir | Out-Null
$count=0
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected $Expected, got $Actual"};$script:count++;Write-Host "PASS $Name"}
function Check-Throws([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Check $failed $true $Name}
try {
    Check (Get-AppSettings).MailEnabled $false 'Mail disabled until user configures it'
    Save-MailSettings $true 'example@gmail.com' 'recipient@gmail.com' 'abcd efgh ijkl mnop'
    $settings=Get-AppSettings
    Check $settings.MailEnabled $true 'Mail settings persisted'
    Check ($settings.Secret -match 'abcdefghijklmnop') $false 'No plaintext app password in configuration'
    $secure=ConvertTo-SecureString $settings.Secret
    try { Check ([Net.NetworkCredential]::new('', $secure).Password -ceq 'abcdefghijklmnop') $true 'DPAPI roundtrip on current Windows account' } finally {$secure.Dispose()}
    Check-Throws { Save-MailSettings $true 'other@gmail.com' 'recipient@gmail.com' '' } 'Changing sender requires new authorization'
    Check-Throws { Save-MailSettings $true 'not-an-email' 'recipient@gmail.com' '' } 'Reject invalid mail address'
    Set-AppPause 30
    Check ((Get-PauseUntil)-gt [DateTime]::UtcNow.AddMinutes(29)) $true 'Pause persists with expiration'
    Set-AppPause 0
    Check ((Get-PauseUntil)-lt [DateTime]::UtcNow) $true 'Resume clears pause'
    $tail=Convert-TailscaleSummary ([pscustomobject]@{BackendState='Running';Self=[pscustomobject]@{Online=$true};TailscaleIPs=@('100.100.1.2')})
    Check $tail.State 'Ready' 'Tailscale reports local ready state'
    $tail=Convert-TailscaleSummary ([pscustomobject]@{BackendState='Running';Self=[pscustomobject]@{Online=$false};TailscaleIPs=@()})
    Check $tail.State 'Offline' 'Running daemon alone does not prove online'
    $tail=Convert-TailscaleSummary ([pscustomobject]@{BackendState='NeedsLogin'})
    Check $tail.State 'NeedsLogin' 'Expired Tailscale login is distinct'
    $now=[DateTime]::UtcNow
    Update-ConnectionEvents $true 'Ready' $now
    Check (Test-Path (Join-Path $script:DataDir 'outbox/Recovered.json')) $false 'No recovery notification on ordinary startup'
    Update-ConnectionEvents $false 'Offline' $now.AddSeconds(15)
    Update-ConnectionEvents $true 'Ready' $now.AddSeconds(75)
    Check (Test-Path (Join-Path $script:DataDir 'outbox/Recovered.json')) $true 'Offline to online generates recovery event'
    Update-ConnectionEvents $true 'Ready' $now.AddSeconds(90)
    Add-MailEvent 'Recovered' 'duplicate'
    Check @(Get-ChildItem (Join-Path $script:DataDir 'outbox') -Filter '*.json').Count 1 'Repeated events coalesce'
    $script:delivered=0
    Send-PendingMail $false {param($s,$e) $script:delivered++}
    Check $script:delivered 0 'Never send while offline'
    Send-PendingMail $true {param($s,$e) $script:delivered++}
    Check $script:delivered 1 'Queued event delivered after recovery'
    Check @(Get-ChildItem (Join-Path $script:DataDir 'outbox') -Filter '*.json').Count 0 'Remove event after accepted delivery'
    Add-MailEvent 'Test' 'test body'
    Send-PendingMail $true {param($s,$e) $script:delivered++}
    Check $script:delivered 1 'One mail attempt per minute across events'
    Remove-Item (Join-Path $script:DataDir 'mail-status.json')
    Send-PendingMail $true {param($s,$e) throw 'Simulated SMTP failure'}
    $queued=Read-AppJson (Join-Path $script:DataDir 'outbox/Test.json') $null
    Check $queued.Attempts 1 'Failed mail remains queued'
    Check ([DateTime]::Parse($queued.NextTry)-gt [DateTime]::UtcNow.AddSeconds(100)) $true 'Exponential retry delay after failure'
    Update-ConnectionEvents $true 'NeedsLogin' $now.AddSeconds(105)
    Update-ConnectionEvents $true 'NeedsLogin' $now.AddSeconds(225)
    Check (Test-Path (Join-Path $script:DataDir 'outbox/TailscaleIssue.json')) $true 'Tailscale persistent issue alert'
    Update-ConnectionEvents $true 'Ready' $now.AddSeconds(240)
    Check (Test-Path (Join-Path $script:DataDir 'outbox/TailscaleRecovered.json')) $true 'Tailscale recovery notification'
    Save-MailSettings $false 'example@gmail.com' 'recipient@gmail.com' ''
    Check (Get-AppSettings).Secret '' 'Disabling mail erases saved credential'
    Check @(Get-ChildItem (Join-Path $script:DataDir 'outbox') -Filter '*.json').Count 0 'Disabling mail clears pending events'
    Add-MailEvent 'Test' 'disabled'
    Check @(Get-ChildItem (Join-Path $script:DataDir 'outbox') -Filter '*.json').Count 0 'Disabled notification cannot enqueue mail'
    Write-Host "$count QoL checks passed. No real email sent."
} finally {Remove-Item -LiteralPath $script:DataDir -Recurse -Force}
