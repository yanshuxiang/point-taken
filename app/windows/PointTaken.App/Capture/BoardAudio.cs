// The microphone for an annotation session: the samples go to 原始录音.wav at the device's own rate as 16-bit mono —
// a quarter of the 32-bit float stereo the device delivers (8 minutes: about 46 MB, not 184 MB), nothing a speech
// model or a listener can tell apart — and a 16 kHz mono 16-bit copy goes to 实时语音/audio.pcm for the caption
// model. Writes happen on one worker, never in the capture callback. While paused (or the microphone is off) nothing
// is written; where recording resumes, 2 s of silence goes in (BoardTranscript.TakeGap), so a take never runs into the next one (the final
// pass hears a pause there) and Breaks says where each new take begins.
using System.Collections.Concurrent;
using NAudio.CoreAudioApi;
using NAudio.Dsp;
using NAudio.Wave;

namespace PointTaken.App.Capture;

public sealed class BoardAudio : IDisposable
{
    public Action<float>? OnLevel;
    public Action<string>? OnFailure;
    public Action<string>? OnWriteWarning;

    IWaveIn? capture;
    volatile bool capturing;
    WaveFileWriter? archive;
    FileStream? livePcm;
    WdlResampler? resampler;
    readonly BlockingCollection<byte[]> queue = new(boundedCapacity: 2000);
    Thread? worker;
    volatile bool paused;
    WaveFormat? format;
    long framesWritten;
    readonly object lockObj = new();
    bool warned;
    readonly ManualResetEventSlim stopped = new(false);
    volatile bool stopping;
    bool started;
    bool dropWarned;
    public bool ArchiveIncomplete { get; private set; }

    public bool Running => capturing;
    /// seconds of audio actually written to the archive
    public double Seconds { get { lock (lockObj) return format == null ? 0 : framesWritten / (double)format.SampleRate; } }
    public string? LivePcmPath { get; private set; }

