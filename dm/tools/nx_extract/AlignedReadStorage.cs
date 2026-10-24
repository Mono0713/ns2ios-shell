using System;
using LibHac;
using LibHac.Fs;

/// <summary>
/// Reads an update's patched data section through 16-byte aligned windows.
///
/// LibHac's Aes128CtrExStorage refuses a read whose offset is not a multiple of 16 ("Offset must be a multiple of 16"
/// from SectorStorage.ValidateSize), and the RomFS reader opens the section at offset 0 with a 0x50-byte header: fine for
/// an update whose patch region starts on a boundary, fatal for one whose does not. Balatro's is the latter -- the base
/// alone extracts, base plus update fails before anything is read, on Windows and on macOS with a freshly built
/// nx_extract alike, so the update could never be layered and only the base could be packed.
///
/// Wrapping the stacked storage rounds every read out to sector windows and copies the wanted slice out, so the inner
/// storage only ever sees aligned offsets. A wrapper, not a fix: it can go when libhac aligns its own reads.
/// </summary>
public class AlignedReadStorage : IStorage
{
    private const int Align = 16;
    private readonly IStorage _base;

    public AlignedReadStorage(IStorage storage) => _base = storage;

    public override Result GetSize(out long size) => _base.GetSize(out size);

    public override Result SetSize(long size) => _base.SetSize(size);

    public override Result Flush() => _base.Flush();

    public override Result Write(long offset, ReadOnlySpan<byte> source) => _base.Write(offset, source);

    public override Result OperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
        => _base.OperateRange(outBuffer, operationId, offset, size, inBuffer);

    public override Result Read(long offset, Span<byte> destination)
    {
        if (destination.Length == 0) return Result.Success;

        Result rc = _base.GetSize(out long size);
        if (rc.IsFailure()) return rc;

        long start = offset & ~(long)(Align - 1);
        long end = (offset + destination.Length + Align - 1) & ~(long)(Align - 1);
        if (end > size) end = size;
        if (end <= start) return LibHac.Fs.ResultFs.OutOfRange.Value;

        byte[] window = new byte[end - start];
        rc = _base.Read(start, window);
        if (rc.IsFailure()) return rc;

        int skip = (int)(offset - start);
        int n = Math.Min(destination.Length, window.Length - skip);
        if (n <= 0) return LibHac.Fs.ResultFs.OutOfRange.Value;
        window.AsSpan(skip, n).CopyTo(destination);
        return Result.Success;
    }
}
