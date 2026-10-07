. "$PSScriptRoot\Portal.ps1"
# The user explicitly authorized automatic iTaiwan consent on 2026-10-05.
# Only the observed official HTTPS form is supported; never execute page scripts.
function Get-TagAttributes {
    param([string]$Tag)
    $attributes = @{}
    $pattern = @'
([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))
'@
    foreach ($match in [regex]::Matches($Tag, $pattern)) {
        $name = $match.Groups[1].Value.ToLowerInvariant()
        if ($attributes.ContainsKey($name)) { throw 'Duplicate HTML attribute.' }
        $value = if ($match.Groups[2].Success) { $match.Groups[2].Value } elseif ($match.Groups[3].Success) { $match.Groups[3].Value } else { $match.Groups[4].Value }
        $attributes[$name] = [Net.WebUtility]::HtmlDecode($value)
    }
    return $attributes
}

function Test-OfficialConsentUri {
    param([uri]$Uri)
    try{[void](Get-ConsentContext $Uri);return $true}catch{return $false}
}

function Get-ConsentForm {
    param([string]$Html, [uri]$SourceUri)
    $context=Get-ConsentContext $SourceUri
    $forms = @()
    foreach ($match in [regex]::Matches($Html, '(?is)<form\b([^>]*)>(.*?)</form\s*>')) {
        $attrs = Get-TagAttributes $match.Groups[1].Value
        if ($attrs['id'] -ceq 'myform' -and $attrs['name'] -ceq 'login_form') {
            $forms += [pscustomobject]@{ Attributes=$attrs; Body=$match.Groups[2].Value }
        }
    }
    if ($forms.Count -ne 1) { throw 'Official login form missing or ambiguous.' }
    $form = $forms[0]
    if ($form.Attributes['method'] -ine 'post') { throw 'Unexpected consent method.' }
    $target = [uri]::new($SourceUri, [string]$form.Attributes['action'])
    if ($target.AbsoluteUri -cne $context.Target.AbsoluteUri) {
        throw 'Unrecognized consent destination; automatic submission refused.'
    }
    $buttons = @([regex]::Matches($form.Body, '(?is)<button\b([^>]*)>') | Where-Object {
        $a = Get-TagAttributes $_.Groups[1].Value
        $a['id'] -ceq 'login-button' -and $a['type'] -ieq 'submit'
    })
    if ($buttons.Count -ne 1 -or $form.Body -match '(?is)<(?:textarea|select|iframe)\b') { throw 'Unsupported consent controls.' }
    $fields = [Collections.Generic.Dictionary[string,string]]::new()
    foreach ($inputTag in [regex]::Matches($form.Body, '(?is)<input\b([^>]*)>')) {
        $attrs = Get-TagAttributes $inputTag.Groups[1].Value
        if ($attrs['type'] -ine 'hidden' -or -not $attrs['name'] -or -not $attrs.ContainsKey('value')) {
            throw 'Consent form requires unsupported user input.'
        }
        if ($fields.ContainsKey($attrs['name']) -or $fields.Count -ge 16 -or $attrs['value'].Length -gt 2048) {
            throw 'Unexpected consent field structure.'
        }
        $fields.Add($attrs['name'], $attrs['value'])
    }
    if (-not $fields.ContainsKey('username') -or -not $fields.ContainsKey('password') -or
        [string]::IsNullOrWhiteSpace($fields['username']) -or [string]::IsNullOrWhiteSpace($fields['password'])) {
        throw 'Official hidden login fields missing.'
    }
    return [pscustomobject]@{ Uri=$target; SourceUri=$SourceUri; Fields=$fields }
}

