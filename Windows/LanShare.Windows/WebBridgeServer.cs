using System.Net;
using System.Net.Sockets;
using System.Text;

namespace LanShare.Windows;

internal sealed class WebBridgeServer : IDisposable
{
    private readonly CancellationTokenSource _stop = new();
    private TcpListener? _listener;
    private Func<string?>? _sharedFile;
    public event Action<string>? FileReceived;

    public void Start(Func<string?> sharedFile)
    {
        _sharedFile = sharedFile;
        try
        {
            _listener = new TcpListener(IPAddress.Any, 52521);
            _listener.Start();
            _ = AcceptLoop();
        }
        catch { }
    }

    private async Task AcceptLoop()
    {
        while (!_stop.IsCancellationRequested && _listener is not null)
        {
            try
            {
                var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                _ = Task.Run(() => Handle(client));
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
        }
    }

    private async Task Handle(TcpClient client)
    {
        using (client)
        {
            var stream = client.GetStream();
            stream.ReadTimeout = 120_000;
            var header = new List<byte>(1024);
            var ending = new byte[] { 13, 10, 13, 10 };
            var matched = 0;
            while (header.Count < 32 * 1024 && matched < ending.Length)
            {
                var one = new byte[1];
                var count = await stream.ReadAsync(one);
                if (count == 0) return;
                header.Add(one[0]);
                matched = one[0] == ending[matched] ? matched + 1 : one[0] == 13 ? 1 : 0;
            }
            if (matched != ending.Length) return;
            var text = Encoding.Latin1.GetString(header.ToArray());
            var lines = text.Split("\r\n");
            var request = lines[0].Split(' ');
            if (request.Length < 2) return;
            var method = request[0];
            var uri = Uri.TryCreate("http://localhost" + request[1], UriKind.Absolute, out var parsed) ? parsed : null;
            if (uri is null) { await Respond(stream, 400, "Bad Request", "잘못된 요청입니다."); return; }
            var length = lines.FirstOrDefault(x => x.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))?
                .Split(':', 2).LastOrDefault()?.Trim();
            var contentLength = long.TryParse(length, out var parsedLength) ? parsedLength : 0;

            if (method == "GET" && uri.AbsolutePath == "/")
            {
                var selected = _sharedFile?.Invoke();
                var download = selected is not null && File.Exists(selected)
                    ? $"<p>선택한 파일: {WebUtility.HtmlEncode(Path.GetFileName(selected))} · <a href='/download'>파일 내려받기</a></p>"
                    : "<p>앱에서 파일을 선택하면 여기서 내려받을 수 있습니다.</p>";
                var html = $"<!doctype html><meta name='viewport' content='width=device-width'><title>LanShare</title><h2>LanShare · Windows</h2>{download}<form id='f'><input id='file' type='file' required><button>이 기기로 보내기</button></form><p id='s'></p><script>f.onsubmit=async e=>{{e.preventDefault();let x=file.files[0];s.textContent='전송 중…';let r=await fetch('/upload?name='+encodeURIComponent(x.name),{{method:'POST',body:x}});s.textContent=r.ok?'전송 완료':'전송 실패'}}</script>";
                await Respond(stream, 200, "OK", html, "text/html; charset=utf-8");
            }
            else if (method == "GET" && uri.AbsolutePath == "/download")
            {
                var file = _sharedFile?.Invoke();
                if (file is null || !File.Exists(file)) { await Respond(stream, 404, "Not Found", "파일이 선택되지 않았습니다."); return; }
                var info = new FileInfo(file);
                var name = Uri.EscapeDataString(info.Name);
                var head = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=UTF-8''{name}\r\nContent-Length: {info.Length}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(head);
                await using var source = File.OpenRead(file);
                await source.CopyToAsync(stream, 64 * 1024, _stop.Token);
            }
            else if (method == "POST" && uri.AbsolutePath == "/upload")
            {
                if (contentLength < 0 || contentLength > 100_000_000_000L) { await Respond(stream, 413, "Payload Too Large", "파일이 너무 큽니다."); return; }
                var nameParameter = uri.Query.TrimStart('?').Split('&').FirstOrDefault(x => x.StartsWith("name=", StringComparison.Ordinal));
                var rawName = nameParameter is null ? "upload.bin" : Uri.UnescapeDataString(nameParameter[5..]);
                var name = Path.GetFileName(rawName);
                if (string.IsNullOrWhiteSpace(name)) name = "upload.bin";
                var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "LanShare");
                Directory.CreateDirectory(folder);
                var target = UniquePath(folder, name);
                var created = false;
                try
                {
                    await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, true);
                    created = true;
                    var buffer = new byte[64 * 1024];
                    var remaining = contentLength;
                    while (remaining > 0)
                    {
                        var count = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), _stop.Token);
                        if (count == 0) throw new EndOfStreamException();
                        await output.WriteAsync(buffer.AsMemory(0, count), _stop.Token);
                        remaining -= count;
                    }
                    FileReceived?.Invoke(Path.GetFileName(target));
                    await Respond(stream, 200, "OK", "전송 완료");
                }
                catch
                {
                    if (created) { try { File.Delete(target); } catch { } }
                    await Respond(stream, 500, "Internal Server Error", "파일을 저장하지 못했습니다.");
                }
            }
            else await Respond(stream, 404, "Not Found", "찾을 수 없습니다.");
        }
    }

    private static async Task Respond(NetworkStream stream, int code, string reason, string body, string type = "text/plain; charset=utf-8")
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {code} {reason}\r\nContent-Type: {type}\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n"));
        await stream.WriteAsync(bytes);
    }

    private static string UniquePath(string folder, string name)
    {
        var stem = Path.GetFileNameWithoutExtension(name);
        var extension = Path.GetExtension(name);
        for (var index = 1; index < 10_000; index++)
        {
            var candidate = Path.Combine(folder, index == 1 ? name : $"{stem} ({index}){extension}");
            if (!File.Exists(candidate)) return candidate;
        }
        return Path.Combine(folder, $"{Guid.NewGuid():N}-{name}");
    }

    public static string? LocalIPv4() => System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses)
        .Select(a => a.Address)
        .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))?.ToString();

    public void Dispose() { _stop.Cancel(); _listener?.Stop(); _stop.Dispose(); }
}
