// The microphone for an annotation session: the original samples go to 原始录音.wav unchanged (the device's own
// rate, channels and 32-bit float, like the macOS app), and a 16 kHz mono 16-bit copy goes to 实时语音/audio.pcm for
// the caption model. Writes happen on one worker, never in the capture callback. While paused nothing is written.
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

    WasapiCapture? capture;
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
    public bool ArchiveIncomplete { get; private set; }

    public bool Running => capture?.CaptureState == CaptureState.Capturing;
    /// seconds of audio actually written to the archive
    public double Seconds { get { lock (lockObj) return format == null ? 0 : framesWritten / (double)format.SampleRate; } }
    public string? LivePcmPath { get; private set; }

    /// Opens the default microphone. Throws with a sentence for the user when it can't.
    public void Start(string archivePath, string? livePcmPath)
    {
        var device = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
        capture = new WasapiCapture(device, useEventSync: true, audioBufferMillisecondsLength: 50);
        format = capture.WaveFormat;
        archive = new WaveFileWriter(archivePath, WaveFormat.CreateIeeeFloatWaveFormat(format.SampleRate, format.Channels));
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
            if (paused || e.BytesRecorded == 0) return;
            var copy = new byte[e.BytesRecorded];
            Buffer.BlockCopy(e.Buffer, 0, copy, 0, e.BytesRecorded);
            if (!queue.TryAdd(copy))
            {
                ArchiveIncomplete = true;
                OnFailure?.Invoke("音频保存跟不上麦克风，录音可能不完整；已接收的录音和实时文字会保留。");
            }
        };
        capture.RecordingStopped += (_, e) =>
        {
            if (e.Exception != null) OnFailure?.Invoke("麦克风中断：" + e.Exception.Message);
        };
        capture.StartRecording();
    }

    public void SetPaused(bool value) => paused = value;

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
            var samples = ToFloats(data);
            var channels = format!.Channels;
            var frames = samples.Length / channels;
            try
            {
                lock (lockObj)
                {
                    archive?.WriteSamples(samples, 0, frames * channels);
                    framesWritten += frames;
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
            if (livePcm != null && resampler != null && frames > 0) WriteLive(samples, frames, channels);
        }
    }

    void WriteLive(float[] samples, int frames, int channels)
    {
        var mono = new float[frames];
        for (var i = 0; i < frames; i++)
        {
            float s = 0;
            for (var c = 0; c < channels; c++) s += samples[i * channels + c];
            mono[i] = s / channels;
        }
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
        try { capture?.StopRecording(); } catch { }
        // let the last buffers arrive
        Thread.Sleep(80);
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
