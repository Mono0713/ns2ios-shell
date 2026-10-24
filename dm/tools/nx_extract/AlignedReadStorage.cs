using System;
using LibHac.Fs;

/// <summary>
/// Reads an update's patched data section through 16-byte aligned windows.
///
/// LibHac's Aes128CtrExStorage refuses a read whose offset is not a multiple of 16 ("Offset must be a multiple of
/// 16" from SectorStorage.ValidateSize), and its RomFS reader starts at offset 0 with a 0x50-byte header: for a base
/// and an update whose patch region does not begin on a 16-byte boundary, that read fails before anything is read, so
/// the update can never be layered over the base -- Balatro's does exactly this, on Windows and on macOS alike.
///
/// Wrapping the stacked storage rounds every read out to sector-sized windows and slices the answer back, so the
/// inner storage only ever sees aligned offsets. A wrapper, not a fix: if libhac learns to align its own reads this
/// class can go.
/// </summary>
public class AlignedReadStorage : IStorage
{
    private const int Align = 16;
    private readonly IStorage _base;

    public AlignedReadStorage(IStorage storage) => _base = storage;

    public long Size => _base.Size;

    public int Read(long offset, Span<byte> destination)
    {
        if (destination.Length == 0) return 0;

        long start = offset & ~(long)(Align - 1);
        long end = (offset + destination.Length + Align - 1) & ~(long)(Align - 1);
        if (end > Size) end = (Size + Align - 1) & ~(long)(Align - 1);
        if (end <= start) return 0;

        byte[] window = new byte[end - start];
        int got = _base.Read(start, window);

        int skip = (int)(offset - start);
        int available = Math.Max(0, got - skip);
        int n = Math.Min(destination.Length, available);
        if (n > 0) window.AsSpan(skip, n).CopyTo(destination);
        return n;
    }

    public void Write(long offset, ReadOnlySpan<byte> source) => throw new NotSupportedException();

    public void Flush() { }
}
