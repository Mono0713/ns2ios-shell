# Rabbids Party of Legends 1.0.1 (01008970149B0000), main build 7c087605.
# The movie player passes a 128-entry count to InitializeMessageQueue, but
# allocates only 128 bytes for each queue. The SDK stores eight-byte messages.
# On iPad its seventeenth store overwrote a live MatroskaSource next to the ring.
CUTS = {
    '7c0876057ee29df336f7e12b3099f738': [
        (0x7be794, 'e3aa3994', '0cab3994', 'allocate full storage for the first movie message queue'),
        (0x7be7a8, 'deaa3994', '07ab3994', 'allocate full storage for the second movie message queue'),
        # Unreferenced alignment words after the allocator wrapper's final branch.
        (0x16293c4, '0000000000000000', '21f07dd3d6ffff17', 'lsl x1, x1, #3; tail-call the original aligned allocator'),
    ],
}
