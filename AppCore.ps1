Set-StrictMode -Version Latest

function Read-AppJson {
    param([string]$Path, $Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $Default }
}
function Write-AppJson {
    param([string]$Path, $Value)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Get-AppSettings {
    $defaults = @{ MailEnabled=$false; Sender=''; Recipient=''; Secret='' }
    $saved = Read-AppJson (Join-Path $script:DataDir 'settings.json') $null
    if ($null -ne $saved) {
        foreach ($key in @($defaults.Keys)) {
            if ($null -ne $saved.PSObject.Properties[$key]) { $defaults[$key] = $saved.$key }
        }
    }
    return [pscustomobject]$defaults
}
function Save-MailSettings {
    param([bool]$Enabled, [string]$Sender, [string]$Recipient, [string]$Password)
    $settings = Get-AppSettings
    $senderChanged = $settings.Sender -ine $Sender.Trim()
    if ($Enabled) {
        $senderAddress = [Net.Mail.MailAddress]::new($Sender.Trim())
        $recipientAddress = [Net.Mail.MailAddress]::new($Recipient.Trim())
        if ($senderAddress.Address -cne $Sender.Trim() -or $recipientAddress.Address -cne $Recipient.Trim()) { throw '請輸入完整電子郵件地址，不含顯示名稱。' }
        if ($senderChanged -and -not $Password) { throw '更換寄件帳號時，請重新輸入應用程式密碼。' }
    }
    if ($Password) {
        $normalized = $Password -replace '\s',''
        if ($normalized -notmatch '^[a-zA-Z]{16}$') { throw '請輸入 Google 提供的 16 個英文字母應用程式密碼。' }
        $secure = ConvertTo-SecureString $normalized -AsPlainText -Force
        try { $settings.Secret = ConvertFrom-SecureString $secure } finally { $secure.Dispose() }
    }
    if ($Enabled -and -not $settings.Secret) { throw '請先設定 Gmail 應用程式密碼。' }
    $settings.MailEnabled = $Enabled
    $settings.Sender = $Sender.Trim()
    $settings.Recipient = $Recipient.Trim()
    if (-not $Enabled) { $settings.Secret = '' }
    # Clear notifications addressed under an old configuration before enabling a new one.
    if ((Test-Path (Join-Path $script:DataDir 'outbox')) -and
        (-not $Enabled -or $senderChanged -or (Get-AppSettings).Recipient -ine $settings.Recipient)) {
        Get-ChildItem (Join-Path $script:DataDir 'outbox') -Filter '*.json' | Remove-Item -Force
    }
    Write-AppJson (Join-Path $script:DataDir 'settings.json') $settings
}
function Get-PauseUntil {
    $control = Read-AppJson (Join-Path $script:DataDir 'control.json') $null
    if ($null -ne $control -and $control.PauseUntil) {
        try { return [DateTime]::Parse($control.PauseUntil).ToUniversalTime() } catch { }
    }
    return [DateTime]::MinValue
}
function Set-AppPause {
    param([int]$Minutes)
    $until = if ($Minutes -gt 0) { [DateTime]::UtcNow.AddMinutes($Minutes).ToString('o') } else { '' }
    Write-AppJson (Join-Path $script:DataDir 'control.json') @{PauseUntil=$until}
}
function Get-TailscaleSummary {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return [pscustomobject]@{ State='NotInstalled'; IPs=@() } }
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($exe, 'status --json')
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) { $process.Kill(); return [pscustomobject]@{State='Timeout';IPs=@()} }
        if ($process.ExitCode -ne 0) { return [pscustomobject]@{State='Unavailable';IPs=@()} }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) { return [pscustomobject]@{State='Timeout';IPs=@()} }
        $parsed = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        return Convert-TailscaleSummary $parsed
    } catch { return [pscustomobject]@{State='Unavailable';IPs=@()} }
    finally { $process.Dispose() }
}
function Convert-TailscaleSummary {
    param($Status)
    $state = [string]$Status.BackendState
    $ips = @()
    if ($null -ne $Status.PSObject.Properties['TailscaleIPs']) { $ips = @($Status.TailscaleIPs) }
    if ($state -eq 'Running') {
        if ($null -ne $Status.PSObject.Properties['Self'] -and $null -ne $Status.Self -and
            $null -ne $Status.Self.PSObject.Properties['Online'] -and $Status.Self.Online) { $state = 'Ready' }
        else { $state = 'Offline' }
    }
    return [pscustomobject]@{ State=$state; IPs=$ips }
}
function Add-MailEvent {
    param([string]$Kind, [string]$Body)
    $settings = Get-AppSettings
    if (-not $settings.MailEnabled) { return }
    $dir = Join-Path $script:DataDir 'outbox'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Coalesce each event type; a network flapping does not generate an unbounded queue.
    $path = Join-Path $dir "$Kind.json"
    if (Test-Path $path) { return }
    Write-AppJson $path @{ Kind=$Kind; Body=$Body; Created=[DateTime]::UtcNow.ToString('o'); Attempts=0; NextTry=[DateTime]::UtcNow.ToString('o'); Sender=$settings.Sender; Recipient=$settings.Recipient }
}
function Update-ConnectionEvents {
    param([bool]$Online, [string]$TailState, [DateTime]$Now = [DateTime]::UtcNow)
    $path = Join-Path $script:DataDir 'monitor.json'
    $state = Read-AppJson $path ([pscustomobject]@{ OfflineSince=''; TailBadSince=''; TailAlerted=$false; TailPrevious=''; LastSeen='' })
    # Sleep or a long stopped interval is not a measured network outage.
    if ($state.LastSeen -and ($Now - [DateTime]::Parse($state.LastSeen).ToUniversalTime()).TotalMinutes -gt 5) {
        $state.OfflineSince=''; $state.TailBadSince=''; $state.TailAlerted=$false
    }
    if (-not $Online -and -not $state.OfflineSince) { $state.OfflineSince=$Now.ToString('o') }
    if ($Online -and $state.OfflineSince) {
        $seconds = [int]($Now - [DateTime]::Parse($state.OfflineSince).ToUniversalTime()).TotalSeconds
        if ($seconds -ge 30) {
            Add-MailEvent 'Recovered' "電腦 $env:COMPUTERNAME 已恢復上網。觀測到的中斷時間約 $seconds 秒。Tailscale 本機狀態：$TailState。這不是遠端端點可達性的保證。"
        }
        $state.OfflineSince=''
    }
    if ($TailState -eq 'Ready' -or $TailState -eq 'NotInstalled') {
        if ($state.TailAlerted -and $TailState -eq 'Ready') { Add-MailEvent 'TailscaleRecovered' "電腦 $env:COMPUTERNAME 的 Tailscale 本機狀態已恢復。未測試另一台設備到本機的連線。" }
        $state.TailBadSince=''; $state.TailAlerted=$false
    } elseif ($Online) {
        if (-not $state.TailBadSince) { $state.TailBadSince=$Now.ToString('o') }
        if (-not $state.TailAlerted -and ($Now - [DateTime]::Parse($state.TailBadSince).ToUniversalTime()).TotalSeconds -ge 120) {
            Add-MailEvent 'TailscaleIssue' "電腦 $env:COMPUTERNAME 可以上網，但 Tailscale 狀態已持續異常至少 2 分鐘：$TailState。程式沒有重啟或更改 VPN。"
            $state.TailAlerted=$true
        }
    } else { $state.TailBadSince='' }
    $state.TailPrevious=$TailState; $state.LastSeen=$Now.ToString('o')
    Write-AppJson $path $state
}
function Send-AppMail {
    param($Settings, $Event)
    $secure = ConvertTo-SecureString $Settings.Secret
    $message = [Net.Mail.MailMessage]::new($Settings.Sender, $Settings.Recipient)
    $smtp = [Net.Mail.SmtpClient]::new('smtp.gmail.com', 587)
    try {
        $message.Subject = '[iTaiwan 助手] ' + $Event.Kind
        $message.SubjectEncoding = [Text.Encoding]::UTF8
        $message.BodyEncoding = [Text.Encoding]::UTF8
        $message.Body = $Event.Body + "`r`n`r`n事件時間（UTC）：" + $Event.Created
        $smtp.EnableSsl = $true
        $smtp.UseDefaultCredentials = $false
        $smtp.Credentials = [Net.NetworkCredential]::new($Settings.Sender, $secure)
        $smtp.Timeout = 15000
        $smtp.Send($message)
    } finally { $smtp.Dispose(); $message.Dispose(); $secure.Dispose() }
}
function Send-PendingMail {
    param([bool]$Online, [scriptblock]$Transport = { param($s,$e) Send-AppMail $s $e })
    $settings = Get-AppSettings
    if (-not $Online -or -not $settings.MailEnabled) { return }
    $dir = Join-Path $script:DataDir 'outbox'
    if (-not (Test-Path $dir)) { return }
    $now = [DateTime]::UtcNow
    $mailStatePath = Join-Path $script:DataDir 'mail-status.json'
    $status = Read-AppJson $mailStatePath $null
    # At most one attempt per minute, across restarts and different event types.
    if ($null -ne $status -and ($now - [DateTime]::Parse($status.AttemptAt).ToUniversalTime()).TotalSeconds -lt 60) { return }
    foreach ($file in Get-ChildItem $dir -Filter '*.json' | Sort-Object LastWriteTimeUtc) {
        $event = Read-AppJson $file.FullName $null
        if ($null -eq $event) { continue }
        if ($event.Sender -ine $settings.Sender -or $event.Recipient -ine $settings.Recipient) { Remove-Item $file.FullName; continue }
        if ([DateTime]::Parse($event.NextTry).ToUniversalTime() -gt $now) { continue }
        Write-AppJson $mailStatePath @{State='Sending';AttemptAt=$now.ToString('o')}
        try {
            & $Transport $settings $event
            Remove-Item -LiteralPath $file.FullName
            Write-AppJson $mailStatePath @{State='Sent';AttemptAt=$now.ToString('o')}
        } catch {
            $event.Attempts++
            $delay = [Math]::Min(3600, 60 * [Math]::Pow(2, [Math]::Min(6,$event.Attempts)))
            $event.NextTry = $now.AddSeconds($delay).ToString('o')
            Write-AppJson $file.FullName $event
            # Do not log exceptions that could contain credentials or recipient information.
            Write-AppJson $mailStatePath @{State='Failed';AttemptAt=$now.ToString('o')}
        }
        break
    }
}

