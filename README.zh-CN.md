# nxnative shell —— 不需要 Mac 就能出包

在 iPhone / iPad 上玩你自己的 Switch 游戏。这是 [nxnative](https://github.com/seedds/nxnative) 的一个分支，把构建拆成两半：  
只在真正需要 Mac 的那一半在 CI 上做**一次**，而所有需要你游戏文件的操作都在**你自己机器上**完成——Windows、Linux 或  
macOS 皆可，不需要 Xcode。

|           | 在哪做        | 做什么                                                         |
| --------- | ---------- | ----------------------------------------------------------- |
| **1. 壳**  | CI 构建，下载一次 | 几 MB 的未签名 iOS 应用，**完全不含游戏内容**                               |
| **2. 打包** | 你的机器       | `scripts/nxn_pack.py` 拿你的 NSP 和 `prod.keys`，改写程序、翻译着色器、写进壳里 |

壳是**游戏无关**的：一个壳服务支持列表里的任何游戏。任何游戏文件都不会进入这个仓库或 CI。

> English documentation: [README.md](README.md)
>
> 上游项目及其原始文档（Mac 路线）：**[seedds/nxnative](https://github.com/seedds/nxnative#readme)**。

## 快速开始（Windows）

**需要四样东西：**

| 要什么 | 从哪来 | 放哪 |
|---|---|---|
| **仓库（必须完整）** | `git clone https://github.com/xinerqu/ns2ios-shell`，或 Releases 页面的源码压缩包 | 任意位置，例 `D:\nxn` |
| **壳** | Releases 页面的 `shell-<日期>-<提交>.zip` | 例 `D:\nxn\shell.zip` |
| **三个可执行文件** | Releases 页面的 `nxnative-windows-tools.zip`（自包含，不需要 .NET SDK） | 解压到例 `D:\nxn-tools` |
| **你的游戏文件 + `prod.keys`** | 你自己的机器 | 例 `D:\games\hades2\` |

> **为什么仓库必须完整，不能只拷 `nxn_pack.py`？**
> 脚本只是入口，真正的活靠仓库里的 `dm/`：每个游戏的支持参数（模块列表、内存布局、改写表、着色器表）在
> `dm/games/<title ID>/`，改写器和着色器工具在 `dm/tools/`、`dm/gfx/tools/`。缺了 `dm/` 它会当场说清楚，不会跑一半才崩。
> 想把它和 `dm/` 平铺在一个目录里也行，脚本两种布局都认。

**支持哪些游戏**：见 [docs/SUPPORTED.md](docs/SUPPORTED.md)——每一款都列出 title ID 和已验证版本，拿你文件名里的那一串十六进制对上即可。

**1. 装依赖**（装给**你将要用的那个** Python —— 打包器用哪个解释器，包装进哪个）：

```bash
python -m pip install lz4 capstone fonttools backports.zstd pillow
```

**2. 把一个游戏的文件放进一个目录。** 文件名随便，游戏是从**包内容**里认出来的（见下文「文件名无所谓」）：

```
D:\games\hades2\
  Hades II.nsp          ← 或者 .xci，名字随意
  (可选) 更新包.nsp      ← 同目录，会打包里面最新的版本
```

**3. 在仓库目录里运行：**

```bash
cd D:\nxn
python scripts\nxn_pack.py shell.zip D:\games\hades2 ^
    -k D:\keys\prod.keys --tools D:\nxn-tools
```

IPA 默认写在游戏文件旁边（`-o` 可指定）。过程会解开游戏、改写程序、翻译着色器、拼装 app、压成 IPA，进度和耗时都会打印。

**4. 侧载**（SideStore、Sideloadly、LiveContainer 都行）。**首次启动会编译一遍着色器**，屏幕上有进度页，会告诉你还要多久。

### 打完包之后

临时文件会**自动删掉**：中途解出来的游戏、改写后的模块、拆出的着色器、拼装好的 app 树，加起来是游戏体积的好几倍
（4 GB 的游戏会留下十几 GB），留着没用。只保留几 KB 的日志（`<title ID>_pack\logs\`），手机上有异常时看它。

- 反复给同一个游戏重打包、省掉解包和翻译的时间：加 `--keep-work`
- 单独清掉之前留下的：`python scripts\nxn_pack.py --clean D:\games\hades2`
- 卡带转储（`.xci`）第一次打包后会生成 `你的文件.xci.tid`，记住它是什么游戏，下次不用再解一遍

## 环境要求

**打包机器**上需要：

| 需要什么 | 怎么弄 |
|---|---|
| 完整仓库 | `git clone` 或源码压缩包——**必须有 `dm/`**，见上面的说明 |
| Python 3.9+ | `python -m pip install lz4 capstone fonttools backports.zstd pillow`。装给**运行打包器的那一个**解释器 |
| 三个可执行文件 | 来自 `nxnative-windows-tools.zip`，用 `--tools` 指过去 |
| `prod.keys` | 从你自己的主机导出。**永远不离开你的机器**：它只作为参数传给 `nx_extract`，不会写进任何日志 |

不需要 .NET SDK、不需要 C++ 工具链、不需要 Mac。（想自己编工具也行：`dotnet publish dm/tools/nx_extract -r win-x64 --self-contained`，`dm/gfx/tools/dmsh_xlate` 同理；SPIRV-Cross 必须用 `vulkan-sdk-1.4.357.0` 这个 tag。）

**关于 Python**：机器上可能装了不止一个 Python，`pip install` 装到哪个、`nxn_pack.py` 用哪个，必须是同一个。
最省事的写法是用同一个解释器跑两件事：

```
C:\path\to\python.exe -m pip install lz4 capstone fonttools backports.zstd pillow
C:\path\to\python.exe scripts\nxn_pack.py ...
```

打包器开跑前会自己检查这五个包，缺了会列出该执行的命令，不会跑到一半才失败。

## 文件名无所谓

打包器从 **NSP 内部的元数据**识别游戏——加密内容旁边的 `cnmt.xml` 是明文的，里面有 title ID、内容类型（本体／更新／DLC）  
和版本号。所以文件叫什么都行。

名字里的 `[XXXXXXXXXXXXX000]` 和 `[vN]` 只在文件**不含这种元数据**时才读。**XCI 卡带**里既没有 ticket，NCA 头也是
加密的（密钥在它自己的 key area 里），所以打包器第一次会先解包一遍、从解包结果里认出 title ID，并把结果记在
`<文件>.xci.tid`；之后重打包直接读这个文件，不再解一遍。

支持格式：**NSP**（本体、更新、DLC）和 **XCI**（只能当本体）。**不支持 NSZ**：先用 `nsz -D "文件.nsz"` 解压。

## 哪些游戏能打、哪个版本能打

[`dm/games/`](dm/games/) 下有 profile 的游戏都支持。**任意版本都行**，带不带更新都可以：打包器取文件夹里**最新的那个  
版本**（也可以用 `-p vN` 指定），并用该版本自己的着色器来构建。上游每款游戏只在一个版本上验证过；换成别的版本时 app  
会说明这一点，而为已验证版本做的修复（比如 60fps）不适用于它。

更新包是可选的——只有本体也能打。文件夹里的 DLC 会被一并打进去；没有 DLC 时游戏就看不到 DLC，和在没插 DLC 的 Switch  
上一样。

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
- **内存上限大约 3.4 GB，壳里已经请求了提高它的权限。** 没有 `increased-memory-limit` 这个 entitlement 时，iOS 只给
  应用约 3,375 MB；被模拟的游戏自己就要 3,285 MiB，所以大作很容易贴到墙上——**超了是被系统杀掉，不是崩溃，日志里看不到
  crash**。壳在构建时用 ad-hoc 占位签名把这个 entitlement 写进了 `DmIOS` 的签名里（没有签名的话，侧载工具无处可读，
  请求会丢失），重签时是否保留取决于工具：

  | 安装方式 | 是否保留 |
  |---|---|
  | AltStore Classic 2.2+、Impactor、Xcode + 个人团队 | 保留 |
  | LiveContainer | 保留（2026-10-23 实测：iPhone 16 Pro Max 上 `6140 MB`） |
  | SideStore + 免费 Apple ID | 保留，但需要对 App ID 做一次性修正（见下） |
  | Sideloadly | 不保留（等于没加，游戏仍在 3.4 GB 上限下跑） |

  **SideStore + 免费 Apple ID 怎么修**（一次性，之后每周刷新都保留）：免费账号本来就能拿到这个能力，但 SideStore 的
  旧构建不把它写进 App ID（[SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)），装上过程是静默的——
  不报错，只是内存还是 3.3 GB。修一次即可：

  1. 先照常用 SideStore 装上这个 IPA（App ID 此时已注册到你的账号下，entitlement 尚未生效）；
  2. 用同一个 SideStore、**同一个 Apple ID** 装上 [GetMoreRam](https://github.com/hugeBlack/GetMoreRam)，打开后
     Settings 登录（要过二次验证），进 App IDs → Refresh，找到 `org.nxnative.<title ID>`，点
     **Add Increased Memory Limit**。只加这一个：Extended Virtual Addressing 是付费账号专属，壳也不需要。
     列表里找不到这个 App ID，先查 Apple ID 是否登的一致；
  3. 回 SideStore 重装一次这个 IPA——**直接覆盖安装，不要先删**（删了会丢存档）。新描述文件里就带这个 entitlement 了。

  另一个办法是换用带 [SideSign PR #4](https://github.com/SideStore/SideSign/pull/4)（2026-10-05）修复的 SideStore
  新构建，装上即生效，不用手动修。嫌麻烦也可以直接用 AltStore Classic 2.2+ 或 LiveContainer，它们无条件保留。

  判断是否生效：看 `Documents/log.txt` 的启动行 `boot: memory limit N MB`——约 3,375 MB 表示没生效，6–8 GB 表示生效。
  **任何游戏都能看出来**，不需要拿大作试：这一行说的是进程能拿多少内存，跟游戏要用多少无关。游戏跑起来之后，
  `[nvn-mtl] memory up to frame N ... headroom to the system memory limit` 那行还会持续报剩余额度。
- **每个游戏是独立的应用，可以同时装多个。** bundle ID 由 title ID 生成（`org.nxnative.<title ID>`），所以第二个游戏
  装上不会顶掉第一个，存档也各自独立。同一个游戏重打包则是覆盖升级（存档保留）。
  早于这个改动打出来的包仍是壳的 `org.nxnative.shell`，会和别的游戏冲突——重打一次即可，旧的记得手动删掉。
- **壳和打包器要配套。** 用同一个 release 里的壳，别拿以前留着的旧 zip。旧壳可能不认识新打包器写进去的东西  
  （典型症状：手机上启动就崩，日志写 `unknown gate kind spin`）。现在的打包器会先读壳自带的 `dm/shell_info.txt`，  
  在打包时就拦下来并告诉你该怎么办，而不是等装到手机上才发现。
- **首次启动比较久**：手机要把所有着色器编译一遍。Hades II 的 140 个约 5 秒；大作要几分钟（进度页会估算）。结果由系统缓存，  
  之后启动就是秒开。
- 想在真机上临时改参数而不重新打包，把 `KEY=VALUE` 写进应用的 `Documents/env.txt` 即可。
- 崩溃时宿主会写 `Documents/log.txt`，绝大多数情况那个文件会直接说明原因。
- 打包需要 **约 NSP 两倍大小的磁盘空间**：解包出的 RomFS、组装中的 app 和最终 IPA 会同时存在。打完包临时文件自动删掉  
  （见上文的 `--keep-work` / `--clean`）。

## 仓库结构

只有前两项是**打包时必须存在**的，其余是它们依赖的、和构建壳用的部分。

```
scripts/nxn_pack.py              打个包的入口；必须在仓库里，旁边要有 dm/
dm/                              打包时的全部依赖，缺了跑不了：
dm/games/<title ID>/             每个游戏的支持参数（模块、内存布局、改写表、着色器表）
dm/tools/                        改写器（patch_nso.py）、guest_dylib.py、nacp.py
dm/gfx/tools/                    着色器链（shader_split、dmsh_build、nometal_run…）
dm/host/ dm/ios/                 宿主与 iOS 应用源码（构建壳用）
dm/ios/tools/shell_build.sh      构建壳（CI 上用，需要 macOS 26 SDK）
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

**内存上限**这一块来自 **LNPANDY** 的 **[nxnative-romfs-archive](https://github.com/LNPANDY/nxnative-romfs-archive)**（MIT）：
`com.apple.developer.kernel.increased-memory-limit` 要嵌进「占位」的 ad-hoc 签名里——未签名的二进制没有签名可供侧载工具
读取，光在工程里声明是不会生效的；无该权限时 iOS 只给约 3,375 MB、《王国之泪》在常驻 3,342 MB 时被杀、以及各家侧载工具
是否保留这个权限，也都是他实测并写下来的。壳的构建时签名（`dm/ios/DmIOS.entitlements` + `shell_build.sh`）是按这个思路
自己实现的，代码没有拷贝。

`nx_extract` 使用 **[LibHac](https://github.com/Thealexbarney/LibHac)**；着色器翻译器内嵌了 Ryujinx 的着色器库；着色器由  
**[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)** 翻译。

**许可：MIT**，与上游一致。[LICENSE](LICENSE) 是上游自己的文件，其中保留的是原始版权声明（© 2026 jhaizhou——nxnative 从  
d2r-mobile 的通用部分起步，因此沿用了它的署名）。转载本分支或其构建产物时，请保留该声明与本许可。MIT 只覆盖代码：游戏文件、  
密钥以及你打出来的 IPA 由你自己负责，不在许可范围内。
