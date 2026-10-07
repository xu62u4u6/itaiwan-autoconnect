$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('ITaiwanLauncherTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$count=0;$parent=$null;$second=$null;$child=$null
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected [$Expected], got [$Actual]"};$script:count++;Write-Host "PASS $Name"}
function Until([scriptblock]$Test,[string]$Name){$limit=[DateTime]::UtcNow.AddSeconds(8);while([DateTime]::UtcNow -lt $limit){if(& $Test){return};Start-Sleep -Milliseconds 100};throw "Timeout: $Name"}
try{
    $exe=Join-Path $root 'ITaiwan.exe'
    Copy-Item (Join-Path $PSScriptRoot 'ITaiwan.exe') $exe
    foreach($n in @('Wifi.cs','Core.ps1','Auth.ps1','Portal.ps1','AppCore.ps1','ITaiwan.ps1','Tray.ps1','Manage.ps1','README.md')){Copy-Item (Join-Path $PSScriptRoot $n) (Join-Path $root $n)}
    Set-Content (Join-Path $root 'settings.json') 'sentinel-private-settings'
    Remove-Item (Join-Path $root 'ITaiwan.ps1')
    $parent=Start-Process $exe -ArgumentList ('--integration-test "'+$root+'"') -PassThru
    Until {Test-Path (Join-Path $root 'test-child.txt')} 'start harmless test child'
    Check (Test-Path (Join-Path $root 'ITaiwan.ps1')) $true 'Missing worker restored on native startup'
    Check (Get-FileHash (Join-Path $root 'ITaiwan.ps1')).Hash (Get-FileHash (Join-Path $PSScriptRoot 'ITaiwan.ps1')).Hash 'Restored worker matches packaged source'
    Check (Get-Content (Join-Path $root 'test-window-visible.txt') -Raw).Trim() 'True' 'First WinForms window is visible with detached launcher'
    Check (Get-Content (Join-Path $root 'settings.json') -Raw).Trim() 'sentinel-private-settings' 'Repair never touches private settings'
    Remove-Item (Join-Path $root 'Tray.ps1')
    Until {Test-Path (Join-Path $root 'Tray.ps1')} 'repair missing tray during supervision'
    Check (Get-FileHash (Join-Path $root 'Tray.ps1')).Hash (Get-FileHash (Join-Path $PSScriptRoot 'Tray.ps1')).Hash 'Deleted tray restored while native supervisor runs'
    $firstPid=[int](Get-Content (Join-Path $root 'test-child.txt') -Raw)
    Set-Content (Join-Path $root 'test-crash.flag') 'crash'
    Until {try{[int](Get-Content (Join-Path $root 'test-child.txt') -Raw) -ne $firstPid}catch{$false}} 'restart crashed child'
    $newPid=[int](Get-Content (Join-Path $root 'test-child.txt') -Raw)
    Check ($newPid -ne $firstPid) $true 'Native supervisor starts replacement after real child exits'
    $second=Start-Process $exe -ArgumentList ('--integration-test "'+$root+'"') -PassThru
    Check ($second.WaitForExit(5000)) $true 'Second launch exits rather than spawning duplicate supervisor'
    Check ([int](Get-Content (Join-Path $root 'test-child.txt') -Raw)) $newPid 'Second launch preserves existing child'
    $child=Get-Process -Id $newPid
    Set-Content (Join-Path $root 'stop.flag') 'stop'
    Check ($parent.WaitForExit(5000)) $true 'Manual stop terminates native supervisor'
    Check ($child.WaitForExit(5000)) $true 'Manual stop allows owned child to terminate'
    Remove-Item (Join-Path $root 'Tray.ps1')
    Start-Sleep -Milliseconds 400
    Check (Test-Path (Join-Path $root 'Tray.ps1')) $false 'Stopped supervisor never resurrects removed files'
    # A second isolated run removes the same file twice: recovery must stop, not loop.
    Copy-Item (Join-Path $PSScriptRoot 'Tray.ps1') (Join-Path $root 'Tray.ps1')
    Remove-Item (Join-Path $root 'test-child.txt')
    $parent.Dispose();$parent=Start-Process $exe -ArgumentList ('--integration-test "'+$root+'"') -PassThru
    Until {Test-Path (Join-Path $root 'test-child.txt')} 'restart isolated supervisor'
    Remove-Item (Join-Path $root 'Tray.ps1')
    Until {Test-Path (Join-Path $root 'Tray.ps1')} 'first bounded repair'
    Remove-Item (Join-Path $root 'Tray.ps1')
    Check ($parent.WaitForExit(5000)) $true 'Repeated file removal stops recovery without an endless repair loop'
    Check (Test-Path (Join-Path $root 'launcher-error.txt')) $true 'Repeated removal leaves an explicit diagnostic'
    Check (Test-Path (Join-Path $root 'Tray.ps1')) $false 'Repeatedly removed file is not restored again'
    Check (Get-Content (Join-Path $root 'settings.json') -Raw).Trim() 'sentinel-private-settings' 'Settings survive recovery failure'
    Write-Host "$count native launcher checks passed. No production process, Wi-Fi, or mail touched."
}finally{
    Set-Content (Join-Path $root 'stop.flag') 'stop'
    foreach($p in @($parent,$second,$child)){if($null -ne $p){if(-not $p.HasExited){[void]$p.WaitForExit(3000);if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(3000)}};$p.Dispose()}}
    $remaining=@(Get-CimInstance Win32_Process -Filter "Name='ITaiwan.exe'"|Where-Object{$_.ExecutablePath -eq (Join-Path $root 'ITaiwan.exe') -and $_.CommandLine -match '--test-child'})
    foreach($p in $remaining){
        $owned=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if($null -ne $owned){if(-not $owned.HasExited){$owned.Kill();[void]$owned.WaitForExit(5000)};$owned.Dispose()}
    }
    for($attempt=0;$attempt -lt 20;$attempt++){try{Remove-Item $root -Recurse -Force;break}catch{if($attempt -eq 19){throw};Start-Sleep -Milliseconds 150}}
}
