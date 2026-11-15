# 遊戲支援表（Switch Pad + iPad 殼）

這張表記錄的是 **Switch Pad（Windows）打包、裝進 iPad「SwitchPad」遊戲庫** 這條路線上，每款遊戲實際測過的結果。
它跟 [SUPPORTED.md](SUPPORTED.md) 不一樣：SUPPORTED.md 是上游 nxnative 有正式設定檔的清單（Mac 流程），這張表是我們自己在 iPad 實機上測的。

- 整理日期：2026-11-14，殼 = main `45dc167`（測試殼 art30，`326822b`）。
- 測試機：iPad（記憶體寬裕，記錄顯示離上限約 5.6 GB）。
- **只有使用者在 iPad 上親自玩過、並明確回報的才標「可玩」**。電腦上打包成功、或記錄裡沒有閃退，都只算「未驗證」。

## 狀態說明

| 標記 | 意思 |
|---|---|
| ✅ 可玩 | 使用者在 iPad 上確認能正常玩 |
| ⚠️ 可玩，有問題 | 能玩，但有已知問題（見備註） |
| ❓ 未驗證 | 已打包進遊戲庫，但在目前的殼上沒有使用者確認過 |
| ⛔ 上不了 iPad | 目前打包不了、裝不上，或殼不支援 |

