$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Auth.ps1"
Add-Type -AssemblyName System.Net.Http
$count=0
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected [$Expected], got [$Actual]"};$script:count++;Write-Host "PASS $Name"}
function Reject([scriptblock]$Action,[string]$Name){$thrown=$false;try{& $Action|Out-Null}catch{$thrown=$true};Check $thrown $true $Name}
function New-TestPortal([string]$Ap='AA:BB:CC:DD:EE:01',[string]$Client='02:11:22:33:44:55'){
    $login='https://itaiwan.vghtpe.gov.tw/eGovWeb/eGovLogin.aspx?switch_url='+[uri]::EscapeDataString('https://wlauth.vghtpe.gov.tw/login.html')+'&ap_mac='+[uri]::EscapeDataString($Ap)+'&client_mac='+[uri]::EscapeDataString($Client)+'&wlan=iTaiwan&redirect='+[uri]::EscapeDataString('www.msftconnecttest.com/redirect')
    return [uri]('https://auth.itaiwan.gov.tw/noauth_page.php?umac='+[uri]::EscapeDataString($Client.Replace(':','-'))+'&loginurl='+[uri]::EscapeDataString($login)+'&user_name=username&pass_name=password&VID=TESTVID001&GID=TESTGID001&HID=ITWTEST0001')
}
$portal=New-TestPortal
$context=Get-ConsentContext $portal
Check $context.Kind 'Vghtpe' 'Recognize hospital consent context'
Check $context.ClientMac '021122334455' 'Normalize client identity'
Check $context.Target.Host 'itaiwan.vghtpe.gov.tw' 'Validated hospital target'
Check (Test-OfficialConsentUri $portal) $true 'Allow observed official context URL'
$formHtml='<form id="myform" name="login_form" method="post" action="'+[Net.WebUtility]::HtmlEncode($context.Target.AbsoluteUri)+'"><input type="hidden" name="username" value="public-account"><input type="hidden" name="password" value="public-consent"><button id="login-button" type="submit">Consent</button></form>'
$form=Get-ConsentForm $formHtml $portal
Check $form.Uri.AbsoluteUri $context.Target.AbsoluteUri 'Preserve exact AP and client context in POST destination'
$portal2=New-TestPortal 'AA:BB:CC:DD:EE:02'
$ctx2=Get-ConsentContext $portal2
Check ($ctx2.Target.AbsoluteUri -ne $context.Target.AbsoluteUri) $true 'New AP creates a fresh destination'
Reject {Get-ConsentForm $formHtml $portal2} 'Old AP form cannot be reused for new AP context'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('auth.itaiwan.gov.tw','auth.itaiwan.gov.tw.evil.example'))} 'Reject spoofed consent host'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('itaiwan.vghtpe.gov.tw','evil.example'))} 'Reject unapproved loginurl host'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('wlauth.vghtpe.gov.tw','evil.example'))} 'Reject unapproved nested switch URL'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('umac=02-11-22-33-44-55','umac=02-11-22-33-44-66'))} 'Reject conflicting outer client identity'
Reject {Get-ConsentContext ($portal.AbsoluteUri+'&loginurl=x')} 'Reject duplicate context keys'
Reject {Get-ConsentContext ($portal.AbsoluteUri+'&unexpected=x')} 'Reject unsupported context keys'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('user_name=username','user_name=other'))} 'Reject unexpected user field mapping'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('redirect%3Dwww.msftconnecttest.com%252Fredirect','redirect%3Devil.example'))} 'Reject unapproved final redirect'
Reject {Get-ConsentContext ($portal.AbsoluteUri.Replace('https%3A%2F%2Fitaiwan','http%3A%2F%2Fitaiwan'))} 'Require HTTPS POST destination'
Reject {Get-ConsentForm ($formHtml.Replace('public-account','').Replace('public-consent','')) $portal} 'Require official hidden fields'
Check (Test-PortalNetwork @([pscustomobject]@{State=1;Ssid='iTaiwan';ClientMac='021122334455'}) $portal) $true 'Current adapter matches portal client identity'
Check (Test-PortalNetwork @([pscustomobject]@{State=1;Ssid='iTaiwan';ClientMac='021122334466'}) $portal) $false 'Another client context cannot be submitted'
Check (Test-PortalNetwork @([pscustomobject]@{State=1;Ssid='Other';ClientMac='021122334455'}) $portal) $false 'Other network cannot use portal context'
$literal='<script>window.location.href="'+[Net.WebUtility]::HtmlEncode($portal.AbsoluteUri)+'";</script>'
Check (Get-ConsentLinkFromHtml $literal ([uri]'http://www.msftconnecttest.com/redirect')).AbsoluteUri $portal.AbsoluteUri 'Extract literal gateway redirect without executing JS'
$meta='<meta http-equiv="refresh" content="0; url='+[Net.WebUtility]::HtmlEncode($portal.AbsoluteUri)+'">'
Check (Get-ConsentLinkFromHtml $meta ([uri]'http://www.msftconnecttest.com/redirect')).AbsoluteUri $portal.AbsoluteUri 'Extract gateway meta refresh without browser'
Check ($null -eq (Get-ConsentLinkFromHtml '<script>location="https://evil.example/";</script>' ([uri]'http://www.msftconnecttest.com/redirect'))) $true 'Ignore untrusted HTML redirect'
Reject {Get-ConsentLinkFromHtml ($literal+'<script>location="'+[Net.WebUtility]::HtmlEncode($portal2.AbsoluteUri)+'";</script>') ([uri]'http://www.msftconnecttest.com/redirect')} 'Reject ambiguous official context links'

