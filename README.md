# iTaiwan 連線助手 v4.4

Windows 10／11 本機小工具：系統匣狀態、iTaiwan 自動連線與同意、Tailscale 狀態，以及可選的 Gmail 通知。不需留著 terminal、WSL 或 Codex；不需另裝 Python／Node.js。

## 啟動、安裝與更新

解壓縮整個 ZIP 至 Windows 本機資料夾，雙擊 **Setup.exe**。安裝後會出現狀態視窗與右下角圖示；圖示若被 Windows 收進隱藏區，可按工作列的 `^` 找到。

- **關閉設定視窗**：程式繼續在系統匣執行。
- **再次開啟**：雙擊系統匣圖示，或從開始功能表找「iTaiwan 連線助手」。
- **退出常駐**：圖示右鍵 → 結束程式，或執行 `Stop.cmd`。若自動啟動仍開啟，下次登入 Windows 會恢復。
- **更新**：解壓新版後再次執行 Setup.exe，保留個人設定、加密密碼、通知佇列與自動啟動偏好。
- **解除安裝**：Windows「設定 → 應用程式 → 已安裝的應用程式」中移除「iTaiwan 連線助手」，或執行 `Uninstall.cmd`。會停止背景程式，移除程式、設定、已存密碼、通知佇列、日誌和捷徑。

程式安裝於 `%LOCALAPPDATA%\ITaiwanAutoConnect`，使用目前 Windows 使用者權限。首次安裝預設登入後啟動；可在狀態頁取消。更新前先檢查檔案，失敗會嘗試回復舊版，回復失敗時保留備份供處理。

`iTaiwan-AutoConnect` 是程式建立的 Windows 個人 Wi-Fi 設定檔名稱，實際 SSID 仍為 `iTaiwan`，不是新熱點。Windows 可能以設定檔名稱顯示網路。此設定檔在解除安裝後會保留，以免影響目前連線。如確定不再使用，可自行執行 `netsh wlan delete profile name="iTaiwan-AutoConnect"`。

## 系統匣與連線狀態

- 查看網際網路、Tailscale 本機狀態，複製 Tailscale IP。
- 立即重試／恢復、暫停 30 分鐘或 1 小時；暫停有到期時間，重啟程式仍保留。暫停的是自動 Wi-Fi／同意操作，狀態監測與通知持續運作。
- 查看日誌、開啟資料夾、切換登入後自動啟動。
- 背景引擎超過 120 秒沒有更新進度，即使程序仍存在，也會由系統匣終止並重新啟動；最後卡住階段記錄於 `watchdog.log`。背景引擎意外退出時，系統匣最多每 30 秒重啟一次、10 分鐘內最多 3 次；手動停止訊號不會被自動重啟覆蓋。原生 EXE 另監督系統匣的非預期退出，同樣最多每 30 秒重啟一次、10 分鐘內 3 次；使用者明確結束與解除安裝會停止全部常駐。系統匣重建時會安全接續同一使用者、同一 Session、同一安裝路徑的既有 worker，保持 heartbeat 監督。

電腦須保持喚醒、Wi-Fi 開啟，且 Windows 使用者已登入。螢幕鎖定或中斷遠端桌面不影響本機程式；關機、睡眠、登出期間不會執行。

平時每輪檢查後等待 15 秒。其他 Wi-Fi 只讀 Windows 本機連線狀態，不發出額外 HTTP 探測。連上精確名稱 `iTaiwan` 時，每 60 秒用 HTTP 探測是否通網，以免過期 Windows 狀態或 VPN 的 Internet 標記掩蓋驗證需求；重新進入 iTaiwan 或按立即重試會立即探測。不切斷既有連線。

未連接 Wi-Fi 且 Windows 判斷無網際網路時，嘗試連上精確名稱 `iTaiwan`，連接要求至少間隔 60 秒。已連 iTaiwan 但通網探測未通過時，先從 Windows 使用的 `/redirect` 探測端點取得當次驗證網址，保留原始編碼與參數，再取得官方 HTTPS 同意頁、檢查表單，重新確認仍在 iTaiwan 後才送出同意；每次至少間隔 60 秒。閘道的未知 HTML 或中間轉址不會被執行或跟隨，也不會開啟瀏覽器。

