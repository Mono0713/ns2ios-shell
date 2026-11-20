# 遊戲支援表（Switch Pad + iPad 殼）

這張表記錄的是 **Switch Pad（Windows）打包、裝進 iPad「SwitchPad」遊戲庫** 這條路線上，每款遊戲在 iPad 實機上的結果。
它跟 [SUPPORTED.md](SUPPORTED.md) 不一樣：SUPPORTED.md 是上游 nxnative 有正式設定檔的清單（Mac 流程），這張表是我們自己在 iPad 上測的。

- 更新日期：2026-11-20（依使用者 11/20 的測試回報整理），遊戲庫 42 款，殼 = 測試殼 art57（`8f3f7d7`）系列。
- **只有使用者在 iPad 上親自玩過、並明確回報能玩的才標「可玩」**。電腦上打包成功、或記錄裡沒有閃退，都只算「未驗證」。
- 11/16～11/17 整個遊戲庫用新格式重轉過一次。標 ✅ 但日期在 11/16 以前的，是重轉前確認的，重轉後沒有再回報過問題。

## 狀態說明

| 標記 | 意思 |
|---|---|
| ✅ 可玩 | 使用者在 iPad 上確認能正常玩 |
| ⚠️ 能玩，有問題 | 能玩，但有已知問題（見備註） |
| ❌ 打不開 | 已在遊戲庫，但在 iPad 上閃退、卡住或畫面不對，修理中 |
| ❓ 未驗證 | 已在遊戲庫，但還沒有使用者在目前的殼上確認過 |
| ⛔ 不在遊戲庫 | 沒勾進遊戲庫，或目前打包不了、殼不支援 |

## 總覽（42 款在遊戲庫）

| 狀態 | 數量 | 遊戲 |
|---|---|---|
| ✅ 可玩 | 12 | SUPER BOMBERMAN R 2、All You Need Is Help、Splatterbot、Unrailed 2、Super Mario Bros. Wonder、Super Mario Odyssey、Super Mario 3D World、Unspottable、CloverPit、Balatro、Ultimate Chicken Horse、Tricky Towers |
| ⚠️ 能玩，有問題 | 8 | 卡比新世界、卡比星之同盟、薩爾達王國之淚、瑪利歐賽車 8 豪華版、Guilty Gear Strive、OddBallers、Roof Rage、Heave Ho |
| ❌ 打不開 | 9 | 世界遊戲大全 51、Minecraft Dungeons II、Rabbids Party of Legends、超級瑪利歐派對 空前盛會、Overcooked! All You Can Eat、Pummel Party、It Takes Two、超級瑪利歐銀河、超級瑪利歐銀河 2 |
| ❓ 未驗證 | 13 | 任天堂明星大亂鬥 特別版、Ember Knights、Toasterball、Ultimate Sheep Raccoon、Super Bunny Man、Lethal League Blaze、Gang Beasts、Stick Fight、ANIMAL WELL、PICO PARK 2、Puyo Puyo Tetris 2、Boomerang Fu、Snipperclips Plus |

## ❓ 未驗證：請在 iPad 上各玩 3～5 分鐘

依建議順序。每款看三件事：能不能進到實際遊戲畫面、畫面對不對、玩幾分鐘會不會閃退。

