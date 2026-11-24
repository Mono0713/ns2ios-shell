# Minecraft Dungeons II (`0100A7C01B792000`)

Update 1.1.3.0, main build `c6b32f4d3d4243ff190b082b4f6aea18`. Unreal Engine.

## Startup

- An iPad breakpoint at the C++ throw inside `main+0x7063d2c` identified `HCGlobalInitialize` as the XAL failure. Its provider called `nn::ssl::Context::Create` at `main+0x7035a1c` to create a settings context before network activity. The offline hook returned `0x2a2`; the library translated it into `0x80004005`.
- The [offline SSL context](../../../docs/reference/services.md#local-ssl-contexts-during-offline-startup) keeps the configuration context's lifecycle in the host, scoped to this main build. This leaves the SDK's service pointer empty and connection operations offline.
- An iPad debugger run applied the local context result to the installed build. XalInitialize returned success and both movie decoders stopped normally. The game then waited for a flip in `FFrameEndSync` (`main+0x1501228` and `+0x150194c`). The log showed `ListFrameHistory` returning zero and the game polls it in the viewport thread (`main+0x142b034` and `+0x142b094`). The host now reports [layer frame history](../../../docs/reference/services.md#layer-frame-history).
- Returning records derived from the installed app's present queue in the debugger moved the game past the blocked frame 174. It reached the first-run brightness screen and continued beyond frame 2,400 after the debugger detached. The player confirmed normal operation after detach. This validated the two failure paths on-device. The player subsequently confirmed an integrated cold launch and playable gameplay on iPad build 2026.1124.1320.

## Frame rate and stutter

- This game's rhi.SyncInterval CVar points to separate game- and render-thread values through the cell at main+0xac96a20. Its built-in value is 2. The installed iPad build set the shell target to 60, but the game requested two display ticks per frame. The FPS lock updates both CVar copies for this exact executable build.
- In the iPad gameplay sample, the median frame was 33.5 ms, and 42 pipeline waits took 731.2 ms in one 300-frame interval. The install lacked a seed manifest and skipped the [device's recorded prewarm list](../../../docs/reference/shaders.md#prewarm-without-a-bundled-seed).
- A second iPad run with the recorded list explicitly provided loaded 876 entries in 0.48 s. Changing both CVar copies from 2 to 1 at runtime moved the game's present interval to 1. In the same scene the next full 300-frame window measured p50 16.63 ms and p95 17.62 ms, compared with p50 33.34 ms and p95 34.55 ms before the change. Campaign performance and the packaged defaults still need a device run.