此程式會自動送出 iTaiwan 同意表單；使用前請確認你已閱讀並同意服務條款。自動送出支援官方 `auth.itaiwan.gov.tw/noauth_page.php`（及英文版）的 HiNet 與北榮流程。HiNet 目的地為固定 `wlanac.hinet.net/loginpages/userlogin.shtml`；北榮目的地為 `itaiwan.vghtpe.gov.tw/eGovWeb/eGovLogin.aspx`，必須與官方網址當次提供的完整 `loginurl` 相符，保留 AP／client／switch 參數，並確認 client 身分與本機 Wi-Fi 網卡相同。若北榮回傳額外隱藏表單，只允許接續 POST 到固定 `https://wlauth.vghtpe.gov.tw/login.html`，最多 3 步且每步再次確認連線。不保存或重用裝置與 AP 參數；官方表單不符合預期、跨域轉址、使用者輸入或驗證碼會拒絕送出。

## 常駐與檔案修復

`ITaiwan.exe` 是不占 terminal 的原生監督器，內嵌九個必要程式／說明檔。啟動與運作期間發現程式檔缺失時，從內嵌版本補回並驗證 SHA-256；只處理 missing，不覆寫既有檔案、不包含個人設定與密碼。同一 EXE 生命周期中，同一檔最多自動修復一次；再次遭移除時停止修復並留下 `launcher-error.txt`，方便檢查外部刪除／隔離原因。修復與重啟記錄在 `launcher.log`（1 MB 輪替）。這不能保證 EXE 本身遭刪除或隔離時仍能運作。

一般啟動會顯示狀態視窗；登入自動啟動使用 `--background` 只顯示系統匣。最多有原生監督器、系統匣與 worker 三個程序。

## Gmail 通知設定

通知**預設關閉**，沒有預先設定任何收件者，也不會自動讀取或使用你瀏覽器內的 Google 帳號。

1. 開啟系統匣 →「Gmail 通知」，勾選啟用。
2. 填入寄件 Gmail、收件地址；收件地址留白會使用寄件地址，方便寄給自己。
3. 在 Google 帳戶啟用兩步驟驗證，建立一組專用的 **16 碼應用程式密碼**。可按「開啟 Google 設定」前往官方頁面。
4. 在本機設定視窗輸入應用程式密碼並儲存。不要填平常的 Google 登入密碼，也不需把任何密碼傳給他人。
5. 按「寄送測試信」，在狀態頁確認結果，再檢查 Gmail 收件匣／垃圾郵件。

應用程式密碼使用 Windows 目前使用者的 DPAPI 加密保存，不會以明文存檔或寫進日誌。既有密碼留白可保留；更換寄件帳號需重新授權。**關閉通知並儲存會清除密碼及所有待寄通知**。本版僅支援 Gmail SMTP 應用程式密碼；部分受管理帳號或安全設定不提供這個選項，未實作 OAuth 登入。

通知事件：

- 網路中斷至少 30 秒後恢復，附觀測到的中斷秒數。
- 有網際網路，但 Tailscale 持續異常至少 2 分鐘。
- 先前已通知的 Tailscale 異常恢復。
- 你手動要求的測試信。

斷網當下寄不出去，事件會在本機暫存，恢復後補寄。同類待寄事件合併，每分鐘最多嘗試一封；失敗依序延長重試間隔，上限每小時一次，直到成功或關閉通知。電腦長時間睡眠／關閉後，不把整段未觀測時間宣稱為斷網時長。

「已交付寄件伺服器」表示 Gmail SMTP 接受寄件，不等於保證進入收件匣。若伺服器已收件但回覆途中斷線，重試仍可能造成重複信；程序在寄出後、刪除待寄檔前被強制終止也有同樣可能。SMTP 授權失敗會保持待寄並顯示失敗，請檢查應用程式密碼、Google 帳戶政策與防火牆。

## Tailscale 範圍

每 60 秒唯讀查詢已安裝的 Tailscale，本機 `Running` 且 `Self.Online` 才顯示「已連線（本機）」。顯示本機 IP、需要登入、停止、離線或查詢失敗。**不會自動登入、重新啟動、切換 exit node 或改動 VPN 設定**；本機正常不代表另一台裝置實際能連入，ACL、防火牆、遠端服務狀態仍需另外確認。

