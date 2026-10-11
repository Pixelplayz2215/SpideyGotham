using System.Runtime.InteropServices;

namespace SpideyLink;

// Small waveOut mixer: one looping music bed with fades, plus one-shot voice lines and effects.
public sealed class Mixer : IDisposable
{
    const int Rate = AudioCache.Rate, FramesPerBuf = 960, NumBufs = 6; // 20 ms buffers
    [StructLayout(LayoutKind.Sequential)] struct WAVEFORMATEX { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }
    [StructLayout(LayoutKind.Sequential)] struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }
    [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr h, int dev, ref WAVEFORMATEX fmt, IntPtr cb, IntPtr inst, int flags);
    [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr h);
    const uint WHDR_DONE = 1;

    readonly IntPtr _h;
    readonly IntPtr[] _hdrs = new IntPtr[NumBufs], _data = new IntPtr[NumBufs];
    readonly Thread _thread;
    volatile bool _run = true;
    readonly object _lock = new();

    float[]? _music; long _musicPos; float _musicVol, _musicTarget, _musicMax = 0.55f;
    readonly List<(float[] s, long pos, float vol)> _voices = new();
    float _duck = 1f; // music gain under voice lines
    public float MasterVolume = 1f;

    public Mixer()
    {
        var fmt = new WAVEFORMATEX { wFormatTag = 1, nChannels = 2, nSamplesPerSec = Rate, wBitsPerSample = 16, nBlockAlign = 4, nAvgBytesPerSec = Rate * 4 };
        int r = waveOutOpen(out _h, -1, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
        if (r != 0) throw new InvalidOperationException($"waveOutOpen failed ({r})");
        int hs = Marshal.SizeOf<WAVEHDR>();
        for (int i = 0; i < NumBufs; i++)
        {
            _data[i] = Marshal.AllocHGlobal(FramesPerBuf * 4);
            _hdrs[i] = Marshal.AllocHGlobal(hs);
            Marshal.StructureToPtr(new WAVEHDR { lpData = _data[i], dwBufferLength = FramesPerBuf * 4, dwFlags = WHDR_DONE }, _hdrs[i], false);
        }
        _thread = new Thread(Loop) { IsBackground = true, Priority = ThreadPriority.AboveNormal, Name = "SpideyMixer" };
        _thread.Start();
    }

    public void SetMusic(float[] stereo, float maxVol) { lock (_lock) { _music = stereo; _musicMax = maxVol; } }
    public void MusicOn() { lock (_lock) _musicTarget = _musicMax; }
    public void MusicOff() { lock (_lock) _musicTarget = 0; }
    public bool VoiceBusy { get { lock (_lock) return _voices.Count > 0; } }
    public void Play(float[] stereo, float vol) { lock (_lock) _voices.Add((stereo, 0, vol)); }

    void Loop()
    {
        int hs = Marshal.SizeOf<WAVEHDR>();
        var mix = new float[FramesPerBuf * 2];
        var pcm = new short[FramesPerBuf * 2];
        while (_run)
        {
            bool wrote = false;
            for (int i = 0; i < NumBufs; i++)
            {
                var hdr = Marshal.PtrToStructure<WAVEHDR>(_hdrs[i]);
                if ((hdr.dwFlags & WHDR_DONE) == 0) continue;
                if ((hdr.dwFlags & 2) != 0) waveOutUnprepareHeader(_h, _hdrs[i], hs); // WHDR_PREPARED
                Fill(mix);
                for (int k = 0; k < mix.Length; k++) pcm[k] = (short)Math.Clamp(mix[k] * MasterVolume * 32767f, -32768f, 32767f);
                Marshal.Copy(pcm, 0, _data[i], pcm.Length);
                Marshal.StructureToPtr(new WAVEHDR { lpData = _data[i], dwBufferLength = FramesPerBuf * 4 }, _hdrs[i], false);
                waveOutPrepareHeader(_h, _hdrs[i], hs);
                waveOutWrite(_h, _hdrs[i], hs);
                wrote = true;
            }
            if (!wrote) Thread.Sleep(4);
        }
    }

    void Fill(float[] mix)
    {
        Array.Clear(mix);
        lock (_lock)
        {
            float fadeStep = 1f / (Rate * 1.5f); // 1.5 s fades
            float duckTarget = _voices.Count > 0 ? 0.4f : 1f, duckStep = 1f / (Rate * 0.15f);
            if (_music != null && (_musicVol > 0 || _musicTarget > 0))
            {
                for (int f = 0; f < FramesPerBuf; f++)
                {
                    if (_musicVol < _musicTarget) _musicVol = Math.Min(_musicTarget, _musicVol + fadeStep);
                    else if (_musicVol > _musicTarget) _musicVol = Math.Max(_musicTarget, _musicVol - fadeStep);
                    _duck += Math.Clamp(duckTarget - _duck, -duckStep, duckStep);
                    mix[f * 2] += _music[_musicPos * 2] * _musicVol * _duck;
                    mix[f * 2 + 1] += _music[_musicPos * 2 + 1] * _musicVol * _duck;
                    if (++_musicPos * 2 >= _music.Length) _musicPos = 0;
                }
            }
            for (int v = _voices.Count - 1; v >= 0; v--)
            {
                var (s, pos, vol) = _voices[v];
                int n = (int)Math.Min(FramesPerBuf, s.Length / 2 - pos);
                for (int f = 0; f < n; f++) { mix[f * 2] += s[(pos + f) * 2] * vol; mix[f * 2 + 1] += s[(pos + f) * 2 + 1] * vol; }
                pos += n;
                if (pos * 2 >= s.Length) _voices.RemoveAt(v); else _voices[v] = (s, pos, vol);
            }
        }
    }

    public void Dispose()
    {
        _run = false; _thread.Join(500);
        waveOutReset(_h);
        int hs = Marshal.SizeOf<WAVEHDR>();
        for (int i = 0; i < NumBufs; i++) { waveOutUnprepareHeader(_h, _hdrs[i], hs); Marshal.FreeHGlobal(_hdrs[i]); Marshal.FreeHGlobal(_data[i]); }
        waveOutClose(_h);
    }
}
