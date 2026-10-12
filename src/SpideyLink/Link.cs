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

    static bool GameRunning()
    {
        try { return Process.GetProcessesByName(GameProcess).Length > 0; } catch { return false; }
    }

    // Melty watches this process, not the game: when started by Play it must stay up exactly as long as the game,
    // whatever goes wrong with the audio. Any failure below only switches the Spider-Man sounds off.
    public static int Run(bool launchGame)
    {
        try { Directory.CreateDirectory(Home); } catch { }
        try { return RunLink(launchGame); }
        catch (Exception ex)
        {
            Log("SpideyLink error: " + ex);
            WriteStatus("no-audio");
            return launchGame ? WaitForGameToEnd() : 0;
        }
    }

    // Started by Play: start the game if needed, then hold until it has been closed for a few seconds
    // (Steam can briefly restart it).
    static int WaitForGameToEnd()
    {
        if (!GameRunning() && !WaitForGameStart()) return 1;
        int goneFor = 0;
        while (goneFor < 10)
        {
            Thread.Sleep(1000);
            goneFor = GameRunning() ? 0 : goneFor + 1;
        }
        Log("game exited");
        return 0;
    }

    static bool WaitForGameStart()
    {
        var deadline = DateTime.UtcNow.AddMinutes(5);
        while (DateTime.UtcNow < deadline) { if (GameRunning()) return true; Thread.Sleep(500); }
        Log("LEGO Batman did not start");
        return false;
    }

    static void StartGame()
    {
        if (GameRunning()) return;
        Log("starting LEGO Batman via Steam");
        try { Process.Start(new ProcessStartInfo($"steam://rungameid/{SteamAppId}") { UseShellExecute = true }); }
        catch (Exception ex) { Log("could not start the game through Steam: " + ex.Message); }
    }

    static int RunLink(bool launchGame)
    {
        using var single = new Mutex(true, "SpideyGotham.SpideyLink", out bool first);
        if (!first)
        {
            // another SpideyLink already plays the sounds; a Play start still has to start the game and wait for it
            Log("already running");
            if (!launchGame) return 0;
            StartGame();
            return WaitForGameToEnd();
        }
        Log($"SpideyLink {typeof(Link).Assembly.GetName().Version} start (launch={launchGame})");

        var events = Path.Combine(Home, "events.txt");
        File.WriteAllText(events, "");
        var sm = FindSpiderMan();
        if (sm == null) { Log("Marvel's Spider-Man Remastered folder not found; audio disabled"); WriteStatus("no-spiderman"); }
        else File.WriteAllText(Path.Combine(Home, "spiderman_dir.txt"), sm);

        if (launchGame) StartGame();

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

        // wait for the game, then run until it has been closed for a few seconds
        if (!GameRunning() && !WaitForGameStart()) return 1;
        Log("game running");

        CuePlayer? player = null;
        try { if (cache != null) player = new CuePlayer(cache, Log); }
        catch (Exception ex) { Log("audio output failed, sounds off: " + ex.Message); }
        using var _ = player;
        GC.Collect(2, GCCollectionMode.Aggressive, true, true); // drop archive/bank buffers from the cache build
        WriteStatus(player != null ? "ready" : "no-audio");
        long readPos = 0;
        var lastBeat = DateTime.MinValue;
        var lastSeen = DateTime.UtcNow;
        var lastCheck = DateTime.UtcNow;
        while ((DateTime.UtcNow - lastSeen).TotalSeconds < 10)
        {
            if ((DateTime.UtcNow - lastCheck).TotalSeconds >= 1)
            {
                lastCheck = DateTime.UtcNow;
                if (GameRunning()) lastSeen = lastCheck;
            }
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
