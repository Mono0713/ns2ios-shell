# 壳（shell）拆分方案

上游的常规路线在一台 Mac 上做完全部工作：`scripts/build_ipa_from_nsp.py` 改写游戏程序、翻译着色器、用苹果的 `metal`
编译器编译、再让 `xcodebuild` 链接出整个 app。没有 Mac 的用户这些一件都做不了。

这条路线把它拆成两半：

| | 在哪 | 做什么 |
|---|---|---|
| **1. 壳**（一次） | Mac 或 macOS CI runner | `dm/ios/tools/shell_build.sh` 编译出**完全不含游戏内容**的 app，产出几 MB 的构建原料 |
| **2. 打包**（每游戏） | Windows / Linux / macOS | `scripts/nxn_pack.py` 拿用户自己的 NSP 和 `prod.keys`，改写程序、翻译着色器、写进壳里，产出 IPA |

任何游戏内容都不会进入本仓库或 CI。壳是游戏无关的——这是最麻烦的地方，也是整件事的重点。

## 一个壳为什么能服务所有游戏

上游 nxnative 把游戏相关数据编进可执行文件，这样出来的壳只能对应编它的那个游戏。壳模式（`-DDM_SHELL`）把每一项都挪到运行期：

| 平时是编译进去的 | 壳模式下 |
|---|---|
| `gen_embed.py` 把改写后的模块映像编进 `__TEXT` / `__DM*W` 段（`host/loader.c`） | 从 `Frameworks/Guest.framework/Guest` 取——一个只装段的动态库，由 `dm/tools/guest_dylib.py` 用纯标准库写出，任何系统产出的字节都一致 |
| profile 的 `DM_GAME_MODULES`（`host/main.c:94`，只在 argv 没给模块名时使用） | 从 Guest 库的 `__dm<name>x0` 节名反推（`dm_shell_modules`），在 `main.m` 里追加进 `argv` |
| profile 的 `dmsh_chain.h` 里的 `DMSH_CHAIN` | 从 `msl/` 下唯一那个库目录名（`b-<版本>`）解析——链版本哈希了游戏的着色器表，每个游戏都不同 |
| `xcrun metal` 编出的 `.metallib` | 不以 `MTLB` 开头的文件按 MSL 源码处理，在设备上现编，之后由系统缓存 |
| 按 `romfs_marker` 定位 RomFS | 任何存在且非空的 RomFS 目录都接受 |
| profile 的内存布局（`mem_used`、`app_pool`、`mem_alias`…） | 启动时从环境变量读；打包器把游戏真实值写进 app 的 `dm/env.txt` |
| — | `dm/ios/Sources/dm_shader_prep.m`：首启把全部源码形态的着色器编一遍，带进度页 |

改写表和着色器表不用动：在 nxnative 里它们本来就是普通资源（`Gen/dm`，`ios/project.yml` 里是资源目录），运行时读取，
不是编进代码的数组。这也是为什么这个壳**构建时不需要游戏文件**，而 d2r-mobile 的 `shell_build.sh` 需要。

内存布局这一项不是显而易见的，花了真机一个来回：用占位 profile 的默认 `mem_used`（64 MB）而不是 Hades II 的 108 MB 时，
游戏按 `池 − 已用` 申请堆，多要了 44 MB，撑爆池子，在 `SetHeapSize` 里 abort。

## 构建

本机 Mac + Xcode 26：

```
bash dm/ios/tools/shell_build.sh
```

或者走 CI：**Build shell** workflow。手动触发用本分支的树；每日定时任务用上游最新提交 + 覆盖本分支的文件
（`.shell-overlay.txt`）。两者都会发布 release。构建末尾会核对 app 里没有 `romfs/`、`msl/`、`aoc/`、没有模块映像节、
`dm/font` 之外没有超过 8 MB 的文件。

## 状态

| 部分 | 状态 |
|---|---|
| 壳模式（`-DDM_SHELL`）与壳构建 | 可用，CI 以 release 形式发布 |
| `scripts/nxn_pack.py`（打包器） | Windows 上端到端可用 |
| 真机验证 | **已证明路线可行**：壳加载了 Guest 库、发现了模块、在手机上 4.3 秒编完 Hades II 的 140 个着色器；随后因内存布局在 `SetHeapSize` abort（已修，尚未在真机复测） |

## 在 Windows 上跑通实际要修的东西

下面每一条都是「只在 macOS 跑过」的代码：

| 文件 | 问题 |
|---|---|
| `dm/gfx/tools/shader_split.py` | `os.path.relpath` 返回反斜杠，记录的 RomFS 路径不再匹配 profile 的 `shader_groups`，所有着色器落进 `other`，拆出的表自校验失败 |
| `dm/gfx/tools/dmsh_mtlcache.py` | `ctypes.CDLL(None)` 只在 POSIX 表示当前进程，Windows 上 import 就抛 `TypeError` |
| `dm/gfx/tools/dmsh_chain.py` | 单文件发布的翻译器旁边没有 `.dll` 可算指纹；可执行文件叫 `dmsh_xlate.exe`；Windows checkout 的 CRLF 让内嵌源摘要与树里的不一致 |
| `dm/gfx/tools/nometal_run.py` | 三个 `xcrun` 探测未处理（移植版对不认识的调用直接抛错）；且它每个着色器删一个临时文件，被统计删除量的环境半路打断 |
| `dm/ios/tools/pack_ipa.py` | Windows 的 `os.stat` 没有 x 位，主程序被打成 0644，装上去起不来 |
| `dm/host/hle_svc.c` | 内存布局只有编译期常量，无游戏内容的壳提供不了 |

## 值得保留的自检

- `shell_build.sh` 若发现 app 里带 `romfs/`、`msl/`、`aoc/`、模块映像节，或 `dm/font` 之外有超过 8 MB 的文件，就拒绝发布。
- 打包器把 `ExeFS/main`、`sdk` 的 NSO build ID 与 profile 比对，并把拆出的着色器表与 profile 逐字节比对。版本不对时当场停下，
  而不是产出一个在手机上才炸的 IPA。
- 着色器完成度以 `dmsh_build.py` 的逐项结果为准，而不是「目录里有库文件」——否则被中断的运行会被误认为已完成。
