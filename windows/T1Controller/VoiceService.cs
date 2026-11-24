using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace T1Controller;

internal sealed record Microphone(string Id, string Name);

internal sealed class VoiceService(Settings settings) : IDisposable
{
    internal sealed record Recognizer(string Executable, string Model);

    private sealed class Recording(WasapiCapture capture, MMDevice endpoint, string owner, Recognizer? recognizer) : IDisposable
    {
        public readonly WasapiCapture Capture = capture;
        public readonly MMDevice Endpoint = endpoint;
        public readonly string Owner = owner;
        public readonly Recognizer? Speech = recognizer;
        public readonly MemoryStream Buffer = new();
        public readonly TaskCompletionSource<StoppedEventArgs> Stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly CancellationTokenSource Cancellation = new();
        public readonly long Started = Stopwatch.GetTimestamp();
        public bool Finishing;
        public bool Pulse;
        public long LastSignal;

        public void Dispose()
        {
            Capture.Dispose();
            Endpoint.Dispose();
            Buffer.Dispose();
            Cancellation.Dispose();
        }
    }

    private Recording? current;
    public event Action<string>? Status;
    public event Action<string>? Transcribed;

    public Recognizer? FindRecognizer()
    {
        var directory = Path.Combine(AppContext.BaseDirectory, "Speech");
        var executable = string.IsNullOrWhiteSpace(settings.WhisperExecutable)
            ? Path.Combine(directory, "whisper-cli.exe") : settings.WhisperExecutable;
        var model = string.IsNullOrWhiteSpace(settings.WhisperModel)
            ? Path.Combine(directory, "ggml-small-q5_1.bin") : settings.WhisperModel;
        return File.Exists(executable) && File.Exists(model) ? new(executable, model) : null;
    }

    public static Microphone[] ListMicrophones()
    {
        using var enumerator = new MMDeviceEnumerator();
        var endpoints = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
        return endpoints.Select(endpoint =>
        {
            using (endpoint)
                return new Microphone(endpoint.ID, endpoint.FriendlyName);
        }).OrderBy(microphone => microphone.Name).ToArray();
    }

    public string? Owner => current?.Owner;

    public bool EndPulseOnNextPress(string owner)
    {
        if (current is not { Pulse: true, Finishing: false } recording || recording.Owner != owner)
            return false;
        _ = Finish(owner);
        return true;
    }

    public void Release(string owner, bool allowPulse)
    {
        var session = current;
        if (session is null || session.Owner != owner || session.Finishing || session.Pulse)
            return;
        if (allowPulse && session.Endpoint.FriendlyName.Contains("Mic Device", StringComparison.OrdinalIgnoreCase) &&
            Stopwatch.GetElapsedTime(session.Started) < TimeSpan.FromMilliseconds(220))
        {
            session.Pulse = true;
            Status?.Invoke("T1 正在收音。说完后会自动识别，也可以再按一次语音键。");
            _ = FinishPulse(session);
            return;
        }
        _ = Finish(owner);
    }

