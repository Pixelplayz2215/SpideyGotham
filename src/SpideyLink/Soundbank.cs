using System.Text;

namespace SpideyLink;

// A Spider-Man Remastered .soundbank asset: Insomniac header + DAT1 wrapping a Wwise .bnk.
public sealed class Soundbank
{
    public List<string> Strings = new();
    public byte[] Bnk = Array.Empty<byte>();
    public int DataOffset = -1; // start of the DATA chunk payload inside Bnk
    public List<(uint id, int off, int len)> Embedded = new();
    public List<uint> StreamedIds = new();
    public Dictionary<uint, uint> SoundToSource = new(); // HIRC Sound object id -> media source id
    public Dictionary<byte, int> TypeCounts = new();
    public List<(uint src, byte stream, uint size)> MusicSources = new();

    public static Soundbank Parse(byte[] asset)
    {
        var sb = new Soundbank();
        var d = new Dat1(asset, 36);
        var strings = d.Section(0x3E8490A3);
        int start = 0;
        for (int i = 0; i < strings.Length; i++)
        {
            if (strings[i] != 0) continue;
            if (i > start) sb.Strings.Add(Encoding.UTF8.GetString(strings[start..i]));
            i++;
            while (i % 4 != 0) i++;
            start = i; i--;
        }
        sb.Bnk = d.Section(0x53F25238).ToArray();
        sb.ParseBnk();
        return sb;
    }

    void ParseBnk()
    {
        var b = Bnk;
        int p = 0;
        var didx = new List<(uint id, int off, int len)>();
        while (p + 8 <= b.Length)
        {
            string tag = Encoding.ASCII.GetString(b, p, 4);
            int len = (int)BitConverter.ToUInt32(b, p + 4);
            int body = p + 8;
            if (len < 0 || body + len > b.Length) break;
            switch (tag)
            {
                case "DIDX":
                    for (int q = body; q + 12 <= body + len; q += 12)
                        didx.Add((BitConverter.ToUInt32(b, q), (int)BitConverter.ToUInt32(b, q + 4), (int)BitConverter.ToUInt32(b, q + 8)));
                    break;
                case "DATA":
                    DataOffset = body;
                    break;
                case "HIRC":
                    ParseHirc(body, len);
                    break;
            }
            p = body + len;
        }
        if (DataOffset >= 0) foreach (var e in didx) Embedded.Add((e.id, DataOffset + e.off, e.len));
    }

    void ParseHirc(int body, int len)
    {
        var b = Bnk;
        uint count = BitConverter.ToUInt32(b, body);
        int q = body + 4;
        for (uint i = 0; i < count && q + 5 <= body + len; i++)
        {
            byte type = b[q];
            int size = (int)BitConverter.ToUInt32(b, q + 1);
            int o = q + 5;
            TypeCounts[type] = TypeCounts.GetValueOrDefault(type) + 1;
            if (type == 11 && size >= 21) // MusicTrack: id, flags(u8), numSources(u32), then AkBankSourceData[]
            {
                uint n = BitConverter.ToUInt32(b, o + 5);
                for (int s = 0; s < n && s < 64; s++)
                {
                    int sp = o + 9 + s * 14;
                    if (sp + 14 > o + size) break;
                    byte st = b[sp + 4];
                    uint src = BitConverter.ToUInt32(b, sp + 5);
                    MusicSources.Add((src, st, BitConverter.ToUInt32(b, sp + 9)));
                }
            }
            if (type == 2 && size >= 17) // Sound
            {
                uint id = BitConverter.ToUInt32(b, o);
                byte stream = b[o + 8];
                uint source = BitConverter.ToUInt32(b, o + 9);
                SoundToSource[id] = source;
                SourceStreamType[source] = stream;
                if (stream != 0 && !StreamedIds.Contains(source)) StreamedIds.Add(source);
            }
            if ((type == 5 || type == 6 || type == 7) && size >= 4) // containers: keep raw body to find child ids
                Containers[BitConverter.ToUInt32(b, o)] = (o, size);
            if (type == 3 && size >= 10) // Action: id, type(u16), target(u32)
            {
                ActionTarget[BitConverter.ToUInt32(b, o)] = (BitConverter.ToUInt16(b, o + 4), BitConverter.ToUInt32(b, o + 6));
            }
            if (type == 4 && size >= 5) // Event: id, action count (u8 or u32 depending on bank version), action ids
            {
                uint id = BitConverter.ToUInt32(b, o);
                int n, p0;
                if ((size - 5) % 4 == 0 && b[o + 4] == (size - 5) / 4) { n = b[o + 4]; p0 = o + 5; }
                else { n = (int)BitConverter.ToUInt32(b, o + 4); p0 = o + 8; }
                var list = new List<uint>();
                for (int k = 0; k < n && p0 + k * 4 + 4 <= o + size; k++) list.Add(BitConverter.ToUInt32(b, p0 + k * 4));
                EventActions[id] = list;
            }
            q = o + size;
        }
    }

