# Offline tests: no Wi-Fi connection, browser, network traffic or installation.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Auth.ps1"
Add-Type -AssemblyName System.Net.Http
Add-Type -Path "$PSScriptRoot\Wifi.cs"
$count = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ($Actual -cne $Expected) { throw "$Name expected [$Expected], got [$Actual]" }
    $script:count++
    Write-Host "PASS $Name"
}
$disconnected = [pscustomobject]@{State=4; Ssid=''}
$itaiwan = [pscustomobject]@{State=1; Ssid='iTaiwan'}
$other = [pscustomobject]@{State=1; Ssid='OtherNetwork'}
$busy = [pscustomobject]@{State=5; Ssid=''}
Assert-Equal (Get-NextAction @($disconnected) $false 999 999) 'Connect' 'Offline startup connects'
Assert-Equal (Get-NextAction @($disconnected) $false 59 999) 'WaitWifi' 'Connection retry cooldown'
Assert-Equal (Get-NextAction @($disconnected) $false 60 999) 'Connect' 'Connection retry boundary'
Assert-Equal (Get-NextAction @($itaiwan) $false 999 999) 'Portal' 'Connected but unauthenticated opens portal'
Assert-Equal (Get-NextAction @($itaiwan) $false 999 59) 'WaitPortal' 'Consent retry throttled'
Assert-Equal (Get-NextAction @($itaiwan) $false 999 60) 'Portal' 'Portal retry boundary'
Assert-Equal (Get-NextAction @($itaiwan) $true 999 999) 'Online' 'Authenticated connection preserved'
Assert-Equal (Get-NextAction @($other,$disconnected) $false 999 999) 'OtherWifi' 'Other Wi-Fi preserved after failed probe'
Assert-Equal (Get-NextAction @($disconnected) $true 999 999) 'Online' 'Wired or other internet preserved'
Assert-Equal (Get-NextAction @($busy,$disconnected) $false 999 999) 'Busy' 'Association in progress preserved'
Assert-Equal (Get-NextAction @() $false 999 999) 'WaitWifi' 'Missing adapter waits'
Assert-Equal (Get-NextAction @([pscustomobject]@{State=0;Ssid=''}) $false 999 999) 'WaitWifi' 'Disabled adapter waits'
Assert-Equal (Get-NextAction @([pscustomobject]@{State=1;Ssid='iTaiwan-Fake'}) $false 999 999) 'OtherWifi' 'Exact SSID required'

# Exercise the real HTTP probe against an in-memory handler, including captive portal 200s.
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class FakeHandler : HttpMessageHandler {
    public int Status = 200;
    public string Body = "Microsoft Connect Test";
    public bool Fail;
    public int Requests;
    public string Redirect;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) {
        Requests++;
        if (Fail) throw new HttpRequestException("offline");
        var response = new HttpResponseMessage((HttpStatusCode)Status) { Content = new StringContent(Body) };
        if (!String.IsNullOrEmpty(Redirect)) response.Headers.Location = new Uri(Redirect);
        return Task.FromResult(response);
    }
}
'@
$handler = New-Object FakeHandler
$client = New-Object Net.Http.HttpClient($handler)
try {
    Assert-Equal (Test-Internet $client) $true 'Expected probe content'
    Assert-Equal (Get-PortalEvidence $client) 'Online' 'Valid probe is not a portal'
    $handler.Status = 302; $handler.Redirect = 'https://login.foxconn.example/'
    Assert-Equal (Get-PortalEvidence $client) 'UnrecognizedPortal' 'Company redirect is not official portal evidence'
    $handler.Redirect = 'https://auth.itaiwan.gov.tw/noauth_page.php'
    Assert-Equal (Get-PortalEvidence $client) 'OfficialPortal' 'Official HTTPS redirect required'
    $handler.Redirect = 'http://auth.itaiwan.gov.tw/noauth_page.php'
    Assert-Equal (Get-PortalEvidence $client) 'UnrecognizedPortal' 'HTTP portal not trusted'
    $handler.Redirect = $null; $handler.Status = 200
    $handler.Body = '<html>Please sign in</html>'
    Assert-Equal (Test-Internet $client) $false 'Portal HTTP 200 is offline'
    Assert-Equal (Get-PortalEvidence $client) 'UnrecognizedPortal' 'Unknown HTML is not official portal evidence'
    $handler.Body = 'Microsoft Connect Test'; $handler.Status = 302
    Assert-Equal (Test-Internet $client) $false 'Redirect is offline'
    $handler.Status = 503
    Assert-Equal (Test-Internet $client) $false 'Server failure is offline'
    $handler.Fail = $true
    Assert-Equal (Test-Internet $client) $false 'Network exception remains retryable'
    Assert-Equal (Get-PortalEvidence $client) 'Unavailable' 'Network error is not official portal evidence'
} finally { $client.Dispose() }