    public void Start(string owner, bool probe)
    {
        if (current is not null)
            return;
        var recognizer = probe ? null : FindRecognizer();
        if (!probe && recognizer is null)
        {
            Status?.Invoke("请先选择 whisper-cli.exe 和中文多语种模型。");
            return;
        }

        Recording? recording = null;
        MMDevice? endpoint = null;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            endpoint = settings.MicrophoneId is { Length: > 0 } id
                ? enumerator.GetDevice(id)
                : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
            var capture = new WasapiCapture(endpoint, true, 50);
            recording = new Recording(capture, endpoint, owner, recognizer);
            var session = recording;
            var max = capture.WaveFormat.AverageBytesPerSecond * 16L;
            capture.DataAvailable += (_, args) =>
            {
                lock (session.Buffer)
                {
                    if (session.Buffer.Length + args.BytesRecorded <= max)
                        session.Buffer.Write(args.Buffer, 0, args.BytesRecorded);
                }
                if (HasSignal(args.Buffer, args.BytesRecorded, capture.WaveFormat))
                    Interlocked.Exchange(ref session.LastSignal, Stopwatch.GetTimestamp());
            };
            capture.RecordingStopped += (_, args) =>
            {
                session.Stopped.TrySetResult(args);
                if (!session.Finishing)
                    _ = Finish(owner, cancel: true);
            };
            current = session;
            capture.StartRecording();
            Status?.Invoke($"正在收音 · {endpoint.FriendlyName}");
            _ = Expire(session);
        }
        catch (Exception exception) when (exception is InvalidOperationException or ArgumentException or
                                          System.Runtime.InteropServices.COMException)
        {
            current = null;
            if (recording is not null)
                recording.Dispose();
            else
                endpoint?.Dispose();
            Status?.Invoke($"无法从所选麦克风录音。{exception.Message}");
        }
    }

    public async Task Finish(string owner, bool cancel = false)
    {
        var session = current;
        if (session is null || session.Owner != owner)
            return;
        if (cancel)
            session.Cancellation.Cancel();
        if (session.Finishing)
            return;
        session.Finishing = true;
        var held = Stopwatch.GetElapsedTime(session.Started);
        try
        {
            session.Capture.StopRecording();
            var ended = await session.Stopped.Task.WaitAsync(TimeSpan.FromSeconds(3));
            if (ended.Exception is not null)
                throw new InvalidOperationException("录音设备断开或读取失败。", ended.Exception);
            if (session.Cancellation.IsCancellationRequested)
            {
                Status?.Invoke("已取消录音。");
                return;
            }
            if (held < TimeSpan.FromMilliseconds(220))
            {
                Status?.Invoke("按住说话，松开后识别。");
                return;
            }

            byte[] recorded;
            lock (session.Buffer)
                recorded = session.Buffer.ToArray();
            var (wave, rms) = MakeWhisperWave(recorded, session.Capture.WaveFormat);
            if (session.Speech is not { } recognizer)
            {
                Status?.Invoke($"试录完成 · {session.Endpoint.FriendlyName} · RMS {rms:P1}");
                return;
            }
            if (rms < 0.002)
            {
                Status?.Invoke("音频电平过低，请检查飞鼠或所选麦克风。");
                return;
            }

            Status?.Invoke("正在本地识别…");
            var text = await Transcribe(recognizer, wave, session.Cancellation.Token);
            if (!session.Cancellation.IsCancellationRequested)
            {
                Status?.Invoke(text.Length == 0 ? "没有识别到清晰的指令。" : $"识别到「{text}」");
                if (text.Length > 0)
                    Transcribed?.Invoke(text);
            }
        }
        catch (OperationCanceledException)
        {
            Status?.Invoke("识别已取消或超时。");
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException or TimeoutException or NotSupportedException or
                                          System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
        {
            Status?.Invoke($"语音操作失败。{exception.Message}");
        }
        finally
        {
            current = null;
            session.Dispose();
        }
    }

    private async Task Expire(Recording session)
    {
        await Task.Delay(TimeSpan.FromSeconds(15));
        if (current == session && !session.Finishing)
            await Finish(session.Owner, cancel: true);
    }

    private async Task FinishPulse(Recording session)
    {
        while (current == session && !session.Finishing)
        {
            await Task.Delay(100);
            if (current != session || session.Finishing) return;
            var last = Interlocked.Read(ref session.LastSignal);
            if (last > 0 && Stopwatch.GetElapsedTime(last) >= TimeSpan.FromMilliseconds(750))
            {
                await Finish(session.Owner);
                return;
            }
            var elapsed = Stopwatch.GetElapsedTime(session.Started);
            if (elapsed >= TimeSpan.FromSeconds(7) || (last == 0 && elapsed >= TimeSpan.FromSeconds(5)))
            {
                await Finish(session.Owner);
                return;
            }
        }
    }

    private static bool HasSignal(byte[] buffer, int length, WaveFormat format)
    {
        if (format.BitsPerSample == 16)
        {
            for (var i = 0; i + 1 < length; i += 2)
                if (Math.Abs((int)BitConverter.ToInt16(buffer, i)) > 560) return true;
        }
        else if (format.BitsPerSample == 32 && (format.Encoding == WaveFormatEncoding.IeeeFloat ||
                 (format is WaveFormatExtensible ext && ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71"))))
        {
            for (var i = 0; i + 3 < length; i += 4)
            {
                var sample = BitConverter.ToSingle(buffer, i);
                if (float.IsFinite(sample) && Math.Abs(sample) > .017f) return true;
            }
        }
        return false;
    }

    private static (byte[] Wave, double Rms) MakeWhisperWave(byte[] recorded, WaveFormat format)
    {
        using var raw = new RawSourceWaveStream(new MemoryStream(recorded), format);
        var resampler = new WdlResamplingSampleProvider(raw.ToSampleProvider(), 16000);
        var channels = resampler.WaveFormat.Channels;
        var samples = new float[channels * 1024];
        var wave = new MemoryStream();
        double squareSum = 0;
        var frames = 0;
        using (var writer = new WaveFileWriter(wave, new WaveFormat(16000, 16, 1)))
        {
            int count;
            while ((count = resampler.Read(samples, 0, samples.Length)) > 0)
            {
                for (var index = 0; index + channels <= count; index += channels)
                {
                    var mono = 0f;
                    for (var channel = 0; channel < channels; channel++)
                        mono += samples[index + channel];
                    mono /= channels;
                    squareSum += mono * mono;
                    frames++;
                    writer.WriteSample(mono);
                }
            }
        }
        return (wave.ToArray(), frames == 0 ? 0 : Math.Sqrt(squareSum / frames));
    }

    private static async Task<string> Transcribe(Recognizer recognizer, byte[] wav, CancellationToken token)
    {
        var start = new ProcessStartInfo(recognizer.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8
        };
        // With stdin input, whisper-cli otherwise treats '-' as its output target and disables its stdout callback.
        foreach (var argument in new[] { "-m", recognizer.Model, "-l", "zh", "-nt", "-np", "-f", "-", "-of", "transcript" })
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动 whisper-cli。");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(45));
        using var stop = deadline.Token.Register(() => StopProcess(process));
        var output = process.StandardOutput.ReadToEndAsync(deadline.Token);
        var errors = process.StandardError.ReadToEndAsync(deadline.Token);
        try
        {
            await process.StandardInput.BaseStream.WriteAsync(wav, deadline.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            var errorText = await errors;
            if (process.ExitCode != 0)
                throw new InvalidOperationException($"whisper-cli 返回 {process.ExitCode}。{errorText.Split('\n').FirstOrDefault(line => line.Contains("error", StringComparison.OrdinalIgnoreCase))}");
            var text = (await output).Trim();
            return Microsoft.VisualBasic.Strings.StrConv(text, Microsoft.VisualBasic.VbStrConv.SimplifiedChinese, 2052) ?? text;
        }
        finally
        {
            StopProcess(process);
        }
    }

    private static void StopProcess(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // The recognition process can exit before or during cleanup.
        }
    }

    public void Dispose()
    {
        if (current is { } session)
            _ = Finish(session.Owner, cancel: true);
    }
}
