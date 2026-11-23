# Gang Beasts: the iPad local match returns from nnMain after character select. On 2026-11-23 neither managed Unity quit
# function fired. Observe the native quit branch and common cleanup to distinguish a native exit from another return path.
OBS = {
  '4a276da904011c02a013fa4ef453b39d': [
    (0x152f5a4, 22, '52802029', 'UnityEngine.Application.Quit: w0 = exit code; orig mov w9, #0x101'),
    (0x152f5c4, 22, 'f9477908', 'UnityEngine.Application.CancelQuit: orig ldr x8, [x8, #0xef0]'),
    (0xfb7a6c, 22, '52800048', 'nnMain: native quit-flag branch taken; orig mov w8, #2'),
    (0xfb7bf4, 22, '911443ff', 'nnMain: common epilogue on all return paths; orig add sp, sp, #0x510'),
  ],
}
