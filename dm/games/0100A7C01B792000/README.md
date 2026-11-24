# Minecraft Dungeons II (`0100A7C01B792000`)

Update 1.1.3.0, main build `c6b32f4d3d4243ff190b082b4f6aea18`. Unreal Engine.

## Startup

- An iPad breakpoint at the C++ throw inside `main+0x7063d2c` identified `HCGlobalInitialize` as the XAL failure. Its provider called `nn::ssl::Context::Create` at `main+0x7035a1c` to create a settings context before network activity. The offline hook returned `0x2a2`; the library translated it into `0x80004005`.
- The [offline SSL context](../../../docs/reference/services.md#local-ssl-contexts-during-offline-startup) keeps the configuration context's lifecycle in the host, scoped to this main build. This leaves the SDK's service pointer empty and connection operations offline.
- An iPad debugger run applied the local context result to the installed build. XalInitialize returned success and both movie decoders stopped normally. The game then waited for a flip in `FFrameEndSync` (`main+0x1501228` and `+0x150194c`). The log showed `ListFrameHistory` returning zero and the game polls it in the viewport thread (`main+0x142b034` and `+0x142b094`). The host now reports [layer frame history](../../../docs/reference/services.md#layer-frame-history).
- Returning records derived from the installed app's present queue in the debugger moved the game past the blocked frame 174. It reached the first-run brightness screen and continued beyond frame 2,400 after the debugger detached. The player confirmed normal operation after detach. This validated the two failure paths on-device. A cold launch of the integrated fixes and a gameplay run still need acceptance.
