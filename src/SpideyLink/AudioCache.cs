using System.Diagnostics;
using System.Text.Json;

namespace SpideyLink;

// Pulls every cue's audio out of the player's own Spider-Man Remastered install and decodes it to 48 kHz stereo PCM
// in %LOCALAPPDATA%\SpideyGotham\cache. Nothing from Spider-Man ships with the mod.
public sealed class AudioCache
{
    const int CacheVersion = 5;
    public const int Rate = 48000;
    readonly string _smDir, _cacheDir, _vgm;
    readonly Action<string> _log;
    public Dictionary<string, List<string>> Files = new(); // cue id -> wav paths

    public AudioCache(string spiderManDir, string cacheDir, string vgmstreamCli, Action<string> log)
    { _smDir = spiderManDir; _cacheDir = cacheDir; _vgm = vgmstreamCli; _log = log; }

    string Stamp()
    {
        var toc = new FileInfo(Path.Combine(_smDir, "asset_archive", "toc"));
        // the cue list is part of the stamp: a mod update that adds or changes cues rebuilds the cache
        var cues = string.Join("|", Cues.All.Select(c => $"{c.Id}={c.Bank}/{c.Events}/{string.Join(",", c.Streams)}/{c.MaxClipS}"));
        uint h = 2166136261; foreach (char ch in cues) h = (h ^ ch) * 16777619;
        return $"{CacheVersion}:{toc.Length}:{toc.LastWriteTimeUtc.Ticks}:{h:X8}";
    }

    public void Build()
    {
        Directory.CreateDirectory(_cacheDir);
        var manifestPath = Path.Combine(_cacheDir, "manifest.json");
        var stamp = Stamp();
        if (File.Exists(manifestPath))
        {
            try
            {
                var m = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(manifestPath));
                if (m != null && m.Stamp == stamp && m.Files.Values.SelectMany(x => x).All(File.Exists)) { Files = m.Files; _log($"audio cache ok ({Files.Values.Sum(v => v.Count)} files)"); return; }
            }
            catch { }
        }
        _log("building audio cache from Spider-Man Remastered...");
        using var a = new SpiderManArchive(Path.Combine(_smDir, "asset_archive"));
        var banks = new Dictionary<string, Soundbank>();
        var tmp = Path.Combine(_cacheDir, "tmp"); Directory.CreateDirectory(tmp);
        foreach (var cue in Cues.All)
        {
            var list = new List<string>();
            if (cue.Kind == "music")
            {
                // stems of one piece: decode each, then mix to one stereo loop
                var stems = new List<float[]>();
                foreach (var s in cue.Streams)
                {
                    var wem = a.Read(0xE000000000000000UL | s) ?? throw new InvalidDataException($"music stream {s} missing");
                    stems.Add(Decode(wem, Path.Combine(tmp, $"{s}.wem")));
                }
                int len = stems.Max(x => x.Length);
                var mix = new float[len];
                foreach (var st in stems) for (int i = 0; i < st.Length; i++) mix[i] += st[i];
                Normalize(mix, 0.85f);
                var outPath = Path.Combine(_cacheDir, $"{cue.Id}.pcm");
                WritePcm(outPath, mix);
                list.Add(outPath);
            }
            else if (cue.Events != null)
            {
                if (!banks.TryGetValue(cue.Bank!, out var bank))
                    banks[cue.Bank!] = bank = Soundbank.Parse(a.Read(cue.Bank!) ?? throw new InvalidDataException($"{cue.Bank} missing"));
                foreach (var (name, src) in bank.SourcesForEventPrefix(cue.Events))
                {
                    byte[]? wem = bank.SourceStreamType.GetValueOrDefault(src) == 0 ? bank.EmbeddedWem(src) : a.Read(0xE000000000000000UL | src);
                    if (wem == null) continue;
                    var outPath = Path.Combine(_cacheDir, $"{cue.Id}_{src}.pcm");
                    if (list.Contains(outPath)) continue;
                    try
                    {
                        var pcm = Decode(wem, Path.Combine(tmp, $"{src}.wem"));
                        if (cue.MaxClipS > 0 && pcm.Length / 2.0 / Rate > cue.MaxClipS) continue; // long breaths/loops do not fit the moment
                        Normalize(pcm, 0.95f); // voice lines are mixed quiet in the source; bring each to full level
                        WritePcm(outPath, pcm); list.Add(outPath);
                    }
                    catch (Exception e) { _log($"skip {name}: {e.Message}"); }
                }
            }
            if (list.Count > 0) Files[cue.Id] = list;
            _log($"  {cue.Id}: {list.Count}");
        }
        try { Directory.Delete(tmp, true); } catch { }
        File.WriteAllText(manifestPath, JsonSerializer.Serialize(new Manifest { Stamp = stamp, Files = Files }));
    }

    sealed class Manifest { public string Stamp { get; set; } = ""; public Dictionary<string, List<string>> Files { get; set; } = new(); }

    // wem -> interleaved stereo float at 48 kHz, via vgmstream-cli (decodes Wwise Vorbis/PCM/ADPCM)
    float[] Decode(byte[] wem, string wemPath)
    {
        File.WriteAllBytes(wemPath, wem);
        var wav = Path.ChangeExtension(wemPath, ".wav");
        var psi = new ProcessStartInfo(_vgm) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add(wav); psi.ArgumentList.Add(wemPath);
        using (var p = Process.Start(psi)!) { p.StandardOutput.ReadToEnd(); p.WaitForExit(60000); }
        File.Delete(wemPath);
        if (!File.Exists(wav)) throw new InvalidDataException("decode failed");
        var r = Wav.ReadStereo48k(wav);
        File.Delete(wav);
        return r;
    }

    static void Normalize(float[] s, float peak)
    {
        float m = 0; foreach (var v in s) m = Math.Max(m, Math.Abs(v));
        if (m > 0) { float k = peak / m; for (int i = 0; i < s.Length; i++) s[i] *= k; }
    }

    static void WritePcm(string path, float[] s)
    {
        var b = new byte[s.Length * 4];
        Buffer.BlockCopy(s, 0, b, 0, b.Length);
        File.WriteAllBytes(path, b);
    }

    public static float[] ReadPcm(string path)
    {
        var b = File.ReadAllBytes(path);
        var s = new float[b.Length / 4];
        Buffer.BlockCopy(b, 0, s, 0, s.Length * 4);
        return s;
    }
}

