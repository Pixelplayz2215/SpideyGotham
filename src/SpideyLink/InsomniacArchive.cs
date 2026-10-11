// Reads assets out of the player's own Marvel's Spider-Man Remastered install (asset_archive/toc + archives).
// Format knowledge from Tkachov's ALERT research (github.com/Tkachov/ALERT); this is an independent implementation.
using System.IO.Compression;
using System.Text;

namespace SpideyLink;

public sealed class Dat1
{
    public readonly byte[] Data;
    public readonly int Base;
    public readonly Dictionary<uint, (int off, int size)> Sections = new();

    public Dat1(byte[] data, int start = 0)
    {
        Data = data; Base = start;
        if (BitConverter.ToUInt32(data, start) != 0x44415431) throw new InvalidDataException("not DAT1");
        int count = BitConverter.ToUInt16(data, start + 12);
        for (int i = 0; i < count; i++)
        {
            int p = start + 16 + i * 12;
            Sections[BitConverter.ToUInt32(data, p)] = (start + (int)BitConverter.ToUInt32(data, p + 4), (int)BitConverter.ToUInt32(data, p + 8));
        }
    }

    public ReadOnlySpan<byte> Section(uint tag) => Sections.TryGetValue(tag, out var s) ? Data.AsSpan(s.off, s.size) : ReadOnlySpan<byte>.Empty;

    public string? StringAt(uint offset)
    {
        int p = Base + (int)offset;
        if (p < 0 || p >= Data.Length) return null;
        int e = Array.IndexOf(Data, (byte)0, p);
        if (e < 0) e = Data.Length;
        return Encoding.UTF8.GetString(Data, p, e - p);
    }
}

public sealed class SpiderManArchive : IDisposable
{
    const uint TagArchives = 0x398ABFF0, TagAssetIds = 0x506D7B8A, TagSizes = 0x65BCF461, TagOffsets = 0xDCD720B5;

    readonly string _dir;
    readonly string[] _archiveNames;
    readonly ulong[] _ids;
    readonly uint[] _sizes;
    readonly (uint arch, uint off)[] _offsets;
    readonly Dictionary<ulong, int> _index = new();
    readonly Dictionary<uint, (FileStream fs, List<(ulong real, ulong comp, uint realSize, uint compSize)>? blocks)> _open = new();

    public int AssetCount => _ids.Length;

    public SpiderManArchive(string assetArchiveDir)
    {
        _dir = assetArchiveDir;
        var raw = File.ReadAllBytes(Path.Combine(_dir, "toc"));
        if (BitConverter.ToUInt32(raw, 0) != 0x77AF12AF) throw new InvalidDataException("unexpected toc magic");
        int size = (int)BitConverter.ToUInt32(raw, 4);
        var toc = Inflate(raw, 8, size);
        var d = new Dat1(toc);

        var arch = d.Section(TagArchives);
        _archiveNames = new string[arch.Length / 72];
        for (int i = 0; i < _archiveNames.Length; i++)
        {
            var name = arch.Slice(i * 72 + 8, 64);
            int z = name.IndexOf((byte)0);
            _archiveNames[i] = Encoding.ASCII.GetString(z < 0 ? name : name[..z]).Replace('\\', '/');
        }
        var ids = d.Section(TagAssetIds);
        _ids = new ulong[ids.Length / 8];
        for (int i = 0; i < _ids.Length; i++) _ids[i] = BitConverter.ToUInt64(ids.Slice(i * 8, 8));
        var sz = d.Section(TagSizes);
        _sizes = new uint[sz.Length / 12];
        for (int i = 0; i < _sizes.Length; i++) _sizes[i] = BitConverter.ToUInt32(sz.Slice(i * 12 + 4, 4));
        var of = d.Section(TagOffsets);
        _offsets = new (uint, uint)[of.Length / 8];
        for (int i = 0; i < _offsets.Length; i++) _offsets[i] = (BitConverter.ToUInt32(of.Slice(i * 8, 4)), BitConverter.ToUInt32(of.Slice(i * 8 + 4, 4)));
        // The toc lists every language; only some localized archives are installed. Prefer installed ones, first entry wins.
        var present = _archiveNames.Select(n => File.Exists(Path.Combine(_dir, n))).ToArray();
        for (int i = _ids.Length - 1; i >= 0; i--)
        {
            bool here = _offsets[i].arch < present.Length && present[_offsets[i].arch];
            if (here || !_index.ContainsKey(_ids[i]) || !present[_offsets[_index[_ids[i]]].arch]) _index[_ids[i]] = i;
        }
    }

    static byte[] Inflate(byte[] src, int offset, int expected)
    {
        using var ms = new MemoryStream(src, offset, src.Length - offset);
        using var z = new ZLibStream(ms, CompressionMode.Decompress);
        var outBuf = new byte[expected];
        int read = 0;
        while (read < expected) { int n = z.Read(outBuf, read, expected - read); if (n <= 0) break; read += n; }
        return outBuf;
    }

    public bool Has(string path) => _index.ContainsKey(AssetId(path));
    public bool Has(ulong id) => _index.ContainsKey(id);

    public byte[]? Read(string path) => Read(AssetId(path));

    public (uint arch, uint off, uint size)? Locate(ulong id)
    {
        if (!_index.TryGetValue(id, out int i)) return null;
        return (_offsets[i].arch, _offsets[i].off, _sizes[i]);
    }

    public IEnumerable<ulong> AllIds => _index.Keys;
    public bool Installed(ulong id) => _index.TryGetValue(id, out int i) && File.Exists(Path.Combine(_dir, _archiveNames[_offsets[i].arch]));
    public string ArchiveName(uint idx) => _archiveNames[idx];