## 診斷與檔案

`Check.cmd` 只讀 Wi-Fi 狀態，不發出連接要求。日誌：`%LOCALAPPDATA%\ITaiwanAutoConnect\itaiwan.log`，超過 1 MB 保留一份 `.old`。

- `heartbeat.json`：背景程序的進度與階段；`watchdog.log`：逾時復原紀錄（上限 1 MB，另留一份 `.old`）。
- `status.json`：背景狀態；`control.json`：暫停到期時間。
- `settings.json`：通知設定與加密密碼。不要把整個檔案貼到公開問題回報。
- `outbox`：待寄事件；`mail-status.json`：最近寄件結果；`monitor.json`：狀態轉換紀錄。
- Wi-Fi 查詢錯誤 5：部分 Windows 11 版本須開啟位置服務及適用的存取權，才能讀取 Wi-Fi 狀態。
- `ConsentPage`／`ConsentPost`／`SwitchPost` 錯誤：分別表示取同意頁、送出第一步或北榮接續送出失敗；紀錄底層網路錯誤類型，省略裝置識別碼與網址參數。
- 系統匣顯示背景已停止：按立即重試，或開啟日誌查看原因。

## 開發與測試

所有 `.ps1` 以 UTF-8 BOM 儲存，支援 Windows PowerShell 5.1 中文文字。`Build.ps1` 使用內建編譯介面建立無主控台的 `ITaiwan.exe` 與 `Setup.exe`，無需安裝 SDK。這是本機編譯工具，未購買商業程式碼簽章。

- `Test.ps1`：原有連線／官方驗證邊界與所有腳本語法。
- `Test-App.ps1`：DPAPI、通知事件、暫存／節流／重試、Tailscale 狀態，不寄真實郵件。
- `Test-Launcher.ps1`：隔離原生 EXE／無害子程序，驗證實際檔案遺失修復、重啟、首次視窗顯示、singleton、停止與反覆刪除的界線。
- `Test-Recovery.ps1`：GUI 意外退出不寫停止旗標、安全接續 orphan worker，以及既有 worker 的 heartbeat 逾時處理。
- `Test-Portal.ps1`：北榮動態參數、換 AP、巢狀編碼、client 身分、受限隱藏表單接續與不洩漏識別碼的錯誤紀錄。
- `Test-Watchdog.ps1`：進度逾時判斷、競態回歸，以及終止刻意睡眠的隔離子程序。
- `Test-Supervisor.ps1`：以模擬程序執行實際監督函式，驗證下一輪重啟、手動停止、暫停保留與重啟節流。
- `Test-Installer.ps1`：獨立測試安裝位置和登錄項目，驗證安裝／更新／移除及故障回復，不碰正式安裝。
- `Tray.ps1 -SmokeTest -DataDirectory <測試資料夾> -PreviewPath <PNG>`：產生程式自身的兩頁介面預覽，不啟動背景工作。
- `ITaiwan.ps1 -Once -MonitorOnly -DataDirectory <測試資料夾>`：唯讀實際 Windows／Tailscale 狀態一輪，不連 Wi-Fi、不送同意、不寄信。

真實登入到期恢復、另一台裝置能否連入、以及真實 Gmail 送達，不能由上述模擬測試取代。

參考：[iTaiwan 官方使用說明](https://itaiwan.gov.tw/ITaiwanArticle/Contents?articleId=68)、[Tailscale CLI](https://tailscale.com/docs/reference/tailscale-cli)、[Google 應用程式密碼](https://support.google.com/accounts/answer/185833?hl=zh-Hant)。

## GitHub 與資料範圍

Repository 僅含原始碼、測試與一般文件。本機設定、加密密碼、郵件佇列、狀態、日誌、私人診斷紀錄和編譯 EXE 不納入 Git。請閱讀 [SECURITY.md](SECURITY.md) 的權限與資料界線。在 Windows 執行 `Build.ps1` 後才會產生 `ITaiwan.exe`／`Setup.exe`。