function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-Equal $thrown $true $Name
}
$fixture = @'
<form id="myform" name="login_form" method="post" action="https://wlanac.hinet.net/loginpages/userlogin.shtml">
<input name="username" type="hidden" value="@itw">
<input name="password" type="hidden" value="myegov">
<input name="token" type="hidden" value="a&amp;b+c">
<button id="login-button" type="submit">Consent</button></form>
'@
$official = [uri]'https://auth.itaiwan.gov.tw/noauth_page.php'
$form = Get-ConsentForm $fixture $official
Assert-Equal $form.Fields['token'] 'a&b+c' 'Hidden values HTML decoded'
Assert-Equal $form.Fields.Count 3 'All hidden fields preserved'
Assert-Throws { Get-ConsentForm $fixture 'https://auth.itaiwan.gov.tw.evil.example/noauth_page.php' } 'Reject spoofed portal host'
Assert-Throws { Get-ConsentForm $fixture 'http://auth.itaiwan.gov.tw/noauth_page.php' } 'Require official HTTPS'
Assert-Throws { Get-ConsentForm ($fixture.Replace('wlanac.hinet.net','evil.example')) $official } 'Reject unrecognized form destination'
Assert-Throws { Get-ConsentForm ($fixture.Replace('type="hidden"','type="text"')) $official } 'Reject user-input form'
Assert-Throws { Get-ConsentForm ($fixture.Replace('id="login-button"','id="unknown"')) $official } 'Reject changed consent button'
Assert-Throws { Get-ConsentForm ($fixture + $fixture) $official } 'Reject ambiguous login forms'
Assert-Throws { Get-ConsentForm ($fixture.Replace('name="token"','name="username"')) $official } 'Reject duplicate fields'

Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class ConsentHandler : HttpMessageHandler {
    public string Html;
    public int GetStatus = 200, PostStatus = 302, Posts, Gets;
    public string LastGet;
    public string Body, Referrer, Origin;
    public string Redirect = "https://evil.example/";
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) {
        if (req.Method == HttpMethod.Post) {
            Posts++;
            Body = req.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            Referrer = req.Headers.Referrer.ToString();
            Origin = String.Join(",", req.Headers.GetValues("Origin"));
            return Task.FromResult(new HttpResponseMessage((HttpStatusCode)PostStatus));
        }
        if (req.RequestUri.Host == "www.msftconnecttest.com") {
            var forward = new HttpResponseMessage(HttpStatusCode.Redirect);
            forward.Headers.Location = new Uri("http://go.microsoft.com/fwlink/");
            return Task.FromResult(forward);
        }
        Gets++; LastGet = req.RequestUri.AbsoluteUri;
        var response = new HttpResponseMessage((HttpStatusCode)GetStatus) { Content = new StringContent(Html) };
        if (GetStatus == 302) response.Headers.Location = new Uri(Redirect);
        return Task.FromResult(response);
    }
}
'@
$consentHandler = New-Object ConsentHandler
$consentHandler.Html = $fixture
$consentClient = [Net.Http.HttpClient]::new($consentHandler)
try {
    Assert-Equal (Submit-ITaiwanConsent $consentClient { $true }) $true 'Submit official form without desktop'
    Assert-Equal $consentHandler.Posts 1 'Exactly one consent POST'
    Assert-Equal ($consentHandler.Body -match 'token=a%26b%2Bc') $true 'Token correctly URL encoded'
    Assert-Equal $consentHandler.Referrer $official.AbsoluteUri 'Official Referer supplied'
    Assert-Equal $consentHandler.Origin 'https://auth.itaiwan.gov.tw' 'Official Origin supplied'
    Assert-Throws { Submit-ITaiwanConsent $consentClient { $false } } 'Network change prevents consent'
    Assert-Equal $consentHandler.Posts 1 'No submission after network change'
    $consentHandler.PostStatus = 500
    Assert-Throws { Submit-ITaiwanConsent $consentClient { $true } } 'Gateway failure is retryable'
    $consentHandler.GetStatus = 302
    Assert-Throws { Get-OfficialConsentForm $consentClient } 'Reject off-domain redirect before request'
    $consentHandler.Redirect = 'https://auth.itaiwan.gov.tw/noauth_page.php'
    Assert-Throws { Get-OfficialConsentForm $consentClient } 'Bound official redirect loop'
} finally { $consentClient.Dispose() }