public static class Wav
{
    // Reads a PCM16 (or float32) WAV with any channel count and rate, returns interleaved stereo at 48 kHz.
    public static float[] ReadStereo48k(string path)
    {
        var d = File.ReadAllBytes(path);
        int p = 12, ch = 0, rate = 0, bits = 0, fmt = 0, dataOff = -1, dataLen = 0;
        while (p + 8 <= d.Length)
        {
            string id = System.Text.Encoding.ASCII.GetString(d, p, 4);
            int len = BitConverter.ToInt32(d, p + 4);
            if (id == "fmt ") { fmt = BitConverter.ToUInt16(d, p + 8); ch = BitConverter.ToUInt16(d, p + 10); rate = BitConverter.ToInt32(d, p + 12); bits = BitConverter.ToUInt16(d, p + 22); if (fmt == 0xFFFE) fmt = BitConverter.ToUInt16(d, p + 32); }
            if (id == "data") { dataOff = p + 8; dataLen = Math.Min(len, d.Length - dataOff); break; }
            p += 8 + len + (len & 1);
        }
        if (dataOff < 0 || ch == 0) throw new InvalidDataException("bad wav");
        int bps = bits / 8, frames = dataLen / (bps * ch);
        float S(int f, int c)
        {
            int o = dataOff + (f * ch + c) * bps;
            return fmt == 3 ? BitConverter.ToSingle(d, o) : BitConverter.ToInt16(d, o) / 32768f;
        }
        var st = new float[frames * 2];
        for (int f = 0; f < frames; f++)
        {
            float l, r;
            if (ch == 1) l = r = S(f, 0);
            else if (ch == 4) { l = S(f, 0) + 0.7f * S(f, 2); r = S(f, 1) + 0.7f * S(f, 3); }
            else if (ch >= 6) { float c = 0.7f * S(f, 2); l = S(f, 0) + c + 0.7f * S(f, 4); r = S(f, 1) + c + 0.7f * S(f, 5); }
            else { l = S(f, 0); r = S(f, 1); }
            st[f * 2] = l; st[f * 2 + 1] = r;
        }
        if (rate == AudioCache.Rate) return st;
        // linear resample
        int outFrames = (int)((long)frames * AudioCache.Rate / rate);
        var o2 = new float[outFrames * 2];
        for (int i = 0; i < outFrames; i++)
        {
            double src = (double)i * rate / AudioCache.Rate; int i0 = (int)src; int i1 = Math.Min(i0 + 1, frames - 1); float t = (float)(src - i0);
            o2[i * 2] = st[i0 * 2] * (1 - t) + st[i1 * 2] * t;
            o2[i * 2 + 1] = st[i0 * 2 + 1] * (1 - t) + st[i1 * 2 + 1] * t;
        }
        return o2;
    }
}