| 遊戲 | Title ID | 要看什麼 | 之前的狀況 |
|---|---|---|---|
| Super Smash Bros. Ultimate（大亂鬥） | `01006A800016E000` | 能不能進對戰；存檔（電腦版存檔 2）有沒有帶過去 | 11/17 帶 13.0.5 更新與 NRO 支援重打包，之後沒有回報。 |
| Ember Knights | `010017A01AAB8000` | 能不能進遊戲、DLC 有沒有出現 | 暫定設定檔，從沒回報過。 |
| Toasterball | `0100FE701A630000` | 能不能進遊戲、存檔後不閃退 | 存檔後閃退已修；記錄中跑過約 4 分半沒閃退。 |
| Ultimate Sheep Raccoon | `010095A0231E2000` | 能不能過開場進遊戲 | 開場中止已修；記錄中跑過約 3 分鐘。 |
| Super Bunny Man | `0100EF401D9D8000` | 畫面是否完整（不是黑畫面） | 記錄中跑過約 3 分鐘。 |
| Lethal League Blaze | `01003AB00983C000` | 能不能過「載入中」 | 曾卡在載入中，已修。 |
| Gang Beasts | `0100D58012E12000` | 第一次開，能不能玩 | iPad 上沒有任何這款的記錄，可能從沒開過。 |
| Stick Fight: The Game | `0100622009FB0000` | 選 LOCAL 後能不能開始一局 | 會出現「未登入」提示（正常，選 LOCAL）。 |
| ANIMAL WELL | `010020D01AD24000` | 能不能玩 | 早期列為可玩，重轉後沒測。 |
| PICO PARK 2 | `010035101E1CC000` | 能不能玩 | 早期列為可玩。 |
| Puyo Puyo Tetris 2 | `010038E011940000` | 能不能玩 | 早期列為可玩。 |
| Boomerang Fu | `010081A00EE62000` | 能不能玩、DLC 角色在不在 | 早期列為可玩。 |
| Snipperclips Plus | `01008E20047DC000` | 能不能玩 | 早期列為可玩。 |

## ❌ 打不開（修理中）

| 遊戲 | Title ID | 11/20 回報的狀況 | 處理 |
|---|---|---|---|
| Clubhouse Games: 51 Worldwide Classics（世界遊戲大全 51） | `010047700D540000` | 點啟動直接閃退 | 「修好閃退與打不開的遊戲」處理中 |
| Minecraft Dungeons II | `0100A7C01B792000` | 點啟動直接閃退 | 同上 |
| Rabbids Party of Legends | `01008970149B0000` | 一按開始就閃退 | 同上 |
| Super Mario Party Jamboree（空前盛會） | `0100965017338000` | 一按開始就閃退 | 同上 |
| Overcooked! All You Can Eat | `0100F28011892000` | 開頭警語畫面一出現就閃退 | 同上（只翻用到的著色器路線） |
| Pummel Party | `01007BA01B9B2000` | 開頭 loading 動畫一出現就閃退 | 同上 |
| It Takes Two | `010092A0172E4000` | 卡在「正在啟動遊戲」轉圈 | 同上（Unreal，ooz 解著色器） |
| Super Mario Galaxy（瑪利歐銀河） | `010099C022B96000` | 進遊戲畫面全紫色 | 11/17 已帶 iPad 錄到的 3,087 個著色器重打包，仍全紫；查 iPad 記錄中 |
| Super Mario Galaxy 2（瑪利歐銀河 2） | `0100FD8022DAA000` | 進遊戲畫面全紫色 | 同上（3,795 個著色器） |

## ⚠️ 能玩，有問題

| 遊戲 | Title ID | 問題 | 處理 |
|---|---|---|---|
| Kirby and the Forgotten Land（卡比新世界） | `01004D300C5AE000` | 貼圖閃爍，跟以前的奧德賽一樣 | 套用奧德賽的修法（設定檔 `ub_defer off`），要重新打包 |
| Kirby Star Allies（卡比星之同盟） | `01007E3006DDA000` | 貼圖不自然閃爍抖動 | 同上 |
| The Legend of Zelda: Tears of the Kingdom（王國之淚） | `0100F2C0115B6000` | 認真玩一陣子偶爾有瞬間卡頓 | 查 iPad 記錄看是著色器第一次建立、讀檔還是 GPU 太滿 |
| Mario Kart 8 Deluxe（瑪利歐賽車 8） | `0100152000022000` | 單人可玩（手機方向盤可用）；本地多人進角色選擇就卡死 | 「修好閃退與打不開的遊戲」處理中 |
| Guilty Gear Strive | `0100AB401F136000` | 遊戲存檔不完整 | 同上 |
| OddBallers | `010079A015976000` | 畫面上有細線（11/01 舊殼） | 未追查，重轉後請再看一次 |
| Roof Rage | `010088100DD42000` | 玩一陣子會自己跳出（11/06） | 未追查，重轉後請再看一次 |
| Heave Ho | `0100ADD00E17E000` | 進關卡時閃紫（10/31） | 未確認是否還有，重轉後請再看一次 |