function Get-OfficialConsentForm {
    param($Client,[uri]$SourceUri='https://auth.itaiwan.gov.tw/noauth_page.php')
    $initialContext=Get-ConsentContext $SourceUri
    $uri = $SourceUri
    for ($i = 0; $i -lt 3; $i++) {
        $response = $null
        try {
            try{$response = $Client.GetAsync($uri).GetAwaiter().GetResult()}catch{throw ('ConsentPage request failed: '+(Get-SafeNetworkError $_))}
            $code = [int]$response.StatusCode
            if ($code -in 301,302,303,307,308) {
                if ($null -eq $response.Headers.Location) { throw 'Consent redirect has no destination.' }
                $next = [uri]::new($uri, $response.Headers.Location.OriginalString)
                if (-not (Test-OfficialConsentUri $next)) { throw 'Unexpected consent redirect.' }
                $nextContext=Get-ConsentContext $next
                if($nextContext.Target.AbsoluteUri -cne $initialContext.Target.AbsoluteUri -or $nextContext.ClientMac -cne $initialContext.ClientMac){throw 'Consent context changed during redirect.'}
                $uri = $next
                continue
            }
            if ($code -ne 200) { throw "Consent page returned HTTP $code." }
            $html = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return Get-ConsentForm -Html $html -SourceUri $uri
        } finally { if ($null -ne $response) { $response.Dispose() } }
    }
    throw 'Too many consent redirects.'
}

function Submit-ITaiwanConsent {
    param($Client, [scriptblock]$ConfirmNetwork,[uri]$ConsentUri='https://auth.itaiwan.gov.tw/noauth_page.php')
    if (-not (& $ConfirmNetwork $ConsentUri)) { throw 'iTaiwan connection changed before consent page request.' }
    $form = Get-OfficialConsentForm -Client $Client -SourceUri $ConsentUri
    if (-not (& $ConfirmNetwork $ConsentUri)) { throw 'iTaiwan connection changed before consent submission.' }
    $context=Get-ConsentContext $ConsentUri
    for($hop=0;$hop -lt 3;$hop++){
        if (-not (& $ConfirmNetwork $ConsentUri)) { throw 'iTaiwan connection changed before consent submission.' }
        $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$form.Uri)
        $response=$null
        try{
            $request.Content=[Net.Http.FormUrlEncodedContent]::new($form.Fields)
            $request.Headers.Referrer=$form.SourceUri
            [void]$request.Headers.TryAddWithoutValidation('Origin',$form.SourceUri.GetLeftPart([UriPartial]::Authority))
            $stage=if($hop -eq 0){'ConsentPost'}else{'SwitchPost'}
            try{$response=$Client.SendAsync($request).GetAwaiter().GetResult()}catch{throw ($stage+' request failed: '+(Get-SafeNetworkError $_))}
            $code=[int]$response.StatusCode
            if($code -lt 200 -or $code -ge 400){throw ($stage+' returned HTTP '+$code)}
            if($context.Kind -eq 'Vghtpe' -and $code -eq 200 -and $null -ne $response.Content){
                $html=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $next=Get-InstitutionalContinuation -Html $html -SourceUri $form.Uri
                if($null -ne $next){$form=$next;continue}
            }
            # The caller must still probe internet access after this bounded submission.
            return $true
        }finally{if($response){$response.Dispose()};$request.Dispose()}
    }
    throw 'Too many institutional submission steps.'

}

function New-ConsentClient {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $handler.UseCookies = $true
    $handler.CookieContainer = [Net.CookieContainer]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(8)
    $client.MaxResponseContentBufferSize = 256KB
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('ITaiwanAutoConnect/2.0')
    return $client
}

function Invoke-ITaiwanPortalRecovery {
    param($ProbeClient,$ConsentClient,[scriptblock]$ConfirmNetwork)
    if (-not (& $ConfirmNetwork)) { return 'NetworkChanged' }
    $evidence=Get-PortalEvidence -Client $ProbeClient -Details
    if ($evidence.State -eq 'Online') { return 'AlreadyOnline' }
    # The redirect is diagnostic only: gateways can return HTML or intermediate URLs.
    # Fetch the fixed official HTTPS page, validate every form boundary, then confirm
    # the exact Wi-Fi again before posting. Never follow the gateway's unknown URL.
    $consentUri=Find-ITaiwanConsentUri -Client $ConsentClient -ConfirmNetwork $ConfirmNetwork -ObservedUri $evidence.Location
    if($null -eq $consentUri){$consentUri=[uri]'https://auth.itaiwan.gov.tw/noauth_page.php'}
    [void](Submit-ITaiwanConsent -Client $ConsentClient -ConfirmNetwork $ConfirmNetwork -ConsentUri $consentUri)
    return 'Submitted'
}
