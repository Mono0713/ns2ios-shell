# Gang Beasts: an iPad local match exits nnMain cleanly after character select. Trace whether Unity requested or cancelled
# the quit, including its return address and exit code, while leaving the guest's exit path intact.
OBS = {
  '4a276da904011c02a013fa4ef453b39d': [
    (0x152f5a4, 22, '52802029', 'UnityEngine.Application.Quit: w0 = exit code; orig mov w9, #0x101'),
    (0x152f5c4, 22, 'f9477908', 'UnityEngine.Application.CancelQuit: orig ldr x8, [x8, #0xef0]'),
  ],
}
