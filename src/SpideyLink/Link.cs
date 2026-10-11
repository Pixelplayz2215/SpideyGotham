using System.Diagnostics;

namespace SpideyLink;

// The runtime: finds Spider-Man Remastered (folder from Melty), builds the audio cache, starts LEGO Batman,
// then plays cues the in-game mod writes to events.txt until the game exits.
public static class Link
{
    public const string GameProcess = "LEGOBatmanLotDK-Win64-Shipping";
    public const string SteamAppId = "2215200";
    public static readonly string Home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpideyGotham");
    static StreamWriter? _logW;

    public static void Log(string s)
    {
        try
        {
            _logW ??= new StreamWriter(Path.Combine(Home, "SpideyLink.log"), append: false) { AutoFlush = true };
            _logW.WriteLine($"[{DateTime.Now:HH:mm:ss}] {s}");
        }
        catch { }
    }

    public static string? FindSpiderMan()
    {
        // 1. Melty writes the companion folder here before every start.
        var env = Path.Combine(Home, "melty.env");
        if (File.Exists(env))
            foreach (var line in File.ReadAllLines(env))
            {
                var i = line.IndexOf('=');
                if (i > 0 && line[..i].Trim() == "SPIDEYGOTHAM_SM_DIR") { var v = line[(i + 1)..].Trim().Trim('"'); if (Valid(v)) return v; }
            }
        var e = Environment.GetEnvironmentVariable("SPIDEYGOTHAM_SM_DIR");
        if (e != null && Valid(e)) return e;
        // 2. Last known good folder (for starts outside Melty).
        var last = Path.Combine(Home, "spiderman_dir.txt");
        if (File.Exists(last)) { var v = File.ReadAllText(last).Trim(); if (Valid(v)) return v; }
        return null;
    }

    static bool Valid(string dir) => File.Exists(Path.Combine(dir, "asset_archive", "toc"));

    public static int Run(bool launchGame)
    {
        Directory.CreateDirectory(Home);
        using var single = new Mutex(true, "SpideyGotham.SpideyLink", out bool first);
        if (!first) { Log("already running"); return 0; }
        Log($"SpideyLink {typeof(Link).Assembly.GetName().Version} start (launch={launchGame})");

        var events = Path.Combine(Home, "events.txt");
        File.WriteAllText(events, "");
        var sm = FindSpiderMan();
        if (sm == null) { Log("Marvel's Spider-Man Remastered folder not found; audio disabled"); WriteStatus("no-spiderman"); }
        else File.WriteAllText(Path.Combine(Home, "spiderman_dir.txt"), sm);

        if (launchGame && Process.GetProcessesByName(GameProcess).Length == 0)
        {
            Log("starting LEGO Batman via Steam");
            Process.Start(new ProcessStartInfo($"steam://rungameid/{SteamAppId}") { UseShellExecute = true });
        }

        AudioCache? cache = null;
        if (sm != null)
        {
            try
            {
                var vgm = Path.Combine(AppContext.BaseDirectory, "vgmstream", "vgmstream-cli.exe");
                cache = new AudioCache(sm, Path.Combine(Home, "cache"), vgm, Log);
                WriteStatus("building-audio");
                cache.Build();
            }
            catch (Exception ex) { Log("audio cache failed: " + ex); cache = null; }
        }

        // wait for the game (up to 3 minutes), then run until it exits
        Process? game = null;
        var deadline = DateTime.UtcNow.AddMinutes(3);
        while (game == null && DateTime.UtcNow < deadline)
        {
            game = Process.GetProcessesByName(GameProcess).FirstOrDefault();
            if (game == null) Thread.Sleep(500);
        }
        if (game == null) { Log("LEGO Batman did not start"); return 1; }
        Log($"game pid {game.Id}");

        using var player = cache != null ? new CuePlayer(cache, Log) : null;
        GC.Collect(2, GCCollectionMode.Aggressive, true, true); // drop archive/bank buffers from the cache build
        WriteStatus(player != null ? "ready" : "no-audio");
        long readPos = 0;
        var lastBeat = DateTime.MinValue;
        while (!game.HasExited)
        {
            try
            {
                using var fs = new FileStream(events, FileMode.OpenOrCreate, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (fs.Length < readPos) readPos = 0;
                if (fs.Length > readPos)
                {
                    fs.Position = readPos;
                    using var sr = new StreamReader(fs);
                    var text = sr.ReadToEnd();
                    int lastNl = text.LastIndexOf('\n');
                    if (lastNl >= 0)
                    {
                        readPos += System.Text.Encoding.UTF8.GetByteCount(text[..(lastNl + 1)]);
                        foreach (var line in text[..lastNl].Split('\n'))
                        {
                            var cue = line.Trim();
                            if (cue.Length > 0) player?.Trigger(cue);
                        }
                    }
                }
            }
            catch (IOException) { }
            player?.Tick();
            if ((DateTime.UtcNow - lastBeat).TotalSeconds >= 2) { WriteStatus(player != null ? "ready" : "no-audio"); lastBeat = DateTime.UtcNow; }
            Thread.Sleep(15);
        }
        Log("game exited");
        WriteStatus("stopped");
        return 0;
    }

    // heartbeat the in-game mod reads: "<state> <unix seconds>"
    static void WriteStatus(string state)
    {
        try { File.WriteAllText(Path.Combine(Home, "link.txt"), $"{state} {DateTimeOffset.UtcNow.ToUnixTimeSeconds()}"); } catch { }
    }
}

public sealed class CuePlayer : IDisposable
{
    readonly Mixer _mixer = new();
    readonly Dictionary<string, List<float[]>> _pools = new();
    readonly Dictionary<string, Cue> _cues = Cues.All.ToDictionary(c => c.Id);
    readonly Dictionary<string, DateTime> _last = new();
    readonly Dictionary<string, int> _lastIdx = new();
    readonly Random _rng = new();
    readonly Action<string> _log;
    DateTime _musicKeepAlive = DateTime.MinValue;
    const double MusicHoldS = 6;

