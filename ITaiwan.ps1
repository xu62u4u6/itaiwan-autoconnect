#requires -Version 5.1
[CmdletBinding()]
param([switch]$Check, [switch]$InspectPortal, [switch]$Once, [switch]$MonitorOnly, [string]$DataDirectory)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Auth.ps1"
. "$PSScriptRoot\AppCore.ps1"
Add-Type -Path "$PSScriptRoot\Wifi.cs"
Add-Type -AssemblyName System.Net.Http

if ($InspectPortal) {
    $inspectionClient = New-ConsentClient
    try {
        $form = Get-OfficialConsentForm $inspectionClient
        [pscustomobject]@{ Validated=$true; Destination=$form.Uri.AbsoluteUri; FieldNames=@($form.Fields.Keys); Submitted=$false } | ConvertTo-Json
    } finally { $inspectionClient.Dispose() }
    exit 0
}

if ($Check) {
    # Read only: no profile creation, connection requests, browser or startup changes.
    $adapters = @([ITaiwan.Wifi]::Snapshot())
    [pscustomobject]@{
        PowerShell = $PSVersionTable.PSVersion.ToString()
        AdapterCount = $adapters.Count
        Adapters = @($adapters | Select-Object Description, State, @{n='IsITaiwan';e={$_.Ssid -ceq 'iTaiwan'}})
    } | ConvertTo-Json -Depth 4
    exit 0
}

