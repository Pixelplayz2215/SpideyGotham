using SpideyLink;

// Player entry points: no arguments / --launch (Melty's Play) and --attach (started by the in-game mod).
if (args.Length == 0 || args[0] == "--launch") return Link.Run(launchGame: true);
if (args[0] == "--attach") return Link.Run(launchGame: false);
if (args[0] == "--build-cache")
{
    Directory.CreateDirectory(Link.Home);
    var sm = args.Length > 1 ? args[1] : Link.FindSpiderMan();
    if (sm == null) { Console.WriteLine("Spider-Man folder not found"); return 1; }
    new AudioCache(sm, Path.Combine(Link.Home, "cache"), Path.Combine(AppContext.BaseDirectory, "vgmstream", "vgmstream-cli.exe"), Link.Log).Build();
    return 0;
}
if (args[0] == "--play-test")
{
    // dev: play a few cues through the mixer to hear the pipeline
    var sm = Link.FindSpiderMan() ?? args[1];
    var cache = new AudioCache(sm, Path.Combine(Link.Home, "cache"), Path.Combine(AppContext.BaseDirectory, "vgmstream", "vgmstream-cli.exe"), Link.Log);
    cache.Build();
    using var p = new CuePlayer(cache, Link.Log);
    foreach (var c in new[] { "vo_suit_up", "music_traversal", "sfx_web_shoot", "vo_swing" }) { p.Trigger(c); Thread.Sleep(2500); }
    Thread.Sleep(4000); p.Trigger("music_stop"); Thread.Sleep(2000);
    return 0;
}
return Dev.Run(args);