    public Dictionary<uint, byte> SourceStreamType = new();
    public Dictionary<uint, (ushort type, uint target)> ActionTarget = new();
    public Dictionary<uint, List<uint>> EventActions = new();
    public Dictionary<uint, (int off, int size)> Containers = new();

    // Sound sources reachable from an object: a Sound directly, or the children of a random/sequence/switch container
    // (child ids are found by scanning the container body for u32s that are known Sound/container ids).
    void Collect(uint obj, List<uint> sources, int depth)
    {
        if (SoundToSource.TryGetValue(obj, out var src)) { if (!sources.Contains(src)) sources.Add(src); return; }
        if (depth > 0 || !Containers.TryGetValue(obj, out var c)) return;
        // only direct Sound children; never walk to other containers (that is how parent links leak whole trees in)
        for (int p = c.off + 4; p + 4 <= c.off + c.size; p++)
        {
            uint v = BitConverter.ToUInt32(Bnk, p);
            if (SoundToSource.TryGetValue(v, out var s) && !sources.Contains(s)) sources.Add(s);
        }
    }

    // Wwise short ids are FNV-1 32 of the lower-cased name.
    public static uint Fnv(string name)
    {
        uint h = 2166136261;
        foreach (byte c in Encoding.ASCII.GetBytes(name.ToLowerInvariant())) h = (h * 16777619) ^ c;
        return h;
    }

    // Wwise source ids for every named event that starts with prefix (Play actions on plain Sounds only).
    public List<(string name, uint source)> SourcesForEventPrefix(string prefix)
    {
        // Numbered VO events (PREFIX_001...) map straight to one line each; use those when they exist.
        var direct = SourcesForEventPrefixCore(prefix, numberedOnly: true);
        return direct.Count > 0 ? direct : SourcesForEventPrefixCore(prefix, numberedOnly: false);
    }

    List<(string name, uint source)> SourcesForEventPrefixCore(string prefix, bool numberedOnly)
    {
        var r = new List<(string, uint)>();
        foreach (var name in Strings)
        {
            if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            var rest = name.Substring(prefix.Length);
            if (rest.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(rest, @"^_\d+[A-Za-z]?$")) continue;
            if (numberedOnly && (rest.Length == 0 || rest.StartsWith("_999"))) continue;
            // VO line names are play events ("Play_" may or may not prefix them)
            foreach (var cand in new[] { name, "Play_" + name })
            {
                if (!EventActions.TryGetValue(Fnv(cand), out var acts)) continue;
                var srcs = new List<uint>();
                foreach (var a in acts)
                    if (ActionTarget.TryGetValue(a, out var at) && (at.type & 0xFF00) == 0x0400) Collect(at.target, srcs, 0); // 0x04xx = Play
                foreach (var s in srcs) r.Add((name, s));
                break;
            }
        }
        return r;
    }

    public byte[]? EmbeddedWem(uint id)
    {
        foreach (var e in Embedded) if (e.id == id) return Bnk.AsSpan(e.off, e.len).ToArray();
        return null;
    }
}