$script:DataDir = if ($DataDirectory) { $DataDirectory } else { Join-Path $env:LOCALAPPDATA 'ITaiwanAutoConnect' }
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$script:LogPath = Join-Path $dataDir 'itaiwan.log'
$stopPath = Join-Path $dataDir 'stop.flag'
$portalTimePath = Join-Path $dataDir 'consent-time.txt'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($DataDirectory -and -not $MonitorOnly) { throw 'Custom data directory is only supported with -MonitorOnly.' }
$mutexSuffix = if ($MonitorOnly) { '-Diagnostic' } else { '' }
$mutex = New-Object Threading.Mutex($false, "Local\ITaiwanAutoConnect-$sid$mutexSuffix")
$acquired = $false
$client = $null
try {
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { Write-Host 'Already running.'; exit 0 }
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $client.MaxResponseContentBufferSize = 4096
    $internetProbe=@{WasITaiwan=$false;NextCheck=[DateTime]::MinValue;Online=$false}
    $lastConnect = [DateTime]::MinValue
    $lastPortal = [DateTime]::MinValue
    if (Test-Path -LiteralPath $portalTimePath) {
        try { $lastPortal = [DateTime]::Parse((Get-Content -LiteralPath $portalTimePath -Raw)).ToUniversalTime() } catch { }
    }
    $previous = ''
    $tail = [pscustomobject]@{State='Starting';IPs=@()}
    $nextTail = [DateTime]::MinValue
    Write-Log 'Started v4.4. Tray controls, Tailscale status and optional Gmail notifications enabled.'
    Write-WorkerHeartbeat 'Started'
    while (-not (Test-Path -LiteralPath $stopPath)) {
        try {
            Write-WorkerHeartbeat 'WifiSnapshot'
            $adapters = @([ITaiwan.Wifi]::Snapshot())
            Write-WorkerHeartbeat 'WindowsConnectivity'
            $windowsOnline = Test-WindowsInternet
            $now = [DateTime]::UtcNow
            $retryRequested=Test-Path (Join-Path $dataDir 'retry.flag')
            $online=if($MonitorOnly){$windowsOnline}else{Get-ConnectionInternet -Adapters $adapters -WindowsOnline $windowsOnline -Client $client -ProbeState $internetProbe -Now $now -Force:$retryRequested}
            if ($retryRequested) {
                Remove-Item (Join-Path $dataDir 'retry.flag') -Force
                $lastConnect=[DateTime]::MinValue; $lastPortal=[DateTime]::MinValue; $nextTail=[DateTime]::MinValue
            }
            if ($now -ge $nextTail) { Write-WorkerHeartbeat 'TailscaleStatus'; $tail=Get-TailscaleSummary; $nextTail=$now.AddSeconds(60) }
            $paused=(Get-PauseUntil) -gt $now
            $action = Get-NextAction -Adapters $adapters -Online $online -SinceConnect ($now - $lastConnect).TotalSeconds -SincePortal ($now - $lastPortal).TotalSeconds
            if ($paused) { $action='Paused' }
            Write-AppJson (Join-Path $dataDir 'status.json') @{Version="4.4";UpdatedUtc=$now.ToString('o');Online=$online;Action=$action;Tailscale=$tail;WorkerPid=$PID}
            if (-not $MonitorOnly) {
                Write-WorkerHeartbeat 'Notifications'
                Update-ConnectionEvents -Online $online -TailState $tail.State -Now $now
                if (Test-Path (Join-Path $dataDir 'mailtest.flag')) {
                    Add-MailEvent 'Test' '這是 iTaiwan 連線助手的測試通知。寄送功能已成功連到 Gmail SMTP 伺服器。'
                    Remove-Item (Join-Path $dataDir 'mailtest.flag') -Force
                }
                Write-WorkerHeartbeat 'MailDelivery'
                Send-PendingMail -Online $online
            }
            if ($action -ne $previous) { Write-Log "State: $action"; $previous = $action }
            if (-not $MonitorOnly -and $action -eq 'Connect') {
                Write-WorkerHeartbeat 'WifiConnect'
                $lastConnect = $now
                foreach ($adapter in $adapters | Where-Object { $_.State -eq 4 }) {
                    [ITaiwan.Wifi]::Connect($adapter.Id)
                    Write-Log 'Requested iTaiwan connection; waiting for Windows to confirm association.'
                }
            } elseif (-not $MonitorOnly -and $action -eq 'Portal') {
                # Recheck after the HTTP probe so a changed network does not open the wrong portal.
                $fresh = @([ITaiwan.Wifi]::Snapshot() | Where-Object { $_.State -eq 1 -and $_.Ssid -ceq 'iTaiwan' })
                if ($fresh.Count) {
                    # Persist attempt time before submission to bound retries after restarts.
                    $lastPortal = $now
                    Set-Content -LiteralPath $portalTimePath -Value $now.ToString('o') -Encoding ASCII
                    $consentClient = New-ConsentClient
                    try {
                        Write-WorkerHeartbeat 'ConsentSubmit'
                        $outcome=Invoke-ITaiwanPortalRecovery -ProbeClient $client -ConsentClient $consentClient -ConfirmNetwork {
                            param([uri]$ConsentUri)
                            return Test-PortalNetwork -Adapters @([ITaiwan.Wifi]::Snapshot()) -ConsentUri $ConsentUri
                        }
                        if($outcome -eq 'Submitted') {
                            Write-Log 'Submitted official iTaiwan consent. Verifying internet access.'
                            Start-Sleep -Seconds 2
                            Write-WorkerHeartbeat 'PostConsentProbe'
                            $internetProbe.Online=Test-Internet -Client $client
                            $internetProbe.NextCheck=[DateTime]::UtcNow.AddSeconds(60)
                            if($internetProbe.Online){Write-Log 'Internet probe passed after automatic consent.'}
                            else{Write-Log 'Internet probe still failing; will retry after cooldown.'}
                        } elseif($outcome -eq 'AlreadyOnline') {
                            $internetProbe.Online=$true
                            $internetProbe.NextCheck=[DateTime]::UtcNow.AddSeconds(60)
                            Write-Log 'Internet probe already passed; no consent needed.'
                        } else {Write-Log 'Network changed; consent skipped.'}
                    } finally { $consentClient.Dispose() }
                }
            }
        } catch {
            $message = 'Retrying: ' + $_.Exception.Message
            if ($message -ne $previous) { Write-Log $message; $previous = $message }
        }
        Write-WorkerHeartbeat 'Idle'
        if ($Once) { break }
        for ($i = 0; $i -lt 15 -and -not (Test-Path -LiteralPath $stopPath); $i++) { Start-Sleep -Seconds 1 }
    }
    Write-Log 'Worker stopped.'
} finally {
    if ($null -ne $client) { $client.Dispose() }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