「專用修正」欄：
- **不用**：通用流程就能跑（殼或打包器的通用修正仍可能是因這款才加的，寫在備註）。
- **repo 設定檔**：`dm/games/<Title ID>/` 裡有正式設定檔。
- **電腦端專用**：只放在使用者電腦 `程式\work\multigame\art<N>\src-*\dm\games\<Title ID>\` 的暫定設定檔或 `patches.py`，**還沒進 repo**；別人用這個程式時拿不到，見文末「待辦」。

## 支援表

| 遊戲 | Title ID | 引擎 / 圖形 | 狀態 | 專用修正 | 已知問題 / 備註 | 最後確認 |
|---|---|---|---|---|---|---|
| SUPER BOMBERMAN R 2 | `0100B87017D94000` | Unity 2020.3 / NVN | ✅ 可玩 | 電腦端專用：記憶體 `mem_alias 0x158000000`、`mem_reserve 0x1F0000000` | 殼補了 Unity 外掛用的好友（friends/ngc）功能（`8af1b65`）。 | 2026-11-14 |
| All You Need Is Help | `010072F01DC94000` | Unity 2022.3 / NVN | ✅ 可玩 | 電腦端專用：同上的記憶體設定 | 殼內建離線 Epic Online Services 替身（`326822b`），遊戲改玩離線。讀不到玩家頭像（不影響遊玩）。 | 2026-11-14 |
| Splatterbot | `0100E4B0223AC000` | Unity 2021.3 / NVN | ✅ 可玩 | 電腦端專用：`patches.py`（遊戲本身的繁中語言表 bug） | 沒有這個修正時，選繁中下次開會變韓文；暫時辦法是選英文或简体中文。 | 2026-11-14 |
| Unrailed 2: Back on Track | `010593A5182E4000` | Godot .NET / NVN | ✅ 可玩 | 電腦端專用：`mem_stack 0x80000000`、`mem_alias 0x158000000`、`mem_reserve 0x1F0000000` | 殼修了主執行緒堆疊大小回報（`311d297`）與 .NET GC 預設（`99e1780`）。 | 2026-11-14 |
| Super Mario Bros. Wonder | `010015100B514000` | NVN | ✅ 可玩 | repo 設定檔 | 需在電腦裝 Apple「Metal Developer Tools for Windows」預先編譯著色器，否則跑動時會卡頓。 | 2026-11-08 |
| CloverPit | `0100ABA02501A000` | Unity / NVN | ✅ 可玩 | 不用 | 記錄有 `nvnTextureViewCompare` 未實作的紅字，目前看不出影響。 | 2026-11-07 |
| Balatro | `0100CD801CE5E000` | LÖVE / OpenGL | ✅ 可玩 | repo 設定檔 | OpenGL 遊戲：第一次玩時殼會錄著色器，再按一次「裝到 iPad」才有完整畫面。 | 2026-11-07 |
| Ultimate Chicken Horse | `0100FCF002A58000` | Unity 2021.3 / NVN | ✅ 可玩 | 不用 | 開場閃紫已修（`2e0f42f`）；打包器加了 Unity 2021.3 格式。 | 2026-11-07 |
| Tricky Towers | `010015F005C8E000` | Unity / NVN | ✅ 可玩 | 電腦端專用：`app_pool 0x80000000`（2 GB，1 GB 開不了） | | 2026-10-30（舊殼） |
| Super Mario Odyssey | `0100000000010000` | NVN | ⚠️ 可玩，有問題 | repo 設定檔（驗證版本 1.4.1，要裝更新） | 帽子王國地上有金色細三角線、偶爾整個畫面閃白；煙霧／粒子邊緣變成硬方塊（半透明沒做出來）。調查中。 | 2026-11-08 |
| Super Mario 3D World + Bowser's Fury | `010028600EBDA000` | NVN | ⚠️ 可玩，有問題 | repo 設定檔 | 掉幀：記錄中仍有 35 ms 以上的長幀。電腦預先編譯著色器後改善很多，但還沒完全順。 | 2026-11-08 |
| OddBallers | `010079A015976000` | Unity 2019.4 / NVN | ⚠️ 可玩，有問題 | 不用 | 大廳與對戰約 60 FPS（`PR #31`）；畫面上有細線，尚未追查。 | 2026-11-01（舊殼） |
| Roof Rage | `010088100DD42000` | Haxe/OpenFL / OpenGL ES 2 | ⚠️ 可玩，有問題 | 不用 | 第一次玩是紫畫面（殼在錄著色器），再「裝到 iPad」一次後才有畫面。11/06 回報「玩一陣子會自己跳出」，當時記錄被蓋掉，原因未查。 | 2026-10-31（舊殼） |
| Heave Ho | `0100ADD00E17E000` | Unity 2018.3 / NVN | ⚠️ 可玩，有問題 | 電腦端專用：`patches.py`（改成中文） | 進入關卡時閃紫畫面（10/31 回報，未確認是否還有）。 | 2026-10-31（舊殼） |
| Stick Fight: The Game | `0100622009FB0000` | Unity / NVN | ❓ 未驗證 | 不用 | 修好黑畫面後能到加入畫面，會出現「未登入」提示，要選 LOCAL。之後回報「不能玩」，細節沒有回報。 | 2026-10-31（舊殼） |
| Toasterball | `0100FE701A630000` | Unity 2022.2 / NVN | ❓ 未驗證 | 不用 | 存檔後閃退已修（殼 hook `nn::fs::ReadFile` 帶 ReadOption 版本）。iPad 記錄中最後一次跑了約 4 分半沒閃退，但使用者沒確認。 | — |
| Ultimate Sheep Raccoon | `010095A0231E2000` | Unity / NVN | ❓ 未驗證 | 不用 | 開場中止（Result 0xe8d）已修（殼回答 nsd 伺服器環境）。記錄中最後一次跑了約 3 分鐘沒閃退，但使用者沒確認。 | — |
| Super Bunny Man | `0100EF401D9D8000` | Unity 6000.5 / NVN | ❓ 未驗證 | 不用 | 需要 PyPI 套件 `zbic`（新 NSO 壓縮格式）；殼補了 SDK 22 執行緒 ID。記錄中有跑約 3 分鐘，不確定畫面是否完整。 | — |
| Lethal League Blaze | `01003AB00983C000` | Unity 2018.4 / NVN | ❓ 未驗證 | 不用 | 曾卡在「載入中」（記憶體位址空間不夠），修正後需重新打包；記錄中有跑約 2 分半。 | — |
| Gang Beasts | `0100D58012E12000` | Unity 2021.3 / NVN | ❓ 未驗證 | 不用（暫定設定檔） | 已打包進遊戲庫，但 iPad 上沒有任何這款的記錄，可能從沒開過。 | — |
| ANIMAL WELL | `010020D01AD24000` | 自製引擎 / NVN | ❓ 未驗證 | repo 設定檔 | 早期交接文件列為可玩，目前的殼上沒有記錄。 | 早期 |
| PICO PARK 2 | `010035101E1CC000` | Unity 2022.3 / NVN | ❓ 未驗證 | 不用 | 早期列為可玩；記錄中有開過約 40 秒。 | 早期 |
| Puyo Puyo Tetris 2 | `010038E011940000` | NVN | ❓ 未驗證 | 不用 | 早期列為可玩，目前的殼上沒有記錄。 | 早期 |
| Boomerang Fu | `010081A00EE62000` | NVN | ❓ 未驗證 | repo 設定檔 | 早期列為可玩；打包器和殼版本不一致時 DLC 曾壞過。 | 早期 |
| Snipperclips Plus | `01008E20047DC000` | Unity 5.5 / NVN | ❓ 未驗證 | 不用 | 早期列為可玩；資料夾名稱有逗號的問題已修（`PR #34`）。 | 早期 |
| Unspottable | `0100B410138C0000` | Unity 2019.4 / NVN | ❓ 未驗證 | 不用 | 打包器加了 Unity 2019.4 格式（`PR #32`）。早期列為可玩；記錄中有開過約 40 秒。 | 早期 |
| Overcooked! All You Can Eat | `0100F28011892000` | Unity 2019.4 / NVN | ⛔ 上不了 iPad | — | 著色器約 52 萬個，打包後太大裝不上 iPad。另有工作在處理。 | — |
| Pummel Party | `01007BA01B9B2000` | Unity 2021.3 / NVN | ⛔ 上不了 iPad | — | 著色器約 27.6 萬個，同上。 | — |
| Mario Kart 8 Deluxe | `0100152000022000` | NVN | ⛔ 還沒試 | repo 設定檔（要 4.0.0） | 手上只有 1.0（v0）本體，要先放 4.0.0 更新檔。 | — |
| Super Smash Bros. Ultimate | `01006A800016E000` | NVN | ⛔ 還沒試 | repo 設定檔（要 13.0.5） | 手上是 13.0.4，要 13.0.5 更新檔。 | — |
| New Super Mario Bros. U Deluxe | `0100EA80032EA000` | — | ⛔ 不支援（待確認） | — | 之前的調查記為 32 位元（AArch32）程式，殼只支援 64 位元；還沒實際打包驗證。 | — |
| Overcooked 2 | — | — | — | — | 資料夾是空的，沒有遊戲檔。 | — |
| Mario Kart: Double Dash!! (recomp) | — | homebrew | ⛔ 不支援 | — | 264 KB 的 homebrew 啟動器，不是遊戲本體；打包器會直接說明。 | — |

