#requires -Version 5.1
param([ValidateSet('Install','Stop','Uninstall')][string]$Action='Install', [switch]$Quiet, [switch]$IntegrationTest, [switch]$KeepData,
    [ValidateSet('','BeforeCopy','AfterIntegration')][string]$InjectFailure='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
if($InjectFailure -and -not $IntegrationTest){throw 'Fault injection is restricted to the isolated installer test.'}
$dest=if($IntegrationTest){Join-Path $env:TEMP 'ITaiwanInstallerTest'}else{Join-Path $env:LOCALAPPDATA 'ITaiwanAutoConnect'}
$suffix=if($IntegrationTest){'-Test'}else{''}
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) "iTaiwan AutoConnect$suffix.lnk"
$startMenu=Join-Path ([Environment]::GetFolderPath('Programs')) "iTaiwan 連線助手$suffix.lnk"
$registry="HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ITaiwanAutoConnect$suffix"
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$files=@('Wifi.cs','Core.ps1','Auth.ps1','Portal.ps1','AppCore.ps1','ITaiwan.ps1','Tray.ps1','Manage.ps1','ITaiwan.exe','Run.cmd','Stop.cmd','Uninstall.cmd','Check.cmd','README.md')
$dirExisted=Test-Path $dest
$wasInstalled=(Test-Path $registry) -or (Test-Path (Join-Path $dest 'ITaiwan.exe'))
$enableStartup=(-not $wasInstalled) -or (Test-Path $startup)
$locks=@();$stage=$null;$backup=$null;$filesMutated=$false;$integrationMutated=$false;$stopRequested=$false
$exitCode=0;$rollbackOk=$true;$workerWasRunning=$false;$trayWasRunning=$false
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Test-BusyMutex([string]$Name){
    $m=[Threading.Mutex]::new($false,$Name);$owned=$false
    try{try{$owned=$m.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true};return -not $owned}
    finally{if($owned){$m.ReleaseMutex()};$m.Dispose()}
}
$shortcutBackup=@{}
foreach($path in @($startup,$startMenu)){if(Test-Path $path){$shortcutBackup[$path]=[IO.File]::ReadAllBytes($path)}}
$registryBackup=@{}
$registryExisted=Test-Path $registry
if($registryExisted){$key=Get-Item $registry;foreach($name in $key.GetValueNames()){$registryBackup[$name]=@{Value=$key.GetValue($name);Kind=$key.GetValueKind($name)}}}
$flagBackup=@{}
foreach($name in @('stop.flag','tray-stop.flag')){if(Test-Path (Join-Path $dest $name)){$flagBackup[$name]=[IO.File]::ReadAllBytes((Join-Path $dest $name))}}
try {
    if($Action -eq 'Install'){
        foreach($name in $files){if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))){throw "安裝檔不完整：$name。請先解壓縮整個 ZIP。"}}
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if($Action -eq 'Install'){
        # Stage and verify before interrupting the working version.
        $stage=Join-Path $dest ('.stage-'+[guid]::NewGuid().ToString('N'))
        $backup=Join-Path $dest ('.backup-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage,$backup -Force | Out-Null
        foreach($name in $files){
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage $name)
            if((Get-FileHash (Join-Path $PSScriptRoot $name)).Hash -ne (Get-FileHash (Join-Path $stage $name)).Hash){throw '安裝檔案驗證失敗。'}
            if(Test-Path (Join-Path $dest $name)){Copy-Item (Join-Path $dest $name) (Join-Path $backup $name)}
        }
        if($InjectFailure -eq 'BeforeCopy'){throw 'Injected staging failure.'}
    }
    $trayWasRunning=Test-BusyMutex "Local\ITaiwanTray-$sid$suffix"
    $workerWasRunning=Test-BusyMutex "Local\ITaiwanAutoConnect-$sid$suffix"
    $stopRequested=$true
    Set-Content (Join-Path $dest 'tray-stop.flag') 'stop'
    Set-Content (Join-Path $dest 'stop.flag') 'stop'
    foreach($base in @('ITaiwanLauncher','ITaiwanTray','ITaiwanAutoConnect')){
        $m=[Threading.Mutex]::new($false,"Local\$base-$sid$suffix");$acquired=$false
        try{$acquired=$m.WaitOne(60000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not $acquired){$m.Dispose();throw '程式仍在結束中，請稍後再試。'}
        $locks+=,$m
    }
    if($Action -eq 'Stop'){Write-Host 'Stopped the tray and worker. Sign-in auto-start is unchanged.'}
    elseif($Action -eq 'Uninstall'){
        Remove-Item $startup,$startMenu -Force -ErrorAction SilentlyContinue
        Remove-Item $registry -Recurse -Force -ErrorAction SilentlyContinue
        if($KeepData){foreach($name in $files){Remove-Item (Join-Path $dest $name) -Force -ErrorAction SilentlyContinue}}
        else{Remove-Item -LiteralPath $dest -Recurse -Force}
        if(-not $Quiet){[void][Windows.Forms.MessageBox]::Show('程式與自動啟動已移除。既有 Wi-Fi 設定檔保留，不會中斷目前網路。','iTaiwan 連線助手')}
        Write-Host 'Uninstalled.'
    } else {
        $filesMutated=$true
        foreach($name in $files){Copy-Item (Join-Path $stage $name) (Join-Path $dest $name) -Force}
        $integrationMutated=$true
        $shell=New-Object -ComObject WScript.Shell
        $shortcutPaths=@($startMenu);if($enableStartup){$shortcutPaths+=,$startup}
        foreach($path in $shortcutPaths){
            $link=$shell.CreateShortcut($path);$link.TargetPath=Join-Path $dest 'ITaiwan.exe';$link.WorkingDirectory=$dest
            $link.Description='iTaiwan 連線助手：Wi-Fi、Tailscale 與 Gmail 通知'
            $link.Arguments=if($path -eq $startup){'--background'}else{''};$link.Save()
        }
        New-Item $registry -Force | Out-Null
        $uninstall='"'+$powershell+'" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $dest 'Manage.ps1')+'" -Action Uninstall'
        if($IntegrationTest){$uninstall+=' -IntegrationTest -Quiet'}
        $values=@{DisplayName="iTaiwan 連線助手$suffix";DisplayVersion='4.4';Publisher='Local utility';InstallLocation=$dest;DisplayIcon=(Join-Path $dest 'ITaiwan.exe');UninstallString=$uninstall}
        foreach($key in $values.Keys){New-ItemProperty $registry -Name $key -Value $values[$key] -PropertyType String -Force | Out-Null}
        foreach($key in @('NoModify','NoRepair')){New-ItemProperty $registry -Name $key -Value 1 -PropertyType DWord -Force | Out-Null}
        if($InjectFailure -eq 'AfterIntegration'){throw 'Injected integration failure.'}
        Remove-Item (Join-Path $dest 'stop.flag'),(Join-Path $dest 'tray-stop.flag') -Force -ErrorAction SilentlyContinue
        if(-not $IntegrationTest){Set-Content (Join-Path $dest 'open-window.flag') 'open'}
        Write-Host "Installed v4.4: $dest"
    }
} catch {
    $exitCode=1;$failure=$_.Exception.Message
    if($Action -eq 'Install'){
        try{
            if($filesMutated){foreach($name in $files){
                if(Test-Path (Join-Path $backup $name)){Copy-Item (Join-Path $backup $name) (Join-Path $dest $name) -Force}
                else{Remove-Item (Join-Path $dest $name) -Force -ErrorAction SilentlyContinue}
            }}
            if($integrationMutated){
                foreach($path in @($startup,$startMenu)){
                    if($shortcutBackup.ContainsKey($path)){[IO.File]::WriteAllBytes($path,$shortcutBackup[$path])}
                    else{Remove-Item $path -Force -ErrorAction SilentlyContinue}
                }
                Remove-Item $registry -Recurse -Force -ErrorAction SilentlyContinue
                if($registryExisted){New-Item $registry -Force | Out-Null;foreach($name in $registryBackup.Keys){New-ItemProperty $registry -Name $name -Value $registryBackup[$name].Value -PropertyType $registryBackup[$name].Kind -Force | Out-Null}}
            }
            if($stopRequested){foreach($name in @('stop.flag','tray-stop.flag')){
                if($flagBackup.ContainsKey($name)){[IO.File]::WriteAllBytes((Join-Path $dest $name),$flagBackup[$name])}
                else{Remove-Item (Join-Path $dest $name) -Force -ErrorAction SilentlyContinue}
            }}
        }catch{$rollbackOk=$false;$failure+=' 回復未完成，備份保留於 '+$backup}
    }
    if(-not $Quiet){[void][Windows.Forms.MessageBox]::Show($failure,'iTaiwan 安裝／移除失敗','OK','Error')}
    Write-Host $failure
} finally {
    foreach($m in $locks){$m.ReleaseMutex();$m.Dispose()}
    if($rollbackOk){foreach($path in @($stage,$backup)){if($path -and (Test-Path $path)){Remove-Item $path -Recurse -Force}}}
}
if($Action -eq 'Install'){
    if($exitCode -eq 0 -and -not $IntegrationTest){(New-Object -ComObject Shell.Application).ShellExecute((Join-Path $dest 'ITaiwan.exe'),'',$dest,'open',0)}
    elseif($exitCode -ne 0 -and $rollbackOk){
        if(-not $IntegrationTest -and $stopRequested){
            if($trayWasRunning){Start-Process (Join-Path $dest 'ITaiwan.exe')}
            elseif($workerWasRunning){Start-Process $powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $dest 'ITaiwan.ps1')+'"') -WindowStyle Hidden}
        }
        if(-not $dirExisted -and (Test-Path $dest)){Remove-Item $dest -Recurse -Force}
    }
}
exit $exitCode
