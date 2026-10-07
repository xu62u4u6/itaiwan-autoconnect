Set-StrictMode -Version Latest

function Get-NextAction {
    param([object[]]$Adapters, [bool]$Online, [double]$SinceConnect, [double]$SincePortal)
    if ($Online) { return 'Online' }
    if (@($Adapters | Where-Object { $_.State -eq 1 -and $_.Ssid -ceq 'iTaiwan' }).Count) {
        if ($SincePortal -ge 60) { return 'Portal' }
        return 'WaitPortal'
    }
    # Preserve an existing connection to another network, even if its probe fails.
    if (@($Adapters | Where-Object { $_.State -eq 1 }).Count) { return 'OtherWifi' }
    if (@($Adapters | Where-Object { $_.State -in 2, 5, 6, 7 }).Count) { return 'Busy' }
    if (@($Adapters | Where-Object { $_.State -eq 4 }).Count -and $SinceConnect -ge 60) { return 'Connect' }
    return 'WaitWifi'
}

function Test-Internet {
    param($Client)
    $response = $null
    try {
        $response = $Client.GetAsync('http://www.msftconnecttest.com/connecttest.txt').GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        # Do not count a redirect or portal page with HTTP 200 as online.
        return ([int]$response.StatusCode -eq 200 -and $body.Trim() -ceq 'Microsoft Connect Test')
    } catch { return $false }
    finally { if ($null -ne $response) { $response.Dispose() } }
}

function Test-WindowsInternet {
    # Read the local Windows connectivity state without making an HTTP request.
    # Errors remain visible to the caller rather than being mistaken for offline.
    $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    return @($profiles | Where-Object {
        [string]$_.IPv4Connectivity -eq 'Internet' -or [string]$_.IPv6Connectivity -eq 'Internet'
    }).Count -gt 0
}

function Get-ConnectionInternet {
    param([object[]]$Adapters,[bool]$WindowsOnline,$Client,[hashtable]$ProbeState,[DateTime]$Now=[DateTime]::UtcNow,[switch]$Force)
    $isITaiwan=@($Adapters | Where-Object { $_.State -eq 1 -and $_.Ssid -ceq 'iTaiwan' }).Count -gt 0
    if (-not $isITaiwan) {
        $ProbeState.WasITaiwan=$false
        return $WindowsOnline
    }
    # Captive Wi-Fi can coexist with an Internet-marked VPN profile or stale NCSI state.
    # Only iTaiwan uses an HTTP check, once a minute; other networks remain passive.
    if (-not $ProbeState.WasITaiwan -or $Force -or $Now -ge $ProbeState.NextCheck) {
        $ProbeState.Online=Test-Internet $Client
        $ProbeState.NextCheck=$Now.AddSeconds(60)
    }
    $ProbeState.WasITaiwan=$true
    return [bool]$ProbeState.Online
}

function Get-PortalEvidence {
    param($Client,[switch]$Details)
    $response=$null;$state='UnrecognizedPortal';$location=$null
    try {
        $response=$Client.GetAsync('http://www.msftconnecttest.com/connecttest.txt').GetAwaiter().GetResult()
        $code=[int]$response.StatusCode
        if($code -eq 200){
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if($body.Trim() -ceq 'Microsoft Connect Test'){$state='Online'}
        }
        if($code -in 301,302,303,307,308 -and $null -ne $response.Headers.Location){
            $location=[uri]::new([uri]'http://www.msftconnecttest.com/connecttest.txt',$response.Headers.Location.OriginalString)
            if(Test-OfficialConsentUri $location){$state='OfficialPortal'}
        }
    }catch{$state='Unavailable'}finally{if($null -ne $response){$response.Dispose()}}
    if($Details){return [pscustomobject]@{State=$state;Location=$location}}
    return $state
}

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
        Move-Item -LiteralPath $script:LogPath -Destination "$script:LogPath.old" -Force
    }
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}
