# Switch Pad

A Windows app that packs your own Switch games into iPad apps and installs them, with one window instead of a terminal:
pick games from a library, press Start, and it extracts, packs, signs and installs each one. It keeps itself, the shell
and the packer up to date from this repository's latest release.

## Get it

1. Download `SwitchPad.zip` from the [latest release](https://github.com/Mono0713/ns2ios-shell/releases/latest) and unzip it
   anywhere (for example the Desktop).
2. Double-click `Switch Pad.cmd`. On first start it tidies the folder: everything of its own goes into `程式\` and a
   `Switch Pad.exe` with the icon appears next to `遊戲\` and `合包\`; from then on, open that. The first time, press **安裝** (Install) at the top: it installs Python 3.12 with
   winget when there is none, the Python packages, the shell, the packer and its tools, and `plumesign` (the command-line
   [Impactor](https://github.com/khcrysalis/Impactor)). It also puts a `Switch Pad` shortcut with an icon on the Desktop.
3. Give it your `prod.keys`: it looks in Ryujinx's and the yuzu-family emulators' folders by itself; otherwise drag the
   file onto the window (a copy goes to `work\`, and stays on this computer).
4. Press **登入 Apple ID** (Sign in) once. A free Apple ID works; its apps expire after 7 days (**全部續期** re-signs them)
   and it allows three apps at a time.
5. Drag NSP / XCI files onto the window: each game gets a folder under `遊戲\`; an update or DLC dropped onto a game's card
   joins that game, and the newest version is the one packed.

The iPad must be connected by USB and unlocked, and Windows needs Apple's device service: install **Apple Devices**
from the Microsoft Store (or iTunes).

## Files

| File | What it does |
|---|---|
| `Switch Pad.exe` | Made on first start (compiled locally from a few lines in `nxn-app.ps1`); starts `程式\nxn-app.ps1` |
| `Switch Pad.cmd` | Starts the app before `Switch Pad.exe` exists |
| `nxn-app.ps1` | The window: library, queue, progress, settings, update check |
| `nxn.ps1` | One game: pack with `scripts/nxn_pack.py`, then sign and install with `plumesign`; also runs alone (`.\nxn.ps1 -?`) |
| `nxn-update.ps1` | Install and update: Python, packages, shell, tools, packer source, `plumesign`, and Switch Pad itself |
| `fix_empty_romfs.py` | Gives an IPA whose game has no RomFS (ANIMAL WELL) a placeholder, so the shell finds its files |
| `make_provisional.py` | Writes a provisional profile for a game with none, on Windows (experimental) |

Everything it downloads or writes stays beside it. The top folder holds only what you use: `Switch Pad.exe`, `遊戲\`
(games) and `合包\` (merged packages). The scripts, `work\` (shell, packer, tools, logs, settings) and `工具\` (plumesign)
are in `程式\`. An older install with all of these at the top is moved there the next time the app starts (skipped while
another Switch Pad is running).
No game files or keys are ever uploaded. The app's text is in Traditional Chinese.

## Releasing

`SwitchPad.zip` is this folder. `.github/workflows/switchpad.yml` uploads it to the latest release whenever `switchpad/`
changes on `main`, and every shell release (`shell.yml`) includes it too. The updater compares the asset's upload time
with `work\app-version.txt`, and the release tag with `work\release.txt`.

---

## 中文說明

Switch Pad 是 Windows 上的打包安裝程式：從遊戲庫挑遊戲、按「開始」，就會自動解包、打包、簽章並裝到 iPad，
還會從這個 repo 最新的 release 自己更新（程式、殼、打包器）。

1. 從[最新 release](https://github.com/Mono0713/ns2ios-shell/releases/latest) 下載 `SwitchPad.zip`，解壓到任何地方。
2. 打開 `Switch Pad.cmd`。第一次打開會整理資料夾：程式檔、work、工具 都收進 `程式\`，最上層只剩 `Switch Pad.exe`、`遊戲\`、`合包\`，之後就開 `Switch Pad.exe`。第一次按上方的「安裝」：沒有 Python 會用 winget 裝 3.12，再裝套件、殼、打包器和 plumesign，並在桌面建捷徑。
3. prod.keys：會自己到 Ryujinx 和 yuzu 系模擬器的資料夾找；找不到就把檔案拖進視窗（複製一份到 `work\`，只留在這台電腦）。
4. 按「登入 Apple ID」一次。免費帳號簽的 App 7 天後過期（按「全部續期」重簽），同時最多 3 個。
5. 把 NSP / XCI 拖進視窗新增遊戲；更新檔或 DLC 拖到遊戲卡上就會加進那款，打包時自動用最新版本。

iPad 要用 USB 接著並解鎖；Windows 要有 Apple 的裝置服務（從 Microsoft Store 安裝「Apple 裝置」或 iTunes）。
