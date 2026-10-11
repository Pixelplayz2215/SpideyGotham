using System.Text;

namespace SpideyLink;

// Developer-only inspection commands (not used by players).
static class DevTools
{
    public static void BankInfo(byte[] asset)
    {
        var bank = Soundbank.Parse(asset);
        Console.WriteLine($"strings: {string.Join(" | ", bank.Strings.Take(60))}");
        Console.WriteLine($"bnk {bank.Bnk.Length} bytes, embedded wems: {bank.Embedded.Count}");
        foreach (var (id, off, len) in bank.Embedded.Take(20)) Console.WriteLine($"  wem {id} {len}");
        Console.WriteLine($"streamed source refs: {bank.StreamedIds.Count}: {string.Join(",", bank.StreamedIds.Take(30))}");
        Console.WriteLine($"HIRC types: {string.Join(" ", bank.TypeCounts.OrderBy(k => k.Key).Select(k => $"{k.Key}:{k.Value}"))}");
        var embeddedIds = bank.Embedded.Select(e => e.id).ToHashSet();
        var ms = bank.MusicSources;
        Console.WriteLine($"music sources: {ms.Count}, stream types: {string.Join(" ", ms.GroupBy(m => m.stream).Select(g => $"{g.Key}:{g.Count()}"))}, embedded-matched: {ms.Count(m => embeddedIds.Contains(m.src))}");
        foreach (var m in ms.Take(10)) Console.WriteLine($"  src {m.src} stream {m.stream} size {m.size}");
    }

    public static void ArchiveListing(SpiderManArchive a, List<string> names, uint archIdx, string outPath)
    {
        using var w = new StreamWriter(outPath);
        foreach (var n in names)
        {
            var info = a.Locate(SpiderManArchive.AssetId(n));
            if (info != null && info.Value.arch == archIdx) w.WriteLine($"{n}\t{info.Value.size}");
        }
    }
}
