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

打完包**临时文件会自动删掉**：中途解出来的游戏、改写后的模块、拆出的着色器、拼装好的 app 树，加起来是游戏体积的好几倍  
（4 GB 的游戏会留下十几 GB），留着没用。只保留几 KB 的日志（`<title ID>_pack\logs\`），手机上有异常时看它。

想反复给同一个游戏重打包、省掉解包和翻译的时间，加 `--keep-work` 保留那棵工作树；想单独清掉之前留下的：

```bash
python scripts/nxn_pack.py --clean D:\games\hades2
```

## 环境要求

**打包机器**上需要：

| 需要什么        | 怎么弄                                                        |
| ----------- | ---------------------------------------------------------- |
| Python 3.9+ | `pip install lz4 capstone fonttools backports.zstd pillow` |
| 三个可执行文件     | 来自 `nxnative-windows-tools.zip`，用 `--tools` 指过去            |
| `prod.keys` | 从你自己的主机导出。**永远不离开你的机器**：它只作为参数传给 `nx_extract`，不会写进任何日志     |

不需要 .NET SDK、不需要 C++ 工具链、不需要 Mac。（想自己编工具也行：`dotnet publish dm/tools/nx_extract -r win-x64 --self-contained`，`dm/gfx/tools/dmsh_xlate` 同理；SPIRV-Cross 必须用 `vulkan-sdk-1.4.357.0` 这个 tag。）

## 文件名无所谓

打包器从 **NSP 内部的元数据**识别游戏——加密内容旁边的 `cnmt.xml` 是明文的，里面有 title ID、内容类型（本体／更新／DLC）  
和版本号。所以文件叫什么都行。

名字里的 `[XXXXXXXXXXXXX000]` 和 `[vN]` 只在文件**不含这种元数据**时才读：也就是 **XCI 卡带**（卡带没有元数据 XML）。  
如果你重命名 XCI，请保留 title ID。

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