    /// Opens the default microphone. Throws with a sentence for the user when it can't.
    public void Start(string archivePath, string? livePcmPath)
    {
        // POINT_TAKEN_TEST_MIC=<a WAV>: that recording is played in real time in place of the microphone — for testing
        // the whole session with real speech on a machine whose speakers don't reach its microphone
        if (Environment.GetEnvironmentVariable("POINT_TAKEN_TEST_MIC") is { Length: > 0 } testMic) capture = new FileMic(testMic);
        else
        {
            var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
            capture = new WasapiCapture(device, useEventSync: true, audioBufferMillisecondsLength: 50);
        }
        format = capture.WaveFormat;
        archive = new WaveFileWriter(archivePath, new WaveFormat(format.SampleRate, 16, 1));
        if (livePcmPath != null)
        {
            LivePcmPath = livePcmPath;
            livePcm = new FileStream(livePcmPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            resampler = new WdlResampler();
            resampler.SetMode(true, 2, false);
            resampler.SetFilterParms();
            resampler.SetFeedMode(true);
            resampler.SetRates(format.SampleRate, 16000);
        }
        worker = new Thread(Drain) { IsBackground = true, Name = "point-taken audio writer" };
        worker.Start();
        capture.DataAvailable += (_, e) =>
        {
            if (paused || e.BytesRecorded == 0 || queue.IsAddingCompleted) return;
            var copy = new byte[e.BytesRecorded];
            Buffer.BlockCopy(e.Buffer, 0, copy, 0, e.BytesRecorded);
            bool added;
            try { added = queue.TryAdd(copy); } catch (InvalidOperationException) { return; }   // closed meanwhile: the stop owns the end
            if (!added)
            {
                ArchiveIncomplete = true;
                if (!dropWarned) { dropWarned = true; OnFailure?.Invoke("音频保存跟不上麦克风，录音可能不完整；已接收的录音和实时文字会保留。"); }
            }
        };
        capture.RecordingStopped += (_, e) =>
        {
            capturing = false;
            stopped.Set();
            // a stop we asked for is not an interruption
            if (e.Exception != null && !stopping) OnFailure?.Invoke("麦克风中断：" + e.Exception.Message);
        };
        capture.StartRecording();
        capturing = true;
        started = true;
    }

    public void SetPaused(bool value)
    {
        // the gap goes in the queue, after whatever was recorded before the pause
        if (paused && !value && started) { try { queue.TryAdd(Array.Empty<byte>()); } catch (InvalidOperationException) { } }
        paused = value;
    }

    const double GapSeconds = PointTaken.Core.BoardTranscript.TakeGap;
    readonly List<double> breaks = new();
    /// the recording's seconds where a take begins after a pause (each after its gap of silence)
    public List<double> Breaks { get { lock (lockObj) return breaks.ToList(); } }

    /// Converts one capture buffer to float samples whatever the device format is.
    float[] ToFloats(byte[] data)
    {
        var f = format!;
        if (f.Encoding == WaveFormatEncoding.IeeeFloat || (f is WaveFormatExtensible x && x.SubFormat == NAudio.Dmo.AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT))
        {
            var r = new float[data.Length / 4];
            Buffer.BlockCopy(data, 0, r, 0, r.Length * 4);
            return r;
        }
        switch (f.BitsPerSample)
        {
            case 16:
            {
                var r = new float[data.Length / 2];
                for (var i = 0; i < r.Length; i++) r[i] = BitConverter.ToInt16(data, i * 2) / 32768f;
                return r;
            }
            case 24:
            {
                var r = new float[data.Length / 3];
                for (var i = 0; i < r.Length; i++) r[i] = ((data[i * 3] << 8 | data[i * 3 + 1] << 16 | data[i * 3 + 2] << 24) >> 8) / 8388608f;
                return r;
            }
            case 32:
            {
                var r = new float[data.Length / 4];
                for (var i = 0; i < r.Length; i++) r[i] = BitConverter.ToInt32(data, i * 4) / 2147483648f;
                return r;
            }
            default: return Array.Empty<float>();
        }
    }

    void Drain()
    {
        var tick = 0;
        foreach (var data in queue.GetConsumingEnumerable())
        {
            var channels = format!.Channels;
            float[] samples;
            if (data.Length == 0)
            {
                // a take resumes: quiet between it and the one before — the room's own hiss, not digital zeros: where
                // zeros give way to the room again the VAD hears a sound start, and the models wrote "Yeah." / "嗯。"
                // for it (measured on a silent take: nothing with the hiss)
                lock (lockObj) if (framesWritten == 0) continue;
                samples = RoomTone((int)(format.SampleRate * GapSeconds), channels);
            }
            else samples = ToFloats(data);
            var frames = samples.Length / channels;
            var mono = Mono(samples, frames, channels);
            if (data.Length > 0) Listen(mono, frames);
            // NAudio writes 16-bit samples without clamping: an over-full peak would wrap round
            for (var i = 0; i < frames; i++) mono[i] = Math.Clamp(mono[i], -1f, 1f);
            try
            {
                lock (lockObj)
                {
                    archive?.WriteSamples(mono, 0, frames);
                    framesWritten += frames;
                    if (data.Length == 0) breaks.Add(framesWritten / (double)format.SampleRate);
                }
            }
            catch (Exception e)
            {
                ArchiveIncomplete = true;
                if (!warned) { warned = true; OnWriteWarning?.Invoke("原始录音部分写入失败，录音可能不完整：" + e.Message); }
            }
            // level: RMS of the first channel, every other buffer
            if (++tick % 2 == 0 && frames > 0)
            {
                double sum = 0;
                for (var i = 0; i < frames; i++) { var v = samples[i * channels]; sum += v * v; }
                OnLevel?.Invoke((float)Math.Sqrt(sum / frames));
            }
            if (livePcm != null && resampler != null && frames > 0) WriteLive(mono, frames);
        }
    }

    /// the room's noise floor (RMS): the quietest buffers heard, rising only slowly with louder ones
    double floor = double.NaN;
    readonly Random hiss = new(7);

    void Listen(float[] mono, int frames)
    {
        if (frames == 0) return;
        double sum = 0;
        for (var i = 0; i < frames; i++) sum += mono[i] * mono[i];
        var rms = Math.Sqrt(sum / frames);
        if (rms < 1e-5) return;              // a driver's buffer of zeros is no measure of the room
        floor =double.IsNaN(floor) || rms < floor ? rms : floor + (rms - floor) * 0.002;
    }

    /// `frames` of noise at the room's level (-80 to -40 dBFS), the same in every channel, so the gap sounds like the
    /// quiet around it once mixed to mono.
    float[] RoomTone(int frames, int channels)
    {
        var level = Math.Clamp(double.IsNaN(floor) ? 0.0005 : floor, 0.0001, 0.01);
        var r = new float[frames * channels];
        for (var f = 0; f < frames; f++)
        {
            // Box–Muller: a normal sample from two uniform ones
            double u = 1 - hiss.NextDouble(), v = hiss.NextDouble();
            var s = (float)(Math.Sqrt(-2 * Math.Log(u)) * Math.Cos(2 * Math.PI * v) * level);
            for (var c = 0; c < channels; c++) r[f * channels + c] = s;
        }
        return r;
    }

    static float[] Mono(float[] samples, int frames, int channels)
    {
        if (channels == 1) return (float[])samples.Clone();
        var mono = new float[frames];
        for (var i = 0; i < frames; i++)
        {
            float s = 0;
            for (var c = 0; c < channels; c++) s += samples[i * channels + c];
            mono[i] = s / channels;
        }
        return mono;
    }

    void WriteLive(float[] mono, int frames)
    {
        var need = resampler!.ResamplePrepare(frames, 1, out var inBuf, out var inOff);
        Array.Copy(mono, 0, inBuf, inOff, Math.Min(need, frames));
        var outMax = frames * 16000 / format!.SampleRate + 64;
        var outBuf = new float[outMax];
        var produced = resampler.ResampleOut(outBuf, 0, need, outMax, 1);
        var bytes = new byte[produced * 2];
        for (var i = 0; i < produced; i++)
        {
            var v = (short)Math.Clamp((int)Math.Round(outBuf[i] * 32767), short.MinValue, short.MaxValue);
            bytes[i * 2] = (byte)v; bytes[i * 2 + 1] = (byte)(v >> 8);
        }
        try { livePcm!.Write(bytes); livePcm.Flush(); }
        catch { /* the live captions lose a piece; the archive is unaffected */ }
    }

    /// Stops the microphone, writes what is queued, closes both files. Returns when everything is on disk.
    public void Stop()
    {
        stopping = true;
        if (!started) stopped.Set();
        try { capture?.StopRecording(); } catch { stopped.Set(); }
        // the last buffers arrive before RecordingStopped; only then is the queue closed
        stopped.Wait(TimeSpan.FromSeconds(3));
        queue.CompleteAdding();
        worker?.Join(TimeSpan.FromSeconds(10));
        lock (lockObj)
        {
            try { archive?.Dispose(); } catch { }
            archive = null;
        }
        try { livePcm?.Dispose(); } catch { }
        livePcm = null;
        capture?.Dispose(); capture = null;
    }

    public void Dispose() { if (capture != null) Stop(); }

    /// The original recording as a 16 kHz mono 16-bit WAV (written next to it first, then moved into place).
    public static bool Resample16k(string source, string wavPath)
    {
        var tmp = wavPath + ".tmp";
        try
        {
            using (var reader = new WaveFileReader(source))
            {
                var samples = reader.ToSampleProvider();
                ISampleProvider mono = samples.WaveFormat.Channels switch
                {
                    1 => samples,
                    2 => new NAudio.Wave.SampleProviders.StereoToMonoSampleProvider(samples),
                    _ => new NAudio.Wave.SampleProviders.MultiplexingSampleProvider(new[] { samples }, 1),
                };
                var resampled = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(mono, 16000);
                WaveFileWriter.CreateWaveFile16(tmp, resampled);
            }
            File.Move(tmp, wavPath, overwrite: true);
            return true;
        }
        catch { try { File.Delete(tmp); } catch { } return false; }
    }

    /// A 16 kHz mono 16-bit WAV of the raw PCM (the final pass reads it without ffmpeg).
    public static bool WrapPcmAsWav(string pcmPath, string wavPath)
    {
        try
        {
            var data = File.ReadAllBytes(pcmPath);
            using var w = new WaveFileWriter(wavPath, new WaveFormat(16000, 16, 1));
            w.Write(data, 0, data.Length);
            return true;
        }
        catch { return false; }
    }
}

/// A WAV file played in real time, 50 ms at a time, as if it were the microphone (POINT_TAKEN_TEST_MIC); silence after
/// its end. Only for tests.
sealed class FileMic : IWaveIn
{
    readonly WaveFileReader reader;
    Thread? thread;
    volatile bool running;
    public WaveFormat WaveFormat { get => reader.WaveFormat; set { } }
    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    public FileMic(string path) { reader = new WaveFileReader(path); }

    public void StartRecording()
    {
        running = true;
        thread = new Thread(() =>
        {
            var chunk = reader.WaveFormat.AverageBytesPerSecond / 20 / reader.WaveFormat.BlockAlign * reader.WaveFormat.BlockAlign;
            var buffer = new byte[chunk];
            var clock = System.Diagnostics.Stopwatch.StartNew();
            long sent = 0;
            while (running)
            {
                var n = reader.Read(buffer, 0, chunk);
                if (n < chunk) Array.Clear(buffer, n, chunk - n);
                DataAvailable?.Invoke(this, new WaveInEventArgs(buffer, chunk));
                sent += chunk;
                var due = sent * 1000.0 / reader.WaveFormat.AverageBytesPerSecond - clock.Elapsed.TotalMilliseconds;
                if (due > 0) Thread.Sleep((int)due);
            }
            RecordingStopped?.Invoke(this, new StoppedEventArgs());
        }) { IsBackground = true, Name = "point-taken test microphone" };
        thread.Start();
    }

    public void StopRecording() => running = false;
    public void Dispose() { running = false; thread?.Join(2000); reader.Dispose(); }
}
