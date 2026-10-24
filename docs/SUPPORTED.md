# Supported games / 支持的游戏

Generated from `dm/games/*/game.tsv` by `dm/tools/supported_list.py` — do not edit by hand.  
本页由 `dm/tools/supported_list.py` 从 `dm/games/*/game.tsv` 生成，请勿手动修改。

**51 款游戏。** 文件名不重要——打包器从包内容识别游戏，在下表里对上 title ID 就够了。

- **IPA 体积** ≈ 你的 NSP/XCI 体积 + 约 16 MB（壳本身）。游戏文件在包里是原样存放的，不再压缩。
- **首次启动**要编译着色器：打包时只把 Switch 的着色器翻译成 Metal 源码，编译在手机上做（之后有缓存）。几秒到大作几分钟，启动时有进度页。
- **内存**：iOS 给不带 entitlement 的应用约 3.4 GB；本项目的壳在构建时已请求提高上限，侧载工具保留该权限后可用到 6–8 GB。
- 表内是本仓库带参数、并且打包器跟随其快照验证过的游戏。**不在表内**的游戏，打包器会尝试从上游取它的参数并尽力打包（未经本仓库验证，可能跑不起来），不会产出半成品 IPA。

| 游戏 | Title ID | 已验证版本 | 特性 |
|---|---|---|---|
| 13 Sentinels: Aegis Rim | `01003FC01670C000` | 1.10 |  |
| Absolum | `0100A83022A22000` | 1.1.1 |  |
| Ace Attorney Investigations Collection | `010005501E68C000` | 1.0.0.2 |  |
| AI: THE SOMNIUM FILES | `010089B00D09C000` | 1.0.1 |  |
| AI: THE SOMNIUM FILES - nirvanA Initiative | `0100713016CCC000` | 1.0.2 |  |
| Animal Crossing: New Horizons | `01006F8002326000` | 3.0.3 |  |
| ANIMAL WELL | `010020D01AD24000` | 1.0.10 |  |
| Balatro | `0100CD801CE5E000` | 1.1.3 | handheld |
| Big Brain Academy: Brain vs. Brain | `0100620012D6E000` | 1.2.0 | handheld |
| Brain Memory Training Academy | `0100F5D01DA3A000` | 1.0.0 |  |
| Captain Toad: Treasure Tracker | `01009BF0072D4000` | 1.4.2 | handheld |
| Catherine: Full Body | `0100BF00112C0000` | 1.0.1a |  |
| Celeste | `01002B30028F6000` | 1.4.1.1 |  |
| Cuphead | `0100A5C00D162000` | 1.3.7 |  |
| DARK SOULS: REMASTERED | `01004AB00A260000` | 1.0.3 |  |
| Digimon Story Cyber Sleuth: Complete Edition | `010014E00DB56000` | 1.0.3 |  |
| DRAGON QUEST VII Reimagined | `0100A9D01C446000` | 1.2.0 | 60 fps |
| DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition | `01006C300E9F0000` | 1.0.4 | 60 fps |
| FINAL FANTASY RESONANCE | `0100606026F12000` | 1.0.1 | 60 fps |
| FINAL FANTASY TACTICS - The Ivalice Chronicles | `010038B015560000` | 1.4.0 |  |
| Fire Emblem Engage | `0100A6301214E000` | 2.0.0 |  |
| Fire Emblem: Three Houses | `010055D009F78000` | 1.2.0 |  |
| Hades | `0100535012974000` | 1.0.38233 |  |
| Hades II | `0100A00019DE0000` | 0.0.126424 |  |
| Hollow Knight: Silksong | `010013C00E930000` | 1.0.30000 |  |
| Hyrule Warriors: Age of Calamity | `01002B00111A2000` | 1.3.0 | 60 fps |
| Luigi's Mansion 3 | `0100DCA0064A6000` | 1.4.0 | 60 fps |
| Mario Kart 8 Deluxe | `0100152000022000` | 4.0.0 |  |
| Metroid Dread | `010093801237C000` | 2.1.0 |  |
| Monster Hunter Rise | `0100B04011742000` | 16.0.2 | 60 fps |
| Monster Train 2 | `010051701FB46000` | 1.1.1 |  |
| OCTOPATH TRAVELER 0 | `01005270232F2000` | 1.0.5 | 60 fps |
| Paper Mario: The Thousand-Year Door | `0100ECD018EBE000` | 1.0.1 | 60 fps |
| Patrick's Parabox | `0100E44016C22000` | 1.0.1 |  |
| Pokémon Legends: Z-A | `0100F43008C44000` | 2.0.2 |  |
| Raging Loop | `010020400E1C2000` | 1.0.0 |  |
| Rhythm Heaven Groove | `0100D9F01D474000` | 1.0.0 | handheld |
| ROMANCE OF THE THREE KINGDOMS 8 REMAKE | `0100C2A01A730000` | 1.1.3 |  |
| STEINS;GATE RE:BOOT | `01008BC024FDE000` | 1.0.3 |  |
| Super Mario 3D World + Bowser's Fury | `010028600EBDA000` | 1.2.2 |  |
| Super Mario Bros. Wonder | `010015100B514000` | 1.2.1（也可 1.0.0） |  |
| Super Mario Galaxy | `010099C022B96000` | 1.3.1 | handheld |
| Super Mario Galaxy 2 | `0100FD8022DAA000` | 1.4.0 | handheld |
| Super Mario Odyssey | `0100000000010000` | 1.4.1 |  |
| Super Smash Bros. Ultimate | `01006A800016E000` | 13.0.5 |  |
| Taiko Risshiden V DX | `0100346017304000` | 1.1.1 | handheld |
| The Great Ace Attorney Chronicles | `010036E00FB20000` | 1.0.0 |  |
| The Legend of Zelda: Breath of the Wild | `01007EF00011E000` | 1.9.0 | 60 fps |
| The Legend of Zelda: Link's Awakening | `01006BB00C6F0000` | 1.1.0 |  |
| The Legend of Zelda: Tears of the Kingdom | `0100F2C0115B6000` | 1.4.3 | 60 fps |
| Unicorn Overlord | `010069401ADB8000` | 1.05 |  |
