# Rabbids Party of Legends (`01008970149B0000`)

Update 1.0.1 (`v65536`), provisional profile. Main build `7c0876057ee29df336f7e12b3099f738`.

## Opening movie

- A hardware watchpoint caught `nn::os::SendMessageQueue` at `sdk+0x372dac` storing the seventeenth eight-byte message in a 128-byte allocation. The write landed at `main+0x4091100`, the first word of the adjacent live `MatroskaSource`. `AudioInputReadThread` then read the message value instead of the vtable at `subsdk1+0x2e9e2c`.
- The movie constructor uses the same count both as the size in bytes of each allocation (`main+0x7be794` and `+0x7be7a8`) and as the number of entries passed to the SDK (`+0x7be7c0` and `+0x7be7d0`). The build-specific patch multiplies only the allocation sizes by eight, using the same aligned allocator, cleanup path and logical queue capacity.
- The live iPad run confirmed 128 entries and 128 bytes. Correcting both byte counts to 1,024 on every invocation covered four allocations across two movies. The iPad logged both movies stopping and more than 4,800 frames without the access fault. The exact rewriter patch passed its original-byte checks on the extracted title executable.

## Rendering

- The provisional package has an empty shader map. The post-intro run recorded 59 distinct missing shader keys and continued presenting black frames. The new [Snowdrop SDF reader](../../../docs/reference/shaders.md#shader-records-in-snowdrop-sdf-data-slices) finds 2,570 unique keys from the shipped archives, including all 59 from that iPad run. The iPad build 2026.1124.1320 stopped crashing but still presented black frames. Its shader map had all 2,570 entries, but the [shell selected an obsolete empty chain directory](../../../docs/reference/shaders.md#obsolete-chain-directories-in-a-shell-package). The installed app's empty directory was removed after checking the current chain stamp and libraries. The next rendering check needs to confirm the title and gameplay.