static class Dev { public static int Run(string[] args) {
if (args.Length >= 3 && args[0] == "names")
{
    var names = SpiderManArchive.ReadDagNames(args[1]);
    File.WriteAllLines(args[2], names);
    Console.WriteLine($"{names.Count} names");
    return 0;
}
if (args.Length >= 4 && args[0] == "dump")
{
    using var a = new SpiderManArchive(args[1]);
    var data = a.Read(args[2]);
    if (data == null) { Console.WriteLine("missing"); return 0; }
    File.WriteAllBytes(args[3], data);
    Console.WriteLine($"{data.Length} bytes");
    return 0;
}
if (args.Length >= 3 && args[0] == "bankinfo")
{
    using var a = new SpiderManArchive(args[1]);
    var data = a.Read(args[2]);
    if (data == null) { Console.WriteLine("missing"); return 0; }
    DevTools.BankInfo(data);
    return 0;
}
if (args.Length >= 5 && args[0] == "archlist")
{
    using var a = new SpiderManArchive(args[1]);
    var names = File.ReadAllLines(args[2]).ToList();
    int idx = a.ArchiveIndexOf(args[3]);
    Console.WriteLine($"archive index {idx}");
    DevTools.ArchiveListing(a, names, (uint)idx, args[4]);
    return 0;
}
if (args.Length >= 3 && args[0] == "probe")
{
    using var a = new SpiderManArchive(args[1]);
    foreach (var id in args.Skip(2))
    foreach (var dir in new[] { "", "sound\\", "sound\\streams\\", "sound\\stream\\", "sound\\wwise\\", "sound\\media\\", "sound\\banks\\", "sound\\english(us)\\", "sound\\banks\\english(us)\\", "sound\\streams\\english(us)\\", "sound\\banks\\streams\\", "sound\\wem\\", "sound\\banks\\media\\" })
    foreach (var ext in new[] { ".wem", ".stream", ".soundstream", "" })
    {
        var p = dir + id + ext;
        var loc = a.Locate(SpiderManArchive.AssetId(p));
        if (loc != null) Console.WriteLine($"HIT {p} arch {loc.Value.arch} size {loc.Value.size}");
    }
    Console.WriteLine("probe done");
    return 0;
}
if (args.Length >= 3 && args[0] == "unnamed")
{
    using var a = new SpiderManArchive(args[1]);
    var named = File.ReadAllLines(args[2]).Select(SpiderManArchive.AssetId).ToHashSet();
    var un = a.AllIds.Where(i => !named.Contains(i)).ToList();
    Console.WriteLine($"total {a.AssetCount}, unnamed {un.Count}");
    var byArch = un.GroupBy(i => a.Locate(i)!.Value.arch).Select(g => $"{g.Key}:{g.Count()}");
    Console.WriteLine("by archive: " + string.Join(" ", byArch));
    var magic = new Dictionary<string, int>();
    var inst = un.Where(a.Installed).ToList(); Console.WriteLine($"installed unnamed {inst.Count}: " + string.Join(" ", inst.GroupBy(i => a.ArchiveName(a.Locate(i)!.Value.arch)).Select(g => $"{g.Key}:{g.Count()}")));
    foreach (var id in inst.Where((_, k) => k % 20 == 0).Take(400))
    {
        var d = a.Read(id)!;
        string m = d.Length >= 4 ? System.Text.Encoding.ASCII.GetString(d, 0, 4).Replace('\0', '.') + "/" + BitConverter.ToUInt32(d, 0).ToString("X8") : "short";
        magic[m] = magic.GetValueOrDefault(m) + 1;
    }
    foreach (var kv in magic.OrderByDescending(k => k.Value).Take(15)) Console.WriteLine($"  {kv.Key} x{kv.Value}");
    return 0;
}
if (args.Length >= 5 && args[0] == "match")
{
    // match prefetched music sources in a bank to full streamed files among unnamed assets of one archive
    using var a = new SpiderManArchive(args[1]);
    var named = File.ReadAllLines(args[2]).Select(SpiderManArchive.AssetId).ToHashSet();
    var bank = Soundbank.Parse(a.Read(args[3])!);
    int arch = a.ArchiveIndexOf(args[4]);
    var cands = a.AllIds.Where(i => !named.Contains(i) && a.Installed(i) && a.Locate(i)!.Value.arch == arch).ToList();
    Console.WriteLine($"{cands.Count} candidates in {args[4]}");
    var heads = new Dictionary<string, ulong>();
    foreach (var id in cands) { var d = a.Read(id)!; if (d.Length >= 256) heads[Convert.ToHexString(d, 0, 256)] = id; }
    int found = 0;
    foreach (var e in bank.Embedded)
    {
        if (e.len < 256) continue;
        var key = Convert.ToHexString(bank.Bnk, e.off, 256);
        if (heads.TryGetValue(key, out var aid)) { found++; if (found <= 8) Console.WriteLine($"source {e.id} (0x{e.id:X8}) -> asset {aid:X16} size {a.Locate(aid)!.Value.size}"); }
    }
    Console.WriteLine($"matched {found}/{bank.Embedded.Count}");
    return 0;
}
if (args.Length >= 3 && args[0] == "idsin")
{
    using var a = new SpiderManArchive(args[1]);
    int arch = a.ArchiveIndexOf(args[2]);
    foreach (var id in a.AllIds.Where(i => a.Locate(i)!.Value.arch == arch).Take(12)) Console.WriteLine($"{id:X16}");
    var bank = Soundbank.Parse(a.Read("sound\\banks\\spid.soundbank")!);
    int hit = 0; foreach (var s in bank.StreamedIds) if (a.Has(0xE000000000000000UL | s)) hit++;
    Console.WriteLine($"spid streamed ids present as E-prefixed: {hit}/{bank.StreamedIds.Count}");
    return 0;
}
if (args.Length >= 4 && args[0] == "strings")
{
    using var a = new SpiderManArchive(args[1]);
    var bank = Soundbank.Parse(a.Read(args[2])!);
    File.WriteAllLines(args[3], bank.Strings);
    var groups = bank.Strings.Skip(1).GroupBy(s => System.Text.RegularExpressions.Regex.Replace(s, @"_\d+[A-Z]?$", "")).OrderBy(g => g.Key);
    foreach (var g in groups) Console.WriteLine($"{g.Key} x{g.Count()}");
    return 0;
}
if (args.Length >= 3 && args[0] == "musicinfo")
{
    using var a = new SpiderManArchive(args[1]);
    foreach (var bankPath in args.Skip(2))
    {
        var raw = a.Read(bankPath); if (raw == null) { Console.WriteLine($"{bankPath}: not in toc"); continue; }
        var bank = Soundbank.Parse(raw);
        var srcs = bank.MusicSources.Select(m => m.src).Distinct().Select(s => (s, size: a.Locate(0xE000000000000000UL | s)?.size ?? 0)).OrderByDescending(x => x.size).ToList();
        Console.WriteLine($"{bankPath}: {srcs.Count} sources; top: {string.Join(", ", srcs.Take(8).Select(x => $"{x.s}={x.size / 1024}KB"))}");
    }
    return 0;
}
if (args.Length >= 4 && args[0] == "stream")
{
    using var a = new SpiderManArchive(args[1]);
    var d = a.Read(0xE000000000000000UL | uint.Parse(args[2]));
    if (d == null) { Console.WriteLine("missing"); return 0; }
    File.WriteAllBytes(args[3], d); Console.WriteLine($"{d.Length} bytes");
    return 0;
}
if (args.Length >= 2 && args[0] == "cues")
{
    using var a = new SpiderManArchive(args[1]);
    var banks = new Dictionary<string, Soundbank>();
    foreach (var c in Cues.All.Where(c => c.Events != null))
    {
        if (!banks.TryGetValue(c.Bank!, out var bank)) banks[c.Bank!] = bank = Soundbank.Parse(a.Read(c.Bank!)!);
        var srcs = bank.SourcesForEventPrefix(c.Events!);
        int ok = srcs.Count(s => bank.SourceStreamType.GetValueOrDefault(s.source) == 0 ? bank.EmbeddedWem(s.source) != null : a.Has(0xE000000000000000UL | s.source));
        Console.WriteLine($"{c.Id}: {srcs.Count} lines ({ok} readable) e.g. {string.Join(", ", srcs.Take(3).Select(s => $"{s.name}={s.source}/{bank.SourceStreamType.GetValueOrDefault(s.source)}"))}");
    }
    return 0;
}
Console.WriteLine("usage: cues | stream | names | dump | bankinfo | archlist | probe | unnamed | match | idsin | strings | musicinfo");
return 1;
} }
