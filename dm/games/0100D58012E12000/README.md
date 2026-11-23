# Gang Beasts

Update 1.26.0 (v589824). The iPad build `2026.1123.1327` reached local character selection. Starting the match left the last loading frame on screen. The process logged a return from `nnMain`.

## Local match server

- **Cause:** `CoreNet.NetworkManager.LaunchServer` calls UNet's `NetworkManager.StartServer`. The iPad log captured `Application.Quit(10)` with the managed string `[NetworkManager] failed to start server, exiting`. `NetworkServer.InternalListen` defaults to opening a socket in `NetworkServerSimple.Listen`. The host reports unavailable sockets.
- **Fix:** Set UNet's documented [`dontListen` flag](https://docs.unity3d.com/560/Documentation/ScriptReference/Networking.NetworkServer-dontListen.html) in the matching build before the listen decision. Keep the library's server initialization and its in-process `ClientScene.ConnectLocalServer` path. The rewriter checks the original instruction bytes for this build.
- **Verified on iPad:** The player reported local play working normally with the change in build 2026.1123.1728. The game log reached gameplay and did not report the earlier native exit.