$switchHtml='<form method="post" action="https://wlauth.vghtpe.gov.tw/login.html"><input type="hidden" name="username" value="public-account"><input type="hidden" name="password" value="public-consent"><input type="hidden" name="buttonClicked" value="4"></form>'
Check (Get-InstitutionalContinuation $switchHtml $context.Target).Uri.AbsoluteUri 'https://wlauth.vghtpe.gov.tw/login.html' 'Parse only the known hospital switch continuation'
Reject {Get-InstitutionalContinuation ($switchHtml+$switchHtml) $context.Target} 'Reject ambiguous switch forms'
Reject {Get-InstitutionalContinuation ($switchHtml.Replace('type="hidden"','type="text"')) $context.Target} 'Do not automate switch forms requiring user input'
Check ($null -eq (Get-InstitutionalContinuation ($switchHtml.Replace('wlauth.vghtpe.gov.tw','evil.example')) $context.Target)) $true 'Unknown continuation destination is ignored'

Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System; using System.Net; using System.Net.Http; using System.Threading; using System.Threading.Tasks;
public class InstitutionalHandler : HttpMessageHandler {
    public string Portal, Html, DiscoveryHtml, LastPost, LastReferrer, LastOrigin, SwitchHtml;
    public bool LoopSwitch;
    public int Posts, Requests; public bool FailPage, RedirectPage, UnknownRedirect;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) {
        Requests++;
        if(r.Method == HttpMethod.Post){
            Posts++;LastPost=r.RequestUri.AbsoluteUri;LastReferrer=r.Headers.Referrer.AbsoluteUri;LastOrigin=String.Join(",",r.Headers.GetValues("Origin"));
            if(SwitchHtml != null && (r.RequestUri.Host == "itaiwan.vghtpe.gov.tw" || LoopSwitch))return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(SwitchHtml)});
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Redirect));
        }
        if(r.RequestUri.Host == "www.msftconnecttest.com") {
            if(DiscoveryHtml != null)return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(DiscoveryHtml)});
            var hop=new HttpResponseMessage(HttpStatusCode.Redirect);hop.Headers.Location=new Uri(UnknownRedirect ? "https://evil.example/" : Portal);return Task.FromResult(hop);
        }
        if(FailPage)throw new HttpRequestException("Never log query: "+Portal, new WebException("private details",WebExceptionStatus.SecureChannelFailure));
        if(RedirectPage){var hop=new HttpResponseMessage(HttpStatusCode.Redirect);hop.Headers.Location=new Uri("https://auth.itaiwan.gov.tw/noauth_page.php");return Task.FromResult(hop);}
        if(r.RequestUri.Host != "auth.itaiwan.gov.tw")throw new Exception("Unexpected GET host");
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(Html)});
    }
}
'@
$h=[InstitutionalHandler]::new();$h.Portal=$portal.AbsoluteUri;$h.Html=$formHtml
$c=[Net.Http.HttpClient]::new($h)
try{
    $found=Find-ITaiwanConsentUri $c {$true}
    Check $found.AbsoluteUri $portal.AbsoluteUri 'Discover fresh full URL from Windows portal endpoint' 
    Check (Invoke-ITaiwanPortalRecovery $c $c {$true}) 'Submitted' 'Complete hospital GET to POST flow'
    Check $h.LastPost $context.Target.AbsoluteUri 'POST goes to hospital with original query intact'
    Check $h.LastReferrer $portal.AbsoluteUri 'POST supplies the actual consent page Referer'
    Check $h.Posts 1 'Exactly one institutional POST'
    $h.Portal=$portal2.AbsoluteUri;$h.Html=$formHtml.Replace([Net.WebUtility]::HtmlEncode($context.Target.AbsoluteUri),[Net.WebUtility]::HtmlEncode($ctx2.Target.AbsoluteUri))
    Check (Invoke-ITaiwanPortalRecovery $c $c {$true}) 'Submitted' 'Roaming uses newly observed AP context'
    Check $h.LastPost $ctx2.Target.AbsoluteUri 'No old AP context is replayed'
    $h.SwitchHtml=$switchHtml;$before=$h.Posts
    Check (Invoke-ITaiwanPortalRecovery $c $c {$true}) 'Submitted' 'Complete hidden switch continuation without JS execution'
    Check ($h.Posts-$before) 2 'Institutional flow submits both validated forms'
    Check $h.LastPost 'https://wlauth.vghtpe.gov.tw/login.html' 'Continuation POST stays at approved switch'
    Check $h.LastReferrer $ctx2.Target.AbsoluteUri 'Switch receives institutional Referrer'
    Check $h.LastOrigin 'https://itaiwan.vghtpe.gov.tw' 'Switch receives institutional Origin'
    $before=$h.Posts
    Reject {Invoke-ITaiwanPortalRecovery $c $c {$h.Posts -eq $before}} 'Network change before switch continuation blocks next POST'
    Check ($h.Posts-$before) 1 'No switch POST after network change'
    $h.LoopSwitch=$true;$before=$h.Posts
    Reject {Invoke-ITaiwanPortalRecovery $c $c {$true}} 'Bound institutional continuation loops'
    Check ($h.Posts-$before) 3 'At most three POST steps'
    $h.LoopSwitch=$false;$h.SwitchHtml=$null
    $h.RedirectPage=$true
    Reject {Get-OfficialConsentForm $c $portal2} 'Official redirect cannot drop institutional context'
    $h.RedirectPage=$false;$h.FailPage=$true
    $message='';try{Get-OfficialConsentForm $c $portal2|Out-Null}catch{$message=$_.Exception.Message}
    Check ($message -match 'ConsentPage.*SecureChannelFailure') $true 'Failure identifies GET and underlying transport status'
    Check ($message -match 'loginurl|umac|021122|auth.itaiwan.gov.tw') $false 'Failure log does not expose client context'
    $h.FailPage=$false;$h.UnknownRedirect=$true;$before=$h.Requests
    Check ($null -eq (Find-ITaiwanConsentUri $c {$true})) $true 'Unknown discovery redirect is ignored'
    Check ($h.Requests-$before) 1 'Unknown discovery URL is never requested'
    $h.UnknownRedirect=$false;$h.Portal=$portal.AbsoluteUri+'&unexpected=x';$before=$h.Posts
    Reject {Invoke-ITaiwanPortalRecovery $c $c {$true}} 'Invalid official context never falls back to HiNet'
    Check $h.Posts $before 'Unknown official query causes zero POST'
    $h.Portal=$portal.AbsoluteUri.Replace('umac=02-11-22-33-44-55','umac=02-11-22-33-44-66')
    Reject {Invoke-ITaiwanPortalRecovery $c $c {$true}} 'Conflicting official client never falls back'
    Check $h.Posts $before 'Conflicting client causes zero POST'
    $h.Portal=$portal.AbsoluteUri;$h.DiscoveryHtml=$literal+'<script>location="'+[Net.WebUtility]::HtmlEncode($portal2.AbsoluteUri)+'";</script>'
    Reject {Invoke-ITaiwanPortalRecovery $c $c {$true}} 'Ambiguous gateway context never falls back'
    Check $h.Posts $before 'Ambiguous context causes zero POST'
    $h.UnknownRedirect=$false;$h.DiscoveryHtml=$literal
    Check (Find-ITaiwanConsentUri $c {$true}).AbsoluteUri $portal.AbsoluteUri 'HTML gateway discovery preserves context'
    $before=$h.Requests
    Reject {Find-ITaiwanConsentUri $c {$false}} 'Network change stops discovery'
    Check $h.Requests $before 'Changed network sends no discovery request'
}finally{$c.Dispose()}
Write-Host "$count portal checks passed. No real network requests or consent submitted."