function Write-WorkerHeartbeat {
    param([string]$Stage)
    Write-AppJson (Join-Path $script:DataDir 'heartbeat.json') @{WorkerPid=$PID;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Stage=$Stage}
}
function Test-WorkerStalled {
    param([int]$WorkerId,[DateTime]$StartedUtc,$Heartbeat,[DateTime]$Now=[DateTime]::UtcNow,[int]$TimeoutSeconds=120)
    $lastProgress=$StartedUtc.ToUniversalTime()
    if ($null -ne $Heartbeat -and $null -ne $Heartbeat.PSObject.Properties['WorkerPid'] -and
        $null -ne $Heartbeat.PSObject.Properties['UpdatedUtc'] -and $Heartbeat.WorkerPid -eq $WorkerId) {
        try {
            $stamp=[DateTime]::Parse($Heartbeat.UpdatedUtc).ToUniversalTime()
            # A stale file from a previous process or a corrupt future timestamp must not hide a hang.
            if ($stamp -ge $lastProgress -and $stamp -le $Now.AddSeconds(1)) {
                $lastProgress=if($stamp -gt $Now){$Now}else{$stamp}
            }
        } catch { }
    }
    return ($Now-$lastProgress).TotalSeconds -ge $TimeoutSeconds
}
function Stop-StalledWorker {
    param($Worker,$Heartbeat,[DateTime]$Now=[DateTime]::UtcNow,[int]$TimeoutSeconds=120)
    if ($null -eq $Worker -or $Worker.HasExited) {return $false}
    if (-not (Test-WorkerStalled -WorkerId $Worker.Id -StartedUtc $Worker.StartTime.ToUniversalTime() -Heartbeat $Heartbeat -Now $Now -TimeoutSeconds $TimeoutSeconds)) {return $false}
    # Only the exact process object created by our supervisor may be terminated.
    $Worker.Kill()
    return $true
}