## ✅ 可玩

| 遊戲 | Title ID | 備註 | 最後確認 |
|---|---|---|---|
| Unspottable | `0100B410138C0000` | 掌機模式 15 FPS 已修（拿掉 iPad 全域設定裡給奧德賽的一行） | 2026-11-16 |
| Super Mario Odyssey | `0100000000010000` | 閃白、硬邊煙霧已修（設定檔 `ub_defer off`） | 2026-11-14 |
| SUPER BOMBERMAN R 2 | `0100B87017D94000` | | 2026-11-14 |
| All You Need Is Help | `010072F01DC94000` | 離線模式；讀不到玩家頭像 | 2026-11-14 |
| Splatterbot | `0100E4B0223AC000` | | 2026-11-14 |
| Unrailed 2: Back on Track | `010593A5182E4000` | | 2026-11-14 |
| Super Mario Bros. Wonder | `010015100B514000` | | 2026-11-08 |
| Super Mario 3D World + Bowser's Fury | `010028600EBDA000` | 電腦預先編譯著色器後順暢 | 2026-11-08 |
| CloverPit | `0100ABA02501A000` | | 2026-11-07 |
| Balatro | `0100CD801CE5E000` | OpenGL：第一次玩先錄著色器 | 2026-11-07 |
| Ultimate Chicken Horse | `0100FCF002A58000` | 開場閃紫已修 | 2026-11-07 |
| Tricky Towers | `010015F005C8E000` | | 2026-10-30（舊殼） |

## ⛔ 不在遊戲庫

| 遊戲 | Title ID | 狀況 |
|---|---|---|
| New Super Mario Bros. U Deluxe | `0100EA80032EA000` | 32 位元（殼只能跑 64 位元的 Switch 遊戲）。2026-11-20 帶 1.0.2 更新檔重驗：更新檔沒有換掉主程式（main／sdk 跟 1.0.0 完全相同），main.npdm 仍標 32 位元。iPad 不可行，替代方案是電腦 Ryujinx＋串流。 |
| Moving Out 2 | `010065D018172000` | 打包失敗已修（11/17），還沒勾進遊戲庫。 |
| The Legend of Zelda: Breath of the Wild | `01007EF00011E000` | 有設定檔，還沒勾進遊戲庫。 |
| Nintendo Switch Sports Resort | `04008E001F098000` | Switch 2 遊戲，要先完整同步上游 nxnative。 |

## 共通注意事項

- **線上功能**：殼一律回答「沒有網路」，遊戲會改玩本機模式。
- **OpenGL / 執行時才產生著色器的遊戲**（Balatro、Roof Rage、Unrailed 2、瑪利歐銀河 1、2）：第一次玩是錄著色器，畫面可能紫或不完整，iPad 接回電腦再同步一次才完整。
- **改了殼或打包器之後**：舊的遊戲包不會自動重打，要在遊戲卡上按「🔁 下次更新時重新打包」。
- 遇到問題：在遊戲卡上按右鍵「📦 匯出問題回報」，會在 `Switch PAD\問題回報\` 產生 zip。

## 待辦（給維護者）

- **把電腦端專用修正收進 repo**：Tricky Towers、SUPER BOMBERMAN R 2、All You Need Is Help、Unrailed 2 的記憶體設定，以及 Heave Ho、Splatterbot 的 `patches.py`，目前只在使用者電腦上。
- 有新的測試結果時更新本表的狀態和日期。
