#requires -Version 5.1
param([switch]$SmokeTest, [string]$DataDirectory, [string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. "$PSScriptRoot\AppCore.ps1"
$script:DataDir = if ($DataDirectory) { $DataDirectory } else { Join-Path $env:LOCALAPPDATA 'ITaiwanAutoConnect' }
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$script:UiClosing=$false
$script:Worker=$null
$script:LastWorkerStart=[DateTime]::MinValue
$script:Restarts=[Collections.Generic.List[DateTime]]::new()
$script:Status=$null
$script:StartupPath=Join-Path ([Environment]::GetFolderPath('Startup')) 'iTaiwan AutoConnect.lnk'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex=[Threading.Mutex]::new($false,"Local\ITaiwanTray-$sid")
$acquired=$false
if (-not $SmokeTest) {
    try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if (-not $acquired) {
        Set-Content (Join-Path $script:DataDir 'open-window.flag') 'open'
        $mutex.Dispose(); exit 0
    }
    Remove-Item (Join-Path $script:DataDir 'tray-stop.flag') -Force -ErrorAction SilentlyContinue
}
function Show-AppError { param($ErrorRecord) [void][Windows.Forms.MessageBox]::Show([string]$ErrorRecord.Exception.Message,'iTaiwan 連線助手','OK','Warning') }
function Set-Autostart {
    param([bool]$Enabled)
    if ($Enabled) {
        $link=(New-Object -ComObject WScript.Shell).CreateShortcut($script:StartupPath)
        $link.TargetPath=Join-Path $PSScriptRoot 'ITaiwan.exe'; $link.WorkingDirectory=$PSScriptRoot
        $link.Description='iTaiwan 連線助手'; $link.Arguments='--background'; $link.Save()
    } else { Remove-Item $script:StartupPath -Force -ErrorAction SilentlyContinue }
}
function Start-AppWorker {
    if ($SmokeTest) { return }
    if (Test-Path (Join-Path $script:DataDir 'stop.flag')) { return }
    $now=[DateTime]::UtcNow
    if ($null -ne $script:Worker -and -not $script:Worker.HasExited) {
        $heartbeat=Read-AppJson (Join-Path $script:DataDir 'heartbeat.json') $null
        $now=[DateTime]::UtcNow # Sample after reading a concurrently updated heartbeat.
        if (Stop-StalledWorker -Worker $script:Worker -Heartbeat $heartbeat -Now $now) {
            $stage=if($null -ne $heartbeat -and $null -ne $heartbeat.PSObject.Properties['Stage']){$heartbeat.Stage}else{'Startup'}
            try {
                $watchLog=Join-Path $script:DataDir 'watchdog.log'
                if((Test-Path $watchLog) -and (Get-Item $watchLog).Length -gt 1MB){Move-Item $watchLog ($watchLog+'.old') -Force}
                Add-Content $watchLog ($now.ToString('o')+' Restarting stalled worker; last stage: '+$stage) -Encoding UTF8
            } catch { }
        }
        return
    }
    if (($now-$script:LastWorkerStart).TotalSeconds -lt 30) { return }
    for ($i=$script:Restarts.Count-1;$i -ge 0;$i--) { if (($now-$script:Restarts[$i]).TotalMinutes -ge 10) { $script:Restarts.RemoveAt($i) } }
    if ($script:Restarts.Count -ge 3) { return }
    $existing=Find-ExistingAppWorker -Root $PSScriptRoot
    if($null -ne $existing){
        if($null -ne $script:Worker){$script:Worker.Dispose()}
        $script:Worker=$existing; $script:LastWorkerStart=$now
        return
    }
    $script:Restarts.Add($now); $script:LastWorkerStart=$now
    if ($null -ne $script:Worker) { $script:Worker.Dispose() }
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Worker=Start-Process $exe -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'ITaiwan.ps1')+'"') -PassThru -WindowStyle Hidden
}
function Request-Retry {
    Set-AppPause 0
    Remove-Item (Join-Path $script:DataDir 'stop.flag') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $script:DataDir 'retry.flag') 'retry'
    $script:Restarts.Clear(); $script:LastWorkerStart=[DateTime]::MinValue
    Start-AppWorker
}
function New-Label {
    param($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width=580,[int]$Height=30)
    $label=[Windows.Forms.Label]::new(); $label.Text=$Text; $label.SetBounds($X,$Y,$Width,$Height)
    $Parent.Controls.Add($label); return $label
}
function New-Button {
    param($Parent,[string]$Text,[int]$X,[int]$Y,[scriptblock]$Action,[int]$Width=140)
    $button=[Windows.Forms.Button]::new(); $button.Text=$Text; $button.SetBounds($X,$Y,$Width,34)
    $button.Add_Click($Action); $Parent.Controls.Add($button); return $button
}
$form=[Windows.Forms.Form]::new()
$form.Text='iTaiwan 連線助手'; $form.ClientSize=[Drawing.Size]::new(660,520)
$form.Font=[Drawing.Font]::new('Microsoft JhengHei UI',10)
$form.StartPosition='CenterScreen'; $form.FormBorderStyle='FixedDialog'; $form.MaximizeBox=$false
$form.AutoScaleMode='Dpi'; $form.Icon=[Drawing.SystemIcons]::Information
$tabs=[Windows.Forms.TabControl]::new(); $tabs.Dock='Fill'; $form.Controls.Add($tabs)
$statusTab=[Windows.Forms.TabPage]::new('連線狀態'); $mailTab=[Windows.Forms.TabPage]::new('Gmail 通知')
$tabs.TabPages.Add($statusTab); $tabs.TabPages.Add($mailTab)
$script:NetworkLabel=New-Label $statusTab '正在讀取連線狀態…' 24 24
$script:NetworkLabel.Font=[Drawing.Font]::new('Microsoft JhengHei UI',16,[Drawing.FontStyle]::Bold)
$script:TailLabel=New-Label $statusTab 'Tailscale：正在檢查…' 24 70
$script:IpLabel=New-Label $statusTab '' 24 106
$script:DetailLabel=New-Label $statusTab 'iTaiwan 會定期檢查通網；其他網路只讀本機狀態。' 24 142 600 44
[void](New-Button $statusTab '立即重試' 24 200 { try { Request-Retry } catch { Show-AppError $_ } })
[void](New-Button $statusTab '暫停 30 分鐘' 180 200 { try { Set-AppPause 30 } catch { Show-AppError $_ } })
[void](New-Button $statusTab '複製 Tailscale IP' 336 200 {
    if ($null -ne $script:Status -and @($script:Status.Tailscale.IPs).Count -gt 0) { [Windows.Forms.Clipboard]::SetText(($script:Status.Tailscale.IPs -join ', ')) }
} 180)
$script:StartupBox=[Windows.Forms.CheckBox]::new(); $script:StartupBox.Text='登入 Windows 後自動啟動'; $script:StartupBox.SetBounds(24,252,350,30)
$script:StartupBox.Add_Click({ try { Set-Autostart $script:StartupBox.Checked } catch { Show-AppError $_ } })
$statusTab.Controls.Add($script:StartupBox)
$script:MailLabel=New-Label $statusTab '通知：尚未設定' 24 292
[void](New-Button $statusTab '查看日誌' 24 340 { $p=Join-Path $script:DataDir 'itaiwan.log'; if (Test-Path $p) { Start-Process notepad.exe -ArgumentList ('"'+$p+'"') } })
[void](New-Button $statusTab '開啟程式資料夾' 180 340 { Start-Process explorer.exe -ArgumentList ('"'+$script:DataDir+'"') } 170)
[void](New-Label $statusTab "關閉視窗後仍在右下角常駐。右鍵圖示可暫停或完全結束。`r`nTailscale 狀態僅代表本機回報，不保證另一台裝置可以連入。" 24 398 600 60)