function Find-ExistingAppWorker {
    param([string]$Root)
    $expected=[regex]::Escape((Join-Path $Root 'ITaiwan.ps1'))
    $session=(Get-Process -Id $PID).SessionId
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $candidates=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop|Where-Object{
        $_.SessionId -eq $session -and $_.CommandLine -match ('-File\s+(?:"'+$expected+'"|'+$expected+')\s*$')
    })
    $valid=@()
    foreach($candidate in $candidates){
        $p=$null
        try{
            $sid=Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid -ErrorAction Stop
            if($sid.ReturnValue -ne 0 -or $sid.Sid -cne $owner){continue}
            $p=Get-Process -Id $candidate.ProcessId -ErrorAction Stop
            if($p.HasExited -or [Math]::Abs(($p.StartTime.ToUniversalTime()-$candidate.CreationDate.ToUniversalTime()).TotalSeconds) -gt 1){$p.Dispose();continue}
            $valid+=,$p
        }catch{if($null -ne $p){$p.Dispose()}}
    }
    if($valid.Count -eq 1){return $valid[0]}
    foreach($p in $valid){$p.Dispose()}
    return $null
}

function Complete-AppUi {
    param([bool]$Intentional)
    if($Intentional){Set-Content (Join-Path $script:DataDir 'stop.flag') 'stop'}
}
