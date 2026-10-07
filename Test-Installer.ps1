$ErrorActionPreference='Stop'
$dest=Join-Path $env:TEMP 'ITaiwanInstallerTest'
if(Test-Path $dest){throw 'Installer test directory already exists; inspect it before running this test.'}
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'iTaiwan AutoConnect-Test.lnk'
$startMenu=Join-Path ([Environment]::GetFolderPath('Programs')) 'iTaiwan 連線助手-Test.lnk'
$registry='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ITaiwanAutoConnect-Test'
$count=0
function Check($Actual,$Expected,[string]$Name){if($Actual -cne $Expected){throw "$Name expected $Expected, got $Actual"};$script:count++;Write-Host "PASS $Name"}
function Invoke-Installer([string]$Action,[string]$Fault="",[int]$ExpectedExit=0){
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output=Join-Path $env:TEMP ('ITaiwanSetup-'+[guid]::NewGuid().ToString('N')+'.log')
    $p=Start-Process $exe -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Manage.ps1')+'" -Action '+$Action+' -IntegrationTest -Quiet'+$(if($Fault){' -InjectFailure '+$Fault}else{''})) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $output
    try{if($p.ExitCode -ne $ExpectedExit){throw "Installer failed: $Action"};if($Fault -and (Get-Content $output -Raw) -notmatch "Injected"){throw "Expected injected failure was not exercised."}}finally{$p.Dispose();Remove-Item $output -Force}
}
try {
    Invoke-Installer Install 'BeforeCopy' 1
    Check (Test-Path $dest) $false 'Staging failure leaves no partial fresh installation'
    Invoke-Installer Install 'AfterIntegration' 1
    Check (Test-Path $startup) $false 'Fresh failure rolls back startup shortcut'
    Check (Test-Path $startMenu) $false 'Fresh failure rolls back start menu shortcut'
    Check (Test-Path $registry) $false 'Fresh failure rolls back app registration'
    Check (Test-Path $dest) $false 'Fresh failure removes partial program files'
    Invoke-Installer Install
    Check (Test-Path (Join-Path $dest 'ITaiwan.exe')) $true 'Installed launcher'
    Check (Test-Path $startup) $true 'Initial install creates sign-in shortcut'
    Check (Test-Path $startMenu) $true 'Start menu entry created'
    Check (Get-ItemProperty $registry).DisplayVersion '4.4' 'Registered in Windows installed apps'
    foreach($name in @('AppCore.ps1','ITaiwan.ps1','Tray.ps1','Manage.ps1','ITaiwan.exe')) {
        Check (Get-FileHash (Join-Path $dest $name)).Hash (Get-FileHash (Join-Path $PSScriptRoot $name)).Hash ("Installed file hash: $name")
    }
    [IO.File]::WriteAllText((Join-Path $dest 'settings.json'),'{"test":"preserve"}')
    Remove-Item $startup
    [IO.File]::WriteAllText((Join-Path $dest 'README.md'),'prior-version-marker')
    Set-ItemProperty $registry -Name DisplayVersion -Value 'prior-test-version'
    Invoke-Installer Install 'AfterIntegration' 1
    Check (Get-Content (Join-Path $dest 'README.md') -Raw) 'prior-version-marker' 'Failed update restores previous program file'
    Check (Get-ItemProperty $registry).DisplayVersion 'prior-test-version' 'Failed update restores previous app registration'
    Check (Test-Path $startup) $false 'Failed update preserves disabled startup'
    Check (Test-Path (Join-Path $dest 'stop.flag')) $false 'Failed update clears newly introduced stop signal'
    Check (Test-Path (Join-Path $dest 'tray-stop.flag')) $false 'Failed update clears newly introduced tray stop signal'
    Invoke-Installer Install
    Check (Get-Content (Join-Path $dest 'settings.json') -Raw) '{"test":"preserve"}' 'Update preserves user settings'
    Check (Test-Path $startup) $false 'Update preserves disabled auto-start'
    Invoke-Installer Uninstall
    Check (Test-Path $dest) $false 'Uninstall removes app and private settings'
    Check (Test-Path $startup) $false 'Uninstall removes startup entry'
    Check (Test-Path $startMenu) $false 'Uninstall removes start menu entry'
    Check (Test-Path $registry) $false 'Uninstall removes Windows app registration'
    Write-Host "$count installer checks passed. Production installation untouched."
} finally {
    if(Test-Path $dest){Invoke-Installer Uninstall}
}
