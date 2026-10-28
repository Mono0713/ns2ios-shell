# nxn.ps1 - 一鍵：把一個遊戲資料夾打包成 IPA，再簽章並安裝到接著的 iPad。
# 需要先準備好 work\（打包器、工具、Python 套件）：在 Switch Pad 按「安裝」，或執行 nxn-update.ps1。
#
# 用法：
#   .\nxn.ps1 -Login                       第一次：登入 Apple ID（之後不用再登）
#   .\nxn.ps1 "遊戲\Boomerang Fu"          打包並安裝
#   .\nxn.ps1 "遊戲\Boomerang Fu" -Out 測試.ipa     換個輸出檔名，不蓋掉舊的 IPA
#   .\nxn.ps1 "遊戲\Boomerang Fu" -PackOnly         只打包，不安裝
#   .\nxn.ps1 "遊戲\Boomerang Fu" -Shell work\phonepads\art7\shell-....zip   用別的殼（輸出成 <資料夾>-<殼版本>.ipa）
#   .\nxn.ps1 -Ipa "遊戲\Boomerang Fu\x.ipa"        只安裝現成的 IPA
param(
    [Parameter(Position = 0)][string]$GameDir = '',
    [string]$Ipa = '',
    [string]$Out = '',
    [string]$Keys = '',              # 沒給就自己找（見 Find-Keys）
    [string]$Udid = '',
    [string]$Shell = '',
    [string]$Python = '',            # 沒給就用 nxn-update.ps1 記下的那個
    [switch]$Login,
    [switch]$PackOnly,
    [switch]$Overwrite,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }

# 原生程式寫到 stderr 時 PowerShell 5.1 會當成錯誤，所以這些呼叫都只看結束碼。
function RunExe($exe, $arglist) {
    $ErrorActionPreference = 'Continue'
    & $exe @arglist 2>&1 | ForEach-Object {
        # stderr 的空行在 PowerShell 5.1 會變成 "System.Management.Automation.RemoteException"
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        if ($line -eq 'System.Management.Automation.RemoteException') { $line = '' }
        Write-Host $line
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return $code
}

$here = $PSScriptRoot
$root = Join-Path $here 'work'
# prod.keys：Switch Pad 自己的 → Ryujinx → yuzu 系的模擬器，第一個找到的
function Find-Keys {
    $c = @((Join-Path $root 'prod.keys'), (Join-Path $here 'prod.keys'), "$env:APPDATA\Ryujinx\system\prod.keys")
    foreach ($emu in 'yuzu', 'suyu', 'sudachi', 'citron', 'eden', 'torzu') { $c += "$env:APPDATA\$emu\keys\prod.keys" }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}
if (-not $Keys) { $Keys = Find-Keys }
if (-not $Python) {
    $saved = Join-Path $root 'python.txt'
    $Python = if (Test-Path $saved) { (Get-Content $saved -Raw).Trim() } else { 'python' }
}
$plume = Join-Path $here '工具\plumesign.exe'

function Finish($msg, $color) {
    Write-Host ''
    Write-Host $msg -ForegroundColor $color
    Write-Host ("總共花了 {0:mm\:ss}" -f (New-TimeSpan $started (Get-Date)))
    if (-not $NoPause -and $Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host '按 Enter 關閉' | Out-Null }
}

try {
    if (-not (Test-Path $plume)) { throw "找不到 $plume（Impactor 的命令列版，從 Impactor 的 release 下載 plumesign-windows-x86_64.exe 改名成 plumesign.exe）。" }

    # ---- 第一次：登入 Apple ID ----
    if ($Login) {
        Step '登入 Apple ID'
        $user = (Read-Host 'Apple ID（email）').Trim()
        if (-not $user) { throw '沒有輸入 Apple ID。' }
        # plumesign 自己問密碼時會把字顯示出來，所以由這裡用隱藏輸入問，再交給它
        $sec = Read-Host '密碼（打字不會顯示）' -AsSecureString
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if (-not $pw) { throw '沒有輸入密碼。' }
        Write-Host '登入中，如果要雙重驗證碼會在下面問。'
        # 直接跑、不接管輸出，雙重驗證碼才能在這個視窗輸入
        & $plume account login --username $user --password $pw
        $code = $LASTEXITCODE
        $pw = $null
        if ($code) { throw "登入失敗（結束碼 $code）。" }
        Finish '登入完成。' Green
        return
    }

    if (-not $GameDir -and -not $Ipa) { throw '請用 -GameDir 或 -Ipa 指定要打包或安裝的東西。' }

    # ---- 先確認登入狀態，不然白打包一小時 ----
    if (-not $PackOnly) {
        Step '檢查 Apple ID'
        # plumesign 的記錄寫在 stderr，Stop 模式下會被當成錯誤，所以這裡改用 Continue 收輸出
        $ErrorActionPreference = 'Continue'
        $acct = (& $plume account list 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }) -join "`n"
        $acctCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $mail = [regex]::Match($acct, '[\w.+-]+@[\w-]+(\.[\w-]+)+').Value
        if ($acctCode -or -not $mail) { Write-Host $acct.Trim(); throw "還沒登入 Apple ID，請先執行：`n  .\nxn.ps1 -Login" }
        Write-Host "已登入：$mail"
    }

    # ---- 打包 ----
    if (-not $Ipa) {
        if (-not (Test-Path $GameDir)) { throw "找不到遊戲資料夾：$GameDir" }
        $GameDir = (Resolve-Path $GameDir).Path
        if (-not $Keys -or -not (Test-Path $Keys)) { throw "找不到 prod.keys。把它拖進 Switch Pad 的視窗，或用 -Keys 指定。" }
        $Keys = (Resolve-Path $Keys).Path

        $srcDir = Join-Path $root 'src'
        $shellZip = Join-Path $root 'shell.zip'
        $customShell = $false
        if ($Shell) {
            if (-not (Test-Path $Shell)) { throw "找不到殼：$Shell" }
            $Shell = (Resolve-Path $Shell).Path
            $customShell = $Shell -ne (Resolve-Path $shellZip -ErrorAction SilentlyContinue).Path
            $shellZip = $Shell
        }
        Write-Host "殼：$shellZip"
        $packer = Join-Path $srcDir 'scripts\nxn_pack.py'
        foreach ($p in @($srcDir, $shellZip, $packer)) {
            if (-not (Test-Path $p)) { throw "還沒準備好打包器（缺 $p），請先在 Switch Pad 按「安裝」。" }
        }
        $nx = Get-ChildItem (Join-Path $root 'tools') -Recurse -Filter 'nx_extract.exe' | Select-Object -First 1
        if (-not $nx) { throw "在 $root\tools 找不到 nx_extract.exe，請先在 Switch Pad 按「安裝」。" }

        $outArg = @()
        $existing = @(Get-ChildItem $GameDir -Filter '*.ipa' -ErrorAction SilentlyContinue)
        if ($Out) {
            # 只有檔名就放在遊戲資料夾裡；有資料夾的相對路徑以 nxn\ 為準（不然會變成 遊戲\X\遊戲\X\…）
            $outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out }
                       elseif ($Out -match '[\\/]') { Join-Path $here $Out }
                       else { Join-Path $GameDir $Out }
            $outArg = @('-o', $outPath)
        } elseif ($customShell) {
            # 不是正式殼（例如測試殼）：輸出成 <資料夾>-<殼版本>.ipa，不碰正式的 IPA
            $tag = if ((Split-Path $shellZip -Leaf) -match 'shell-\d+-([0-9a-f]+)') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($shellZip) }
            $outPath = Join-Path $GameDir ((Split-Path $GameDir -Leaf) + "-$tag.ipa")
            $outArg = @('-o', $outPath)
            Warn "用的不是正式殼，這次會輸出成 $(Split-Path $outPath -Leaf)"
        } elseif ($existing.Count -and -not $Overwrite) {
            # 資料夾裡已經有驗證過的 IPA，預設不蓋掉它：這次輸出成 <資料夾>-new.ipa
            $outPath = Join-Path $GameDir ((Split-Path $GameDir -Leaf) + '-new.ipa')
            $outArg = @('-o', $outPath)
            Warn "資料夾裡已經有 $($existing[0].Name)，這次會輸出成 $(Split-Path $outPath -Leaf)（要蓋掉舊的請加 -Overwrite）"
        }

        Step "打包 $(Split-Path $GameDir -Leaf)（這一步最久，大作可能一小時以上）"
        $pyExe = (& $Python -c 'import sys; print(sys.executable)').Trim()
        $before = @(Get-ChildItem $GameDir -Filter '*.ipa' | ForEach-Object { $_.FullName })
        Push-Location $srcDir
        try {
            $env:PYTHONUTF8 = '1'
            $code = RunExe $pyExe (@($packer, $shellZip, $GameDir, '-k', $Keys, '--tools', $nx.DirectoryName) + $outArg)
        } finally { Pop-Location }
        if ($code) { throw "打包失敗（結束碼 $code），記錄在 $GameDir 裡的 *_pack\logs。" }

        if ($outArg) {
            $ipaFile = Get-Item $outPath
        } else {
            # 取這次新出現的 IPA；都沒有新的就取最新改過的
            $after = Get-ChildItem $GameDir -Filter '*.ipa' | Sort-Object LastWriteTime -Descending
            $ipaFile = ($after | Where-Object { $before -notcontains $_.FullName } | Select-Object -First 1)
            if (-not $ipaFile) { $ipaFile = $after | Select-Object -First 1 }
        }
        if (-not $ipaFile) { throw "打包器沒有產生 IPA。" }

        # 沒有 RomFS 的遊戲（例如 ANIMAL WELL）會讓 shell 顯示 "Game files not found"，補一個佔位檔
        Step '檢查 RomFS'
        $fix = Join-Path $here 'fix_empty_romfs.py'
        if (Test-Path $fix) { RunExe $pyExe @('-I', $fix, $ipaFile.FullName) | Out-Null }

        $Ipa = $ipaFile.FullName
        Ok "IPA：$Ipa（$([int]($ipaFile.Length / 1MB)) MB）"
    } else {
        if (-not (Test-Path $Ipa)) { throw "找不到 IPA：$Ipa" }
        $Ipa = (Resolve-Path $Ipa).Path
    }

    if ($PackOnly) { Finish "打包完成：$Ipa" Green; return }

    # ---- 簽章並安裝 ----
    Step '簽章並安裝到 iPad（iPad 要用 USB 接著並解鎖；第一次會問要不要信任這台電腦）'
    # plumesign 的 --udid 其實要的是 Apple 行動裝置服務（usbmuxd）給這次連線的編號（1、2、3…），
    # 不是真的 UDID，所以直接問服務（127.0.0.1:27015）現在接著哪些裝置，免得 plumesign 每次都問「Select a device」
    function Get-MuxDevices {
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $tcp.Connect('127.0.0.1', 27015)
            $ns = $tcp.GetStream(); $ns.ReadTimeout = 5000
            $body = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>MessageType</key><string>ListDevices</string><key>ClientVersionString</key><string>nxn</string><key>ProgName</key><string>nxn</string></dict></plist>')
            $hdr = [byte[]]([BitConverter]::GetBytes([uint32](16 + $body.Length)) + [BitConverter]::GetBytes([uint32]1) +
                   [BitConverter]::GetBytes([uint32]8) + [BitConverter]::GetBytes([uint32]1))
            $ns.Write($hdr, 0, 16); $ns.Write($body, 0, $body.Length)
            function ReadN($n) { $b = New-Object byte[] $n; $o = 0
                while ($o -lt $n) { $r = $ns.Read($b, $o, $n - $o); if ($r -le 0) { throw 'usbmuxd 斷線' }; $o += $r }; $b }
            $len = [BitConverter]::ToUInt32((ReadN 16), 0)
            $doc = New-Object Xml.XmlDocument; $doc.XmlResolver = $null
            $doc.LoadXml([Text.Encoding]::UTF8.GetString((ReadN ($len - 16))))
            # DeviceList 裡每台：<dict> DeviceID / Properties{ SerialNumber(=UDID), ConnectionType } </dict>
            foreach ($d in $doc.SelectNodes('/plist/dict/array/dict')) {
                $id = $d.SelectSingleNode('key[.="DeviceID"]/following-sibling::*[1]').InnerText
                $pr = $d.SelectSingleNode('key[.="Properties"]/following-sibling::dict[1]')
                [pscustomobject]@{
                    Id     = $id
                    Serial = $pr.SelectSingleNode('key[.="SerialNumber"]/following-sibling::*[1]').InnerText
                    Usb    = $pr.SelectSingleNode('key[.="ConnectionType"]/following-sibling::*[1]').InnerText -eq 'USB'
                }
            }
        } finally { $tcp.Close() }
    }
    $muxId = $null
    try {
        $devs = @(Get-MuxDevices)
        $norm = { param($x) ($x -replace '-', '').ToUpper() }
        if ($Udid) { $pick = @($devs | Where-Object { (& $norm $_.Serial) -eq (& $norm $Udid) }) }
        else {
            # 同一台 iPad 用 USB 又開 Wi-Fi 同步時會出現兩筆，優先 USB
            $pick = @($devs | Where-Object Usb)
            if (-not $pick) { $pick = $devs }
            $pick = @($pick | Group-Object Serial | ForEach-Object { $_.Group[0] })
        }
        if ($pick.Count -eq 1) { $muxId = $pick[0].Id; Write-Host "裝置：$($pick[0].Serial)（連線編號 $muxId）" }
        elseif ($pick.Count -gt 1) { Write-Host "接著 $($pick.Count) 台 Apple 裝置，請在 plumesign 視窗選一台" }
        else { Write-Host '找不到接著的 iPad（要用 USB 接著、解鎖），交給 plumesign 自己找' }
    } catch {
        Write-Host "問不到 Apple 行動裝置服務（$($_.Exception.Message)），交給 plumesign 自己選裝置"
    }
    $signArgs = @('sign', '--package', $Ipa, '--apple-id', '--register-and-install')
    # plumesign 只有在要問問題時（選裝置、要不要重設憑證、重新登入）才需要真的終端機，輸出被接管時問問題會出現 "not a terminal"。
    # 所以知道裝到哪台時先在背景跑、記錄直接寫進這裡；失敗了才另開一個命令列視窗讓你回答，失敗時停住讓你看訊息。
    function Run-SignQuiet($argv) {
        $ErrorActionPreference = 'Continue'
        & $plume @argv 2>&1 | ForEach-Object {
            $l = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            if ($l.Trim()) { Write-Host $l }
        }
        $c = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        return $c
    }
    function Q($x) { "'" + ($x -replace "'", "''") + "'" }
    function Run-Sign($argv, $pause) {
        $onFail = if ($pause) { "Write-Host ''; Read-Host '安裝失敗，看完上面的訊息後按 Enter 關閉' | Out-Null" } else { "Start-Sleep 3" }
        $inner = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; & $(Q $plume) $(($argv | ForEach-Object { Q $_ }) -join ' '); " +
                 "`$c = `$LASTEXITCODE; if (`$c) { $onFail }; exit `$c"
        $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`"" -Wait -PassThru
        return $proc.ExitCode
    }
    if ($muxId) {
        $code = Run-SignQuiet ($signArgs + @('--udid', $muxId))
        if ($code) {
            # 編號在拔插後會變，或 plumesign 要問問題（重新登入、重設憑證），就開視窗讓你回答
            Warn "背景安裝沒成功（結束碼 $code），改開 plumesign 視窗，如果它問問題請在那個視窗回答"
            $code = Run-Sign $signArgs $true
        }
    } else {
        Write-Host '（plumesign 會在另一個命令列視窗執行，如果它問問題請在那個視窗回答）'
        $code = Run-Sign $signArgs $true
    }
    if ($code) {
        throw @"
安裝失敗（結束碼 $code）。IPA 本身是好的：$Ipa
常見原因：
  - iPad 沒解鎖，或還沒按「信任這台電腦」
  - 免費 Apple ID 的憑證 7 天就過期、同時最多 3 個 App，先在 iPad 上刪掉一個舊的
  - 還是不行就用 工具\Impactor-windows-x86_64-portable.exe 手動拖這個 IPA 進去
"@
    }

    # 記下這個遊戲最後裝的是哪個 IPA，給「全部重簽」用（同一個資料夾只記最新一次）
    try {
        $db = Join-Path $root 'installed.json'
        $map = [ordered]@{}
        if (Test-Path $db) {
            (Get-Content $db -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $map[$_.Name] = $_.Value }
        }
        $map[(Split-Path $Ipa -Parent)] = [ordered]@{ ipa = $Ipa; time = (Get-Date).ToString('s') }
        $map | ConvertTo-Json -Depth 3 | Set-Content $db -Encoding UTF8
    } catch { Warn "記錄安裝紀錄失敗：$($_.Exception.Message)" }

    Finish "裝好了：$Ipa 已經在 iPad 上，可以直接開。（免費帳號 7 天後要重簽）" Green
} catch {
    Finish "出錯了：$($_.Exception.Message)" Red
    exit 1
}
