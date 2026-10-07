# Portal context from the observed official page. Never persist client/AP identifiers.
function Read-PortalQuery {
    param([uri]$Uri)
    $values=@{}
    if(-not $Uri.Query){return $values}
    foreach($part in $Uri.Query.TrimStart('?').Split('&')){
        $pair=$part -split '=',2
        if($pair.Count -ne 2){throw 'Malformed portal context.'}
        $key=[uri]::UnescapeDataString($pair[0].Replace('+',' '))
        $value=[uri]::UnescapeDataString($pair[1].Replace('+',' '))
        if($key -notmatch '^[a-zA-Z_]+$' -or $values.ContainsKey($key) -or $value.Length -gt 4096){throw 'Ambiguous portal context.'}
        $values[$key]=$value
    }
    return $values
}
function Assert-PortalQueryKeys {
    param([hashtable]$Values,[string[]]$Keys)
    if($Values.Count -ne $Keys.Count){throw 'Unsupported portal context fields.'}
    foreach($key in $Keys){if(-not $Values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Values[$key])){throw 'Required portal context missing.'}}
}
function Convert-PortalMac {
    param([string]$Value)
    if($Value -notmatch '^(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'){throw 'Invalid portal client identity.'}
    return ($Value -replace '[:-]','').ToUpperInvariant()
}
function Get-VghtpeLoginContext {
    param([uri]$Uri)
    if($Uri.Scheme -cne 'https' -or $Uri.Host -ine 'itaiwan.vghtpe.gov.tw' -or $Uri.Port -ne 443 -or
        $Uri.UserInfo -or $Uri.Fragment -or $Uri.AbsolutePath -cne '/eGovWeb/eGovLogin.aspx'){throw 'Unsupported institutional consent destination.'}
    $q=Read-PortalQuery $Uri
    Assert-PortalQueryKeys $q @('switch_url','ap_mac','client_mac','wlan','redirect')
    $switch=$null
    if(-not [uri]::TryCreate($q.switch_url,[UriKind]::Absolute,[ref]$switch)){throw 'Malformed institutional switch destination.'}
    if($switch.AbsoluteUri -cne 'https://wlauth.vghtpe.gov.tw/login.html'){throw 'Unsupported institutional switch destination.'}
    if($q.wlan -cne 'iTaiwan' -or $q.redirect -cnotin @('www.msftconnecttest.com/redirect','www.msftconnecttest.com/connecttest.txt')){throw 'Unsupported institutional network context.'}
    [void](Convert-PortalMac $q.ap_mac)
    return [pscustomobject]@{Target=$Uri;ClientMac=(Convert-PortalMac $q.client_mac)}
}
function Get-ConsentContext {
    param([uri]$Uri)
    if($Uri.Scheme -cne 'https' -or $Uri.Host -ine 'auth.itaiwan.gov.tw' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or
        $Uri.Fragment -or $Uri.AbsolutePath -cnotin @('/noauth_page.php','/en/noauth_page.php')){throw 'Unsupported consent page URL.'}
    if(-not $Uri.Query){return [pscustomobject]@{Target=[uri]'https://wlanac.hinet.net/loginpages/userlogin.shtml';ClientMac='';Kind='HiNet'}}
    $q=Read-PortalQuery $Uri
    Assert-PortalQueryKeys $q @('umac','loginurl','user_name','pass_name','VID','GID','HID')
    if($q.user_name -cne 'username' -or $q.pass_name -cne 'password'){throw 'Unsupported institutional field names.'}
    foreach($key in @('VID','GID','HID')){if($q[$key] -cnotmatch '^[A-Za-z0-9]{1,64}$'){throw 'Invalid institutional identifier.'}}
    $loginUri=$null
    if(-not [uri]::TryCreate($q.loginurl,[UriKind]::Absolute,[ref]$loginUri)){throw 'Malformed institutional login destination.'}
    $login=Get-VghtpeLoginContext $loginUri
    if((Convert-PortalMac $q.umac) -cne $login.ClientMac){throw 'Portal client identity mismatch.'}
    return [pscustomobject]@{Target=$login.Target;ClientMac=$login.ClientMac;Kind='Vghtpe'}
}
function Get-SafeNetworkError {
    param($ErrorRecord)
    $parts=@();$ex=$ErrorRecord.Exception
    while($null -ne $ex){
        $item=$ex.GetType().Name
        if($ex -is [Net.WebException]){$item+='('+[string]$ex.Status+')'}
        if($ex -is [Net.Sockets.SocketException]){$item+='('+[string]$ex.SocketErrorCode+')'}
        if($ex -is [ComponentModel.Win32Exception]){$item+='('+[string]$ex.NativeErrorCode+')'}
        $parts+=,$item;$ex=$ex.InnerException
    }
    return $parts -join ' > '
}
function Get-ConsentLinkFromHtml {
    param([string]$Html,[uri]$BaseUri)
    $candidates=@()
    foreach($tag in [regex]::Matches($Html,'(?is)<meta\b([^>]*)>')){
        $a=Get-TagAttributes $tag.Groups[1].Value
        if($a['http-equiv'] -ieq 'refresh' -and $a['content'] -match '(?is)^\s*\d+\s*;\s*url\s*=\s*(.+)$'){$candidates+=,$Matches[1].Trim().Trim('"',"'")}
    }
    $pattern=@'
(?is)(?:(?:window\.)?location(?:\.href)?\s*=\s*|(?:window\.)?location\.(?:replace|assign)\s*\(\s*)["']([^"']+)["']
'@
    foreach($m in [regex]::Matches($Html,$pattern)){$candidates+=,$m.Groups[1].Value}
    $valid=@()
    foreach($candidate in $candidates){
        $uri=$null
        try{$uri=[uri]::new($BaseUri,[Net.WebUtility]::HtmlDecode($candidate))}catch{continue}
        if($uri.Host -ine 'auth.itaiwan.gov.tw'){continue}
        # An observed official link with invalid context must not become HiNet fallback.
        [void](Get-ConsentContext $uri)
        $valid+=,$uri
    }
    $unique=@($valid|Sort-Object AbsoluteUri -Unique)
    if($unique.Count -gt 1){throw 'Ambiguous consent links.'}
    if($unique.Count -eq 1){return $unique[0]}
    return $null
}
function Find-ITaiwanConsentUri {
    param($Client,[scriptblock]$ConfirmNetwork,[uri]$ObservedUri)
    if($null -ne $ObservedUri -and $ObservedUri.Host -ieq 'auth.itaiwan.gov.tw'){
        [void](Get-ConsentContext $ObservedUri);return $ObservedUri
    }
    # Windows opens /redirect when showing its captive portal window. That endpoint
    # carries the fresh institutional URL, whereas /connecttest.txt can return HTML.
    $uri=[uri]'http://www.msftconnecttest.com/redirect'
    for($i=0;$i -lt 4;$i++){
        if(-not (& $ConfirmNetwork)){throw 'Network changed during portal discovery.'}
        $response=$null
        try{
            try{$response=$Client.GetAsync($uri).GetAwaiter().GetResult()}catch{return $null}
            if([int]$response.StatusCode -in 301,302,303,307,308 -and $response.Headers.Location){
                $next=[uri]::new($uri,$response.Headers.Location.OriginalString)
                if($next.Host -ieq 'auth.itaiwan.gov.tw'){[void](Get-ConsentContext $next);return $next}
                # Only this observed hospital gateway can be read as an intermediate.
                # Unknown redirects (including normal Microsoft forwarding) are ignored.
                if($next.Scheme -cin @('http','https') -and $next.Host -ieq 'wlauth.vghtpe.gov.tw' -and
                    $next.AbsolutePath -ceq '/login.html' -and -not $next.UserInfo -and -not $next.Fragment -and $next.IsDefaultPort){$uri=$next;continue}
                return $null
            }
            if([int]$response.StatusCode -eq 200){return Get-ConsentLinkFromHtml ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult()) $uri}
            return $null
        }finally{if($response){$response.Dispose()}}
    }
    return $null
}