# Real recovery path, including a gateway that returns HTML rather than a direct redirect.
$probeHandler=[FakeHandler]::new();$probeHandler.Body='<html>Gateway login required</html>'
$probeClient=[Net.Http.HttpClient]::new($probeHandler)
$loginHandler=[ConsentHandler]::new();$loginHandler.Html=$fixture
$loginClient=[Net.Http.HttpClient]::new($loginHandler)
try {
    Assert-Equal (Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$true}) 'Submitted' 'Gateway HTML still permits validated official consent'
    Assert-Equal $loginHandler.Posts 1 'Fallback submits exactly once'
    Assert-Equal $loginHandler.LastGet $official.AbsoluteUri 'Fallback fetches fixed official HTTPS URL'
    $probeHandler.Status=302;$probeHandler.Redirect='https://login.foxconn.example/'
    Assert-Equal (Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$true}) 'Submitted' 'Unknown redirect uses independently validated official page'
    Assert-Equal $loginHandler.LastGet $official.AbsoluteUri 'Unknown gateway URL is never followed'
    $loginHandler.Html=$fixture.Replace('wlanac.hinet.net','evil.example')
    Assert-Throws {Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$true}} 'Changed official form still prevents consent'
    Assert-Equal $loginHandler.Posts 2 'Invalid form sends no additional POST'
    $loginHandler.Html=$fixture;$loginHandler.GetStatus=302
    Assert-Throws {Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$true}} 'Off-domain official page redirect remains rejected'
    Assert-Equal $loginHandler.Posts 2 'Off-domain redirect sends no POST'
    $loginHandler.GetStatus=200;$probeHandler.Status=200;$probeHandler.Redirect=$null;$probeHandler.Body='Microsoft Connect Test'
    $gets=$loginHandler.Gets
    Assert-Equal (Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$true}) 'AlreadyOnline' 'Already authenticated connection skips consent'
    Assert-Equal $loginHandler.Gets $gets 'Online connection does not fetch consent page'
    $requests=$probeHandler.Requests
    Assert-Equal (Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$false}) 'NetworkChanged' 'Other Wi-Fi never enters recovery'
    Assert-Equal $probeHandler.Requests $requests 'Other Wi-Fi makes no portal request'
    $probeHandler.Body='<html>Gateway login required</html>'
    $script:networkChecks=0
    Assert-Throws {Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$script:networkChecks++;$script:networkChecks -lt 2}} 'Network change after probe prevents official page request'
    Assert-Equal $loginHandler.Gets $gets 'Network change prevents official GET'
    $script:networkChecks=0;$posts=$loginHandler.Posts
    Assert-Throws {Invoke-ITaiwanPortalRecovery $probeClient $loginClient {$loginHandler.Gets -le $gets}} 'Network change after official GET prevents POST'
    Assert-Equal $loginHandler.Gets ($gets+1) 'Official GET completed before network change'
    Assert-Equal $loginHandler.Posts $posts 'POST after network change is never sent'
    $cache=@{WasITaiwan=$false;NextCheck=[DateTime]::MinValue;Online=$false}
    $now=[DateTime]::UtcNow;$requests=$probeHandler.Requests
    Assert-Equal (Get-ConnectionInternet @($other) $true $probeClient $cache $now) $true 'Other Wi-Fi retains passive Windows state'
    Assert-Equal $probeHandler.Requests $requests 'Other Wi-Fi sends no internet probe'
    Assert-Equal (Get-ConnectionInternet @($itaiwan) $true $probeClient $cache $now) $false 'iTaiwan portal overrides stale Windows or VPN Internet flag'
    Assert-Equal ($probeHandler.Requests-$requests) 1 'First iTaiwan association probes immediately'
    $probeHandler.Body='Microsoft Connect Test'
    Assert-Equal (Get-ConnectionInternet @($itaiwan) $true $probeClient $cache $now.AddSeconds(59)) $false 'Internet probes are throttled for a minute'
    Assert-Equal (Get-ConnectionInternet @($itaiwan) $true $probeClient $cache $now.AddSeconds(60)) $true 'Next probe observes recovered internet'
    $probeHandler.Body='<html>Gateway login required</html>'
    Assert-Equal (Get-ConnectionInternet @($itaiwan) $true $probeClient $cache $now.AddSeconds(61) -Force) $false 'Manual retry bypasses internet probe cache'
    [void](Get-ConnectionInternet @($other) $true $probeClient $cache $now.AddSeconds(62))
    $probeHandler.Body='Microsoft Connect Test'
    Assert-Equal (Get-ConnectionInternet @($itaiwan) $false $probeClient $cache $now.AddSeconds(63)) $true 'Returning to iTaiwan always probes again'
} finally {$probeClient.Dispose();$loginClient.Dispose()}

# Mock the local Windows status query; no HTTP request is involved.
function Get-NetConnectionProfile {
    param($ErrorAction)
    if ($script:statusThrows) { throw 'Windows status query failed' }
    return $script:mockProfiles
}
$script:statusThrows = $false
$script:mockProfiles = @([pscustomobject]@{IPv4Connectivity='Internet';IPv6Connectivity='NoTraffic'})
Assert-Equal (Test-WindowsInternet) $true 'Passive Windows IPv4 internet state'
$script:mockProfiles = @([pscustomobject]@{IPv4Connectivity='LocalNetwork';IPv6Connectivity='Internet'})
Assert-Equal (Test-WindowsInternet) $true 'Passive Windows IPv6 internet state'
$script:mockProfiles = @()
Assert-Equal (Test-WindowsInternet) $false 'No network profiles is offline'
$script:statusThrows = $true
Assert-Throws { Test-WindowsInternet } 'Windows query errors do not authorize login'
Remove-Item Function:\Get-NetConnectionProfile

foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-Equal $errors.Count 0 ("Syntax: " + $file.Name)
}
Write-Host "$count checks passed. Native Wi-Fi wrapper compiled. No live connection was attempted."
