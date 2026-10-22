# nxnative shell —— 不需要 Mac 就能出包

在 iPhone / iPad 上玩你自己的 Switch 游戏。这是 [nxnative](https://github.com/seedds/nxnative) 的一个分支，把构建拆成两半：
只在真正需要 Mac 的那一半在 CI 上做**一次**，而所有需要你游戏文件的操作都在**你自己机器上**完成——Windows、Linux 或
macOS 皆可，不需要 Xcode。

| | 在哪做 | 做什么 |
|---|---|---|
| **1. 壳** | CI 构建，下载一次 | 几 MB 的未签名 iOS 应用，**完全不含游戏内容** |
| **2. 打包** | 你的机器 | `scripts/nxn_pack.py` 拿你的 NSP 和 `prod.keys`，改写程序、翻译着色器、写进壳里 |

壳是**游戏无关**的：一个壳服务支持列表里的任何游戏。任何游戏文件都不会进入这个仓库或 CI。

> English documentation: [README.md](README.md)
>
> 上游项目及其原始文档（Mac 路线）：**[seedds/nxnative](https://github.com/seedds/nxnative#readme)**。
> 分叉当时的 README 快照保留在 [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md)。

## 快速开始（Windows）

**1. 下载两个文件**（到 [Releases](../../releases) 页面）：

- `shell-<日期>-<提交>-shell.zip` —— 壳
- `nxnative-windows-tools.zip` —— `nx_extract.exe`、`dmsh_xlate.exe`、`spirv-cross.exe`（自包含，不需要 .NET SDK）

把工具解压到任意位置，例如 `D:\nxn-tools`。

**2. 把一个游戏的文件放进一个目录。** 文件名必须带 title ID 和版本号：

```
D:\games\hades2\
  Hades II [0100A00019DE0000][v0].nsp
```

**3. 运行：**

```bash
python scripts/nxn_pack.py shell-<日期>-<提交>-shell.zip D:\games\hades2 ^
    -k D:\keys\prod.keys --tools D:\nxn-tools
```

**4. 侧载**它生成在你 NSP 旁边的 IPA（SideStore、Sideloadly、LiveContainer 都行）。**首次启动会编译一遍着色器**，屏幕上
有进度页，会告诉你还要多久。

## 环境要求

**打包机器**上需要：

| 需要什么 | 怎么弄 |
|---|---|
| Python 3.9+ | `pip install lz4 capstone fonttools backports.zstd pillow` |
| 三个可执行文件 | 来自 `nxnative-windows-tools.zip`，用 `--tools` 指过去 |
| `prod.keys` | 从你自己的主机导出。**永远不离开你的机器**：它只作为参数传给 `nx_extract`，不会写进任何日志 |

不需要 .NET SDK、不需要 C++ 工具链、不需要 Mac。（想自己编工具也行：`dotnet publish dm/tools/nx_extract -r win-x64
--self-contained`，`dm/gfx/tools/dmsh_xlate` 同理；SPIRV-Cross 必须用 `vulkan-sdk-1.4.357.0` 这个 tag。）

## 文件命名——必读

打包器**从文件名取 title ID 和版本号**：

```
Hades II [0100A00019DE0000][v0].nsp
         └─ title ID ─┘ └版本┘
```

- 缺 title ID → 该文件被跳过并给出警告。
- **随后有两道内容校验**，确认它确实是那个版本：`ExeFS/main` 与 `sdk` 里的 NSO build ID 会和 profile 比对；从你的文件里
  重新拆出的着色器表必须和 profile **逐字节一致**。文件名写错或版本不对时，构建会直接停下，而不是产出一个坏包。

支持的格式：**NSP**（本体、更新、DLC）和 **XCI**（卡带 dump，只能当本体）。**不支持 NSZ**：先用 `nsz -D "文件.nsz"` 解压。

## 哪些游戏能打

[`dm/games/`](dm/games/) 下有 profile 的游戏都支持；profile 同时记录了**必须存在哪些版本**。有些游戏需要本体**和**更新包：

| 情况 | 例子 |
|---|---|
| 只要本体 | Hades II `0100A00019DE0000`、Brain Memory Training Academy、Rhythm Heaven Groove、The Great Ace Attorney Chronicles |
| 本体 + 特定更新 | 马里奥惊奇要 `v0` **和** `v327680`（1.2.1）；奥德赛要 `v393216` |

`dm/games/<title ID>/game.tsv` 里的 `shader_versions` 就是版本要求。缺版本时打包器会直接说明，并告诉你需要哪个文件。

已知有两款还需要额外条件：**火焰纹章 风花雪月**（GLSL 着色器）和**超级马里奥银河**（Vulkan）——它们的着色器是运行时
生成的，光靠文件拆不出来。

## 原理

```
CI（一次）         你的机器                           iPhone
─────────          ──────────────────────────────    ────────────────────
shell_build.sh ──► nxn_pack.py
  宿主程序            ├ 解包 NSP        (nx_extract)
  无游戏内容          ├ 改写程序        (patch_nso.py)
  无着色器            ├ 拆着色器        (shader_split.py)
  无 RomFS            ├ 译成 MSL 源码   (dmsh_xlate, spirv-cross)  ──► IPA ──► 侧载
                     ├ 写 Guest.framework (guest_dylib.py)                │
                     └ 组装 + 打 IPA   (pack_ipa.py)                      ▼
                                                                    首次启动：
                                                                    编译着色器
```

让一个壳通吃所有游戏的关键，是把两件事从编译期挪到运行期：

- **模块列表**从 `Frameworks/Guest.framework` 的 `__dm<name>x0` 节名反推（游戏程序是一个只装段的动态库，不再编进主程序）；
- **着色器链版本**从 `msl/b-<版本>` 目录名读取。

壳还是用中性占位 profile 编的，所以游戏的内存布局（`mem_used`、`app_pool` 等）由打包器写进应用的 `dm/env.txt`，宿主启动时读取。

## 注意事项

- **IPA 里含你的游戏文件。** 仅供自己使用，不要分发。
- **首次启动比较久**：手机要把所有着色器编译一遍。Hades II 的 140 个约 5 秒；大作要几分钟（进度页会估算）。结果由系统缓存，
  之后启动就是秒开。
- 想在真机上临时改参数而不重新打包，把 `KEY=VALUE` 写进应用的 `Documents/env.txt` 即可。
- 崩溃时宿主会写 `Documents/log.txt`，绝大多数情况那个文件会直接说明原因。
- 打包需要 **约 NSP 两倍大小的磁盘空间**：解包出的 RomFS、组装中的 app 和最终 IPA 会同时存在。

## 仓库结构

```
dm/ios/tools/shell_build.sh      构建壳（CI 上用，需要 macOS 26 SDK）
scripts/nxn_pack.py              把壳和你的游戏文件打成 IPA（任意系统）
dm/tools/guest_dylib.py          把改写后的模块写成 Frameworks/Guest.framework
dm/gfx/tools/nometal_run.py      在没有苹果 metal 编译器的情况下跑着色器链
dm/ios/Sources/dm_shader_prep.m  首启编译着色器的进度页
dm/games/0000000000000000/       壳编译时用的中性 profile
.shell-overlay.txt               本分支相对上游新增/修改的文件清单
docs/SHELL.md                    拆分的详细说明
```

## 致谢与许可

本仓库是 **seedds** 的 **[nxnative](https://github.com/seedds/nxnative)** 的分支，绝大部分实质工作来自上游：改写器、
翻译链、宿主、游戏 profile 以及那三十来个经过真机验证的标题，都是上游的成果。

这套「原生执行」方案本身来自 **jhaizhou-ops** 的 **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT），是为
《暗黑破坏神 II：重制版》做出来的。上游 nxnative（最初叫 smbw-mobile）就是从它的通用部分起步——NSO 改写器、Horizon 宿主、
NVN-on-Metal 层和 iOS app 外壳——两个项目之间的修复是**双向**的。它们是**两个独立项目、两位不同作者**，各自对应各自的游戏。

本分支的「壳」路线沿用 d2r-mobile 的 `shell_build.sh` 做法；`guest_dylib.py`、`nometal_run.py`、`dm_shader_prep.m`、
`shell_build.sh` 是从那里移植的。

`nx_extract` 使用 **[LibHac](https://github.com/Thealexbarney/LibHac)**；着色器翻译器内嵌了 Ryujinx 的着色器库；着色器由
**[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)** 翻译。

**许可：MIT**，与上游一致。[LICENSE](LICENSE) 是上游自己的文件，其中保留的是原始版权声明（© 2026 jhaizhou——nxnative 从
d2r-mobile 的通用部分起步，因此沿用了它的署名）。转载本分支或其构建产物时，请保留该声明与本许可。MIT 只覆盖代码：游戏文件、
密钥以及你打出来的 IPA 由你自己负责，不在许可范围内。