$settings=Get-AppSettings
$script:EnableMail=[Windows.Forms.CheckBox]::new(); $script:EnableMail.Text='啟用 Gmail 通知'; $script:EnableMail.SetBounds(24,20,400,30); $script:EnableMail.Checked=[bool]$settings.MailEnabled
$mailTab.Controls.Add($script:EnableMail)
[void](New-Label $mailTab '網路恢復、Tailscale 持續異常時通知；斷網期間會先暫存。' 24 58 600 28)
[void](New-Label $mailTab '寄件 Gmail' 24 104 180)
$script:SenderBox=[Windows.Forms.TextBox]::new(); $script:SenderBox.SetBounds(215,100,390,30); $script:SenderBox.Text=$settings.Sender; $mailTab.Controls.Add($script:SenderBox)
[void](New-Label $mailTab '收件地址' 24 150 180)
$script:RecipientBox=[Windows.Forms.TextBox]::new(); $script:RecipientBox.SetBounds(215,146,390,30); $script:RecipientBox.Text=$settings.Recipient; $mailTab.Controls.Add($script:RecipientBox)
[void](New-Label $mailTab '應用程式密碼' 24 196 180)
$script:PasswordBox=[Windows.Forms.TextBox]::new(); $script:PasswordBox.SetBounds(215,192,390,30); $script:PasswordBox.UseSystemPasswordChar=$true; $mailTab.Controls.Add($script:PasswordBox)
[void](New-Label $mailTab "使用 Google 的 16 碼應用程式密碼，不是平常登入密碼。`r`n已設定時可留白保留。密碼由 Windows 加密，只在這台電腦使用。" 24 242 600 55)
[void](New-Button $mailTab '開啟 Google 設定' 24 314 { Start-Process 'https://myaccount.google.com/apppasswords' } 180)
[void](New-Button $mailTab '儲存設定' 220 314 {
    try {
        if (-not $script:RecipientBox.Text.Trim()) { $script:RecipientBox.Text=$script:SenderBox.Text.Trim() }
        Save-MailSettings $script:EnableMail.Checked $script:SenderBox.Text $script:RecipientBox.Text $script:PasswordBox.Text
        $script:PasswordBox.Clear()
        [void][Windows.Forms.MessageBox]::Show('設定已儲存。可按「寄送測試信」確認。關閉通知會清除已存密碼與待寄通知。','iTaiwan 連線助手')
    } catch { Show-AppError $_ }
})
[void](New-Button $mailTab '寄送測試信' 376 314 {
    try {
        if (-not (Get-AppSettings).MailEnabled) { throw '請先儲存並啟用 Gmail 通知。' }
        Set-Content (Join-Path $script:DataDir 'mailtest.flag') 'test'
        [void][Windows.Forms.MessageBox]::Show('測試信已排入佇列。請在連線狀態頁查看寄送結果。','iTaiwan 連線助手')
    } catch { Show-AppError $_ }
})
[void](New-Label $mailTab "需先開啟 Google 兩步驟驗證；部分公司帳號不提供應用程式密碼。`r`n斷網當下無法寄信，恢復後會補寄。收件匣請一併檢查垃圾郵件。" 24 380 600 65)
$tray=[Windows.Forms.NotifyIcon]::new(); $tray.Icon=[Drawing.SystemIcons]::Information; $tray.Text='iTaiwan 連線助手'
$menu=[Windows.Forms.ContextMenuStrip]::new(); $tray.ContextMenuStrip=$menu
function Add-Menu { param([string]$Text,[scriptblock]$Action) $item=$menu.Items.Add($Text); $item.Add_Click($Action) }
Add-Menu '開啟狀態與設定' { $form.Show(); $form.WindowState='Normal'; $form.Activate() }
Add-Menu '立即重試／恢復' { try { Request-Retry } catch { Show-AppError $_ } }
Add-Menu '暫停 30 分鐘' { try { Set-AppPause 30 } catch { Show-AppError $_ } }
Add-Menu '暫停 1 小時' { try { Set-AppPause 60 } catch { Show-AppError $_ } }
[void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
Add-Menu '結束程式' { $script:UiClosing=$true; $form.Close(); [Windows.Forms.Application]::Exit() }
$tray.Add_DoubleClick({ $form.Show(); $form.WindowState='Normal'; $form.Activate() })
$form.Add_FormClosing({ param($sender,$eventArgs) if (-not $script:UiClosing -and $eventArgs.CloseReason -eq 'UserClosing') { $eventArgs.Cancel=$true; $form.Hide() } })
function Refresh-Status {
    $script:Status=Read-AppJson (Join-Path $script:DataDir 'status.json') $null
    $script:StartupBox.Checked=Test-Path $script:StartupPath
    if ($null -eq $script:Status) { return }
    $st=$script:Status
    $stale=([DateTime]::UtcNow-[DateTime]::Parse($st.UpdatedUtc).ToUniversalTime()).TotalSeconds -gt 90
    $paused=(Get-PauseUntil) -gt [DateTime]::UtcNow
    $script:NetworkLabel.Text=if ($stale) {'背景檢查逾時，正在恢復'} elseif ($paused) {'自動連線已暫停'} elseif ($st.Online) {'網際網路已連線'} else {'等待網路恢復'}
    $tailNames=@{Ready='已連線（本機）';NotInstalled='未安裝';NeedsLogin='需要登入';Stopped='已停止';Offline='離線';Timeout='查詢逾時';Unavailable='無法取得狀態';Starting='啟動中'}
    $tailText=if ($tailNames.ContainsKey($st.Tailscale.State)) {$tailNames[$st.Tailscale.State]} else {$st.Tailscale.State}
    $script:TailLabel.Text='Tailscale：'+$tailText
    $script:IpLabel.Text='遠端 IP：'+($st.Tailscale.IPs -join '  ')
    $script:DetailLabel.Text=if ($paused) {'暫停至 '+(Get-PauseUntil).ToLocalTime().ToString('HH:mm')+'。狀態監測與通知持續運作。'} elseif ($stale) {'系統會自動重新啟動卡住的背景程序；亦可按「立即重試」。'} else {'iTaiwan-AutoConnect 是本機設定檔；只對官方 iTaiwan 頁面自動同意。'}
    $mail=Read-AppJson (Join-Path $script:DataDir 'mail-status.json') $null
    $mailState=if (-not (Get-AppSettings).MailEnabled) {'尚未設定／已關閉'} elseif ($null -eq $mail) {'已啟用，尚無寄送紀錄'} else {
        switch ($mail.State) { 'Sent' {'最近一次已交付寄件伺服器'} 'Failed' {'寄送失敗，請確認授權；稍後自動重試'} 'Sending' {'寄送中'} default {'等待寄送'} }
    }
    $script:MailLabel.Text='Gmail 通知：'+$mailState
    $tray.Icon=if ($paused -or $stale) {[Drawing.SystemIcons]::Warning} elseif ($st.Online) {[Drawing.SystemIcons]::Information} else {[Drawing.SystemIcons]::Error}
    $tray.Text=('iTaiwan | '+$(if($stale){'Recovering'}elseif($paused){'Paused'}elseif($st.Online){'Online'}else{'Offline'})+' | Tailscale: '+$st.Tailscale.State)
    if ($tray.Text.Length -gt 63) { $tray.Text=$tray.Text.Substring(0,63) }
}
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=1500
$timer.Add_Tick({
    try {
        if (Test-Path (Join-Path $script:DataDir 'tray-stop.flag')) { $script:UiClosing=$true; [Windows.Forms.Application]::Exit(); return }
        if (Test-Path (Join-Path $script:DataDir 'open-window.flag')) { Remove-Item (Join-Path $script:DataDir 'open-window.flag') -Force; $form.Show(); $form.Activate() }
        Start-AppWorker; Refresh-Status
    } catch { $script:DetailLabel.Text='狀態讀取暫時失敗，稍後重試。' }
})
try {
    Refresh-Status
    if ($SmokeTest) {
        $form.Show(); [Windows.Forms.Application]::DoEvents()
        if ($PreviewPath) {
            $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
            $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
            $tabs.SelectedIndex=1; [Windows.Forms.Application]::DoEvents()
            $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
            $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
            $mailPreview=[IO.Path]::Combine([IO.Path]::GetDirectoryName($PreviewPath), 'mail-preview.png')
            $bitmap.Save($mailPreview,[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
        }
        [pscustomobject]@{Tabs=$tabs.TabCount;MenuItems=$menu.Items.Count;PasswordMasked=$script:PasswordBox.UseSystemPasswordChar;StatusText=$script:NetworkLabel.Text} | ConvertTo-Json
    } else {
        Remove-Item (Join-Path $script:DataDir 'stop.flag') -Force -ErrorAction SilentlyContinue
        $tray.Visible=$true; Start-AppWorker; $timer.Start()
        [Windows.Forms.Application]::Run()
    }
} finally {
    $intentional=$script:UiClosing -or (Test-Path (Join-Path $script:DataDir 'stop.flag')) -or (Test-Path (Join-Path $script:DataDir 'tray-stop.flag'))
    $script:UiClosing=$true; $timer.Stop(); $timer.Dispose(); $tray.Visible=$false; $tray.Dispose(); $form.Dispose()
    if (-not $SmokeTest) { Complete-AppUi -Intentional $intentional }
    if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