function Test-PortalNetwork {
    param([object[]]$Adapters,[uri]$ConsentUri)
    $connected=@($Adapters|Where-Object{$_.State -eq 1 -and $_.Ssid -ceq 'iTaiwan'})
    if(-not $connected.Count){return $false}
    if($null -eq $ConsentUri){return $true}
    $context=Get-ConsentContext $ConsentUri
    if(-not $context.ClientMac){return $true}
    return @($connected|Where-Object{$_.ClientMac -ceq $context.ClientMac}).Count -gt 0
}

function Get-InstitutionalContinuation {
    param([string]$Html,[uri]$SourceUri)
    $expected=[uri]'https://wlauth.vghtpe.gov.tw/login.html'
    $forms=@()
    foreach($m in [regex]::Matches($Html,'(?is)<form\b([^>]*)>(.*?)</form\s*>')){
        $a=Get-TagAttributes $m.Groups[1].Value
        if(-not $a['action']){continue}
        $target=[uri]::new($SourceUri,[string]$a['action'])
        if($target.AbsoluteUri -ceq $expected.AbsoluteUri){$forms+=,[pscustomobject]@{Attributes=$a;Body=$m.Groups[2].Value}}
    }
    if($forms.Count -eq 0){return $null}
    if($forms.Count -ne 1){throw 'Ambiguous institutional continuation.'}
    $form=$forms[0]
    if($form.Attributes['method'] -ine 'post' -or $form.Body -match '(?is)<(?:textarea|select|iframe)\b'){throw 'Unsupported institutional continuation controls.'}
    $fields=[Collections.Generic.Dictionary[string,string]]::new()
    foreach($tag in [regex]::Matches($form.Body,'(?is)<input\b([^>]*)>')){
        $a=Get-TagAttributes $tag.Groups[1].Value
        if($a['type'] -ine 'hidden' -or -not $a['name'] -or -not $a.ContainsKey('value') -or
            $fields.ContainsKey($a['name']) -or $fields.Count -ge 16 -or $a['value'].Length -gt 2048){throw 'Unsupported institutional continuation fields.'}
        $fields.Add($a['name'],$a['value'])
    }
    if(-not $fields.ContainsKey('username') -or -not $fields.ContainsKey('password') -or
        [string]::IsNullOrWhiteSpace($fields['username']) -or [string]::IsNullOrWhiteSpace($fields['password'])){throw 'Institutional continuation fields missing.'}
    return [pscustomobject]@{Uri=$expected;SourceUri=$SourceUri;Fields=$fields}
}
