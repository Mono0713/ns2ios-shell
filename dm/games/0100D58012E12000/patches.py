# Gang Beasts 1.26.0 (v589824). The local match calls CoreNet.NetworkManager.LaunchServer, then attaches an in-process
# client through ClientScene.ConnectLocalServer. UNet's usual Listen path tries to open a network socket, which fails in
# the offline host. The iPad trace showed Application.Quit(10) with "[NetworkManager] failed to start server, exiting".
# Set NetworkServer.dontListen in InternalListen and run its existing initialization path for an in-process host.
CUTS = {
  '4a276da904011c02a013fa4ef453b39d': [
    (0x2b36ea4, '601e40f908614039c8000034', '2900805209610039601e40f9',
     'NetworkServer::InternalListen: set dontListen to true and initialize its NetworkServerSimple without a socket'),
  ],
}

OBS = {
  '4a276da904011c02a013fa4ef453b39d': [
    (0x152f5a4, 22, '52802029', 'UnityEngine.Application.Quit: w0 = exit code; orig mov w9, #0x101'),
    (0x152f5c4, 22, 'f9477908', 'UnityEngine.Application.CancelQuit: orig ldr x8, [x8, #0xef0]'),
    (0xfb7a6c, 22, '52800048', 'nnMain: native quit-flag branch taken; orig mov w8, #2'),
    (0xfb7bf4, 22, '911443ff', 'nnMain: common epilogue on all return paths; orig add sp, sp, #0x510'),
  ],
}