    public CuePlayer(AudioCache cache, Action<string> log)
    {
        _log = log;
        foreach (var (id, files) in cache.Files)
        {
            var c = _cues[id];
            if (c.Kind == "music") _mixer.SetMusic(AudioCache.ReadPcm(files[0]), c.Volume);
            else _pools[id] = files.Select(AudioCache.ReadPcm).ToList();
        }
        _log($"cue player ready: {string.Join(", ", _pools.Select(p => $"{p.Key}={p.Value.Count}"))}");
    }

    public void Trigger(string id)
    {
        if (id == "music_traversal") { if (_musicKeepAlive < DateTime.UtcNow.AddSeconds(-MusicHoldS)) _log("music on"); _musicKeepAlive = DateTime.UtcNow; _mixer.MusicOn(); return; }
        if (id == "music_stop") { _musicKeepAlive = DateTime.MinValue; _mixer.MusicOff(); _log("music off"); return; }
        if (!_cues.TryGetValue(id, out var c) || !_pools.TryGetValue(id, out var pool) || pool.Count == 0) return;
        var now = DateTime.UtcNow;
        if (_last.TryGetValue(id, out var t) && (now - t).TotalSeconds < c.CooldownS) return;
        if (_rng.NextDouble() > c.Chance) return;
        if (c.Kind == "vo" && _mixer.VoiceBusy && id != "vo_suit_up") return; // one line at a time
        int idx = _rng.Next(pool.Count);
        if (pool.Count > 1 && _lastIdx.TryGetValue(id, out var li) && li == idx) idx = (idx + 1) % pool.Count;
        _lastIdx[id] = idx; _last[id] = now;
        _mixer.Play(pool[idx], c.Volume);
        _log($"play {id} #{idx}");
    }

    public void Tick()
    {
        if (_musicKeepAlive != DateTime.MinValue && (DateTime.UtcNow - _musicKeepAlive).TotalSeconds > MusicHoldS)
        { _musicKeepAlive = DateTime.MinValue; _mixer.MusicOff(); _log("music fade out"); }
    }

    public void Dispose() => _mixer.Dispose();
}