## 共通注意事項

- **線上功能**：殼一律回答「沒有網路」，遊戲會改玩本機模式。Nintendo 帳號頭像、好友、線上對戰都不能用。
- **OpenGL / OpenGL ES 遊戲**（Balatro、Roof Rage）：第一次玩是錄著色器，畫面可能紫或不完整，iPad 接回電腦再按一次「裝到 iPad」才完整。
- **任天堂第一方大作**：建議裝 Apple「Metal Developer Tools for Windows」，打包時在電腦先編好著色器，iPad 上才不會卡頓。
- **改了殼或打包器之後**：舊的遊戲包不會自動重打，要在遊戲卡上按「🔁 下次更新時重新打包」。
- 遇到問題：在遊戲卡上按右鍵「📦 匯出問題回報」，會在 `Switch PAD\問題回報\` 產生 zip。

## 需要在 iPad 上確認的項目

依優先順序（每款開起來玩 3～5 分鐘，看能不能進到實際遊戲畫面、有沒有閃退）：

1. Toasterball：能不能進遊戲、存檔後不閃退
2. Ultimate Sheep Raccoon：能不能過開場進遊戲
3. Super Bunny Man：畫面是否完整（不是黑畫面）
4. Lethal League Blaze：能不能過「載入中」
5. Gang Beasts：第一次開，能不能玩
6. Stick Fight：選 LOCAL 後能不能開始一局
7. Roof Rage：連續玩 10 分鐘以上會不會自己跳出
8. Heave Ho：進關卡還會不會閃紫
9. ANIMAL WELL、PICO PARK 2、Puyo Puyo Tetris 2、Boomerang Fu（含 DLC 角色）、Snipperclips Plus、Unspottable：在目前的殼上重測一次
10. OddBallers：畫面上的細線還在不在
11. Tricky Towers：在目前的殼上重測一次

## 待辦（給維護者）

- **把電腦端專用修正收進 repo**：Tricky Towers、SUPER BOMBERMAN R 2、All You Need Is Help、Unrailed 2 的記憶體設定，以及 Heave Ho、Splatterbot 的 `patches.py`，目前只在使用者電腦上。要給別人用，得把它們放進 `dm/games/<Title ID>/`。
- 有新的測試結果時更新本表的「狀態」和「最後確認」欄。