    public int ArchiveIndexOf(string fileName) => Array.FindIndex(_archiveNames, n => n.EndsWith(fileName, StringComparison.OrdinalIgnoreCase));

    public byte[]? Read(ulong id)
    {
        if (!_index.TryGetValue(id, out int i)) return null;
        var (archIdx, off) = _offsets[i];
        uint size = _sizes[i];
        var (fs, blocks) = Archive(archIdx);
        if (blocks == null)
        {
            var buf = new byte[size];
            fs.Position = off; fs.ReadExactly(buf);
            return buf;
        }
        var result = new byte[size];
        ulong start = off, end = start + size;
        int written = 0;
        foreach (var b in blocks)
        {
            ulong bEnd = b.real + b.realSize;
            if (bEnd <= start) continue;
            if (b.real >= end) break;
            var comp = new byte[b.compSize];
            fs.Position = (long)b.comp; fs.ReadExactly(comp);
            var plain = b.compSize == b.realSize ? comp : Lz.Decompress(comp, (int)b.realSize);
            int from = (int)(Math.Max(b.real, start) - b.real);
            int to = (int)(Math.Min(bEnd, end) - b.real);
            Buffer.BlockCopy(plain, from, result, written, to - from);
            written += to - from;
        }
        return result;
    }

    (FileStream fs, List<(ulong real, ulong comp, uint realSize, uint compSize)>? blocks) Archive(uint idx)
    {
        if (_open.TryGetValue(idx, out var a)) return a;
        var fs = new FileStream(Path.Combine(_dir, _archiveNames[idx]), FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var head = new byte[32]; fs.ReadExactly(head);
        List<(ulong real, ulong comp, uint realSize, uint compSize)>? blocks = null;
        if (BitConverter.ToUInt32(head, 0) == 0x52415344) // "DSAR"
        {
            uint headerEnd = BitConverter.ToUInt32(head, 12);
            var tbl = new byte[headerEnd - 32]; fs.ReadExactly(tbl);
            blocks = new();
            for (int p = 0; p + 32 <= tbl.Length; p += 32)
                blocks.Add((BitConverter.ToUInt64(tbl, p), BitConverter.ToUInt64(tbl, p + 8), BitConverter.ToUInt32(tbl, p + 16), BitConverter.ToUInt32(tbl, p + 20)));
        }
        _open[idx] = (fs, blocks);
        return (fs, blocks);
    }

    static readonly ulong[] Crc = BuildCrc();
    static ulong[] BuildCrc()
    {
        var t = new ulong[256];
        for (ulong i = 0; i < 256; i++)
        {
            ulong c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? (c >> 1) ^ 0xC96C5795D7870F42UL : c >> 1;
            t[i] = c;
        }
        return t;
    }

    public static string Normalize(string path)
    {
        var sb = new StringBuilder();
        bool slash = false;
        foreach (char ch in path.ToLowerInvariant().Replace('\\', '/'))
        {
            if (ch == '/') { if (slash) continue; slash = true; } else slash = false;
            sb.Append(ch);
        }
        return sb.ToString();
    }

    public static ulong AssetId(string path)
    {
        ulong v = 0xC96C5795D7870F42UL;
        foreach (byte b in Encoding.UTF8.GetBytes(Normalize(path))) v = (v >> 8) ^ Crc[(byte)(v ^ b)];
        return (v >> 2) | 0x8000000000000000UL;
    }

    public void Dispose() { foreach (var a in _open.Values) a.fs.Dispose(); }

    // Asset names, from the dependency graph file next to the toc.
    public static List<string> ReadDagNames(string assetArchiveDir)
    {
        var raw = File.ReadAllBytes(Path.Combine(assetArchiveDir, "dag"));
        if (BitConverter.ToUInt32(raw, 0) != 0x891F77AF) throw new InvalidDataException("unexpected dag magic");
        var dag = Inflate(raw, 12, (int)BitConverter.ToUInt32(raw, 4));
        var d = new Dat1(dag);
        var names = d.Section(0xD101A6CC);
        var list = new List<string>(names.Length / 4);
        for (int i = 0; i + 4 <= names.Length; i += 4)
        {
            var s = d.StringAt(BitConverter.ToUInt32(names.Slice(i, 4)));
            if (s != null) list.Add(s);
        }
        return list;
    }
}

// Insomniac's LZ4-style block codec (as documented by ALERT).
public static class Lz
{
    public static byte[] Decompress(byte[] c, int realSize)
    {
        var r = new byte[realSize];
        int ri = 0, ci = 0, cs = c.Length;
        while (ri <= realSize && ci < cs)
        {
            int a = c[ci++], b = 0;
            if ((a & 0xF0) == 0xF0) b = c[ci++];
            int direct = (a >> 4) + b;
            while (direct >= 270 && (direct - 15) % 255 == 0) { int v = c[ci++]; direct += v; if (v == 0) break; }
            for (int i = 0; i < direct; i++) { if (ri + i >= realSize || ci + i >= cs) break; r[ri + i] = c[ci + i]; }
            ri += direct; ci += direct;
            int rev = (a & 15) + 4;
            if (!(ri <= realSize && ci < cs)) break;
            int off = c[ci] | (c[ci + 1] << 8); ci += 2;
            if (rev == 19)
            {
                rev += c[ci++];
                while (rev >= 274 && (rev - 19) % 255 == 0) { int v = c[ci++]; rev += v; if (v == 0) break; }
            }
            for (int i = 0; i < rev; i++)
            {
                int dst = ri + i, src = ri - off + i;
                if (dst < realSize && src >= 0 && src < realSize) r[dst] = r[src];
            }
            ri += rev;
        }
        return r;
    }
}
