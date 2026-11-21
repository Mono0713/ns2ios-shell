# Moving Out 2 (010065D018172000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS as described there ("Registered patches"). The game's profile itself is provisional (the NSP script's survey), so this folder holds only this file.
#
# Update v327680 main (build c552b646), Unity 2021.3 IL2CPP: two identical virtual call thunks (main+0xd29e10 and main+0xe55d70, 96 bytes each with their padding) end in
#   ldrh w17,[x17,#0x50]; add x17,x18,x17,lsl #4; ldp x18,x17,[x17,#0x138]; ...; stp x16,x17,[sp,#0x38]; br x18; udf #0
# (x18 the object's class, then vtable[slot] = {method pointer, MethodInfo}). The rewriter takes a br x18 for a tail call only when the last write of x18 is an ldr and the br is the
# function's last instruction; here it is an ldp and the zero padding word after it is inside the unwind range, so it looked for a jump table and stopped ("jump table d29e68").
# The br and the padding become mov x16,x18; br x16: x16 is an intra-procedure-call temporary (the thunk already stored it), the mov is an ordinary x18 read, and the jump no longer
# goes through x18 at all. The same as site_br_call emits for a recognised tail call. A generic patch_nso.py rule would change PACK_ABI (the whole library repacked), so it waits for
# the next format change: switch-pad project files moving-clubhouse/patch_nso-tailcall-generic.patch
_THUNK = '40021fd6' '00000000', 'f00312aa' '00021fd6'   # br x18; udf #0  →  mov x16, x18; br x16
CUTS = {
    'c552b6464e7348a7bb261a708b353137': [
        (0xd29e68, *_THUNK, 'IL2CPP virtual call thunk: br x18 after ldp x18,x17 → mov x16,x18; br x16 (tail call, not a jump table)'),
        (0xe55dc8, *_THUNK, 'IL2CPP virtual call thunk: br x18 after ldp x18,x17 → mov x16,x18; br x16 (tail call, not a jump table)'),
    ],
}
