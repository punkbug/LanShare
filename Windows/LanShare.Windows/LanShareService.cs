using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace LanShare.Windows;

internal sealed record Peer(string Id, string Name, IPAddress Address, int Port);
internal sealed record TransferPrompt(string Sender, string FileName, long Size, Action<bool> Respond);
internal sealed record TransferProgress(string Label, long Bytes, long Total);
internal sealed record TransferRequest(int Version, string Sender, string FileName, long Size);

internal sealed class LanShareService : IDisposable
{
    private const string ServiceType = "_lanshare._tcp.local";
    private const string MulticastGroup = "224.0.0.251";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private readonly string _deviceName = Environment.MachineName;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly ConcurrentDictionary<string, (string Host, int Port, DateTime Seen)> _services = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, IPAddress> _addresses = new(StringComparer.OrdinalIgnoreCase);
    private UdpClient? _mdns;
    private TcpListener? _listener;
    private int _port;
    private int _sending;
    public bool IsSending => Volatile.Read(ref _sending) != 0;
    public event Action<IReadOnlyList<Peer>>? PeersChanged;
    public event Action<string>? StatusChanged;
    public event Action<TransferPrompt>? IncomingRequest;
    public event Action<TransferProgress>? ProgressChanged;
    public event Action<string>? TransferCompleted;
    public event Action<string>? Error;

    public async Task StartAsync()
    {
        try
        {
            _listener = new TcpListener(IPAddress.Any, 0);
            _listener.Start();
            _port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _ = AcceptLoopAsync(_lifetime.Token);
            _mdns = new UdpClient(AddressFamily.InterNetwork);
            _mdns.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _mdns.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
            _mdns.JoinMulticastGroup(IPAddress.Parse(MulticastGroup));
            _mdns.Ttl = 255;
            _mdns.MulticastLoopback = false;
            _ = MdnsReceiveLoopAsync(_lifetime.Token);
            _ = MdnsAnnounceLoopAsync(_lifetime.Token);
            Refresh();
            StatusChanged?.Invoke("주변 기기를 검색 중입니다…");
        }
        catch (Exception ex) { Error?.Invoke($"로컬 네트워크 시작 실패: {ex.Message}"); }
        await Task.CompletedTask;
    }

    public void Refresh()
    {
        _services.Clear();
        PublishPeers();
        _ = SendMdnsAsync(BuildBrowseQuery(), _lifetime.Token);
        StatusChanged?.Invoke("주변 기기를 다시 검색 중입니다…");
    }

    private async Task MdnsReceiveLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                var packet = await _mdns!.ReceiveAsync(token);
                var shouldAnswer = ParseMdns(packet.Buffer);
                if (shouldAnswer) await SendMdnsAsync(BuildAnnouncement(), token);
                PublishPeers();
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (Exception ex) { if (!token.IsCancellationRequested) StatusChanged?.Invoke($"기기 검색 오류: {ex.Message}"); }
        }
    }

    private async Task MdnsAnnounceLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            await SendMdnsAsync(BuildAnnouncement(), token);
            await SendMdnsAsync(BuildBrowseQuery(), token);
            foreach (var old in _services.Where(x => DateTime.UtcNow - x.Value.Seen > TimeSpan.FromMinutes(2)).Select(x => x.Key).ToArray()) _services.TryRemove(old, out _);
            PublishPeers();
            try { await Task.Delay(TimeSpan.FromSeconds(30), token); } catch (OperationCanceledException) { break; }
        }
    }

    private async Task SendMdnsAsync(byte[] bytes, CancellationToken token)
    {
        try { if (_mdns is not null) await _mdns.SendAsync(bytes, new IPEndPoint(IPAddress.Parse(MulticastGroup), 5353), token); }
        catch (Exception ex) { if (!token.IsCancellationRequested) StatusChanged?.Invoke($"mDNS 전송 오류: {ex.Message}"); }
    }

    private bool ParseMdns(byte[] packet)
    {
        if (packet.Length < 12) return false;
        var flags = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(2, 2));
        var questions = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(4, 2));
        var answerCount = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(6, 2));
        var authorityCount = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(8, 2));
        var additionalCount = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(10, 2));
        var isQuery = (flags & 0x8000) == 0;
        var browseQuestion = false;
        var offset = 12;
        for (var i = 0; i < questions && offset + 4 <= packet.Length; i++)
        {
            var name = ReadDnsName(packet, ref offset);
            if (offset + 4 > packet.Length) return false;
            var type = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset, 2));
            offset += 4;
            if (name.Equals(ServiceType, StringComparison.OrdinalIgnoreCase) && type == 12) browseQuestion = true;
        }
        var all = new List<(string Name, ushort Type, int DataOffset, int DataLength)>();
        var records = answerCount + authorityCount + additionalCount;
        for (var i = 0; i < records && offset + 10 <= packet.Length; i++)
        {
            var owner = ReadDnsName(packet, ref offset);
            if (offset + 10 > packet.Length) break;
            var type = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset, 2));
            var length = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(offset + 8, 2));
            offset += 10;
            if (offset + length > packet.Length) break;
            all.Add((owner, type, offset, length));
            offset += length;
        }
        var ptrs = new List<(string Instance, int Ttl)>();
        var srvs = new List<(string Owner, string Host, int Port)>();
        foreach (var record in all)
        {
            var normalized = record.Name.TrimEnd('.');
            if (record.Type == 12)
            {
                var ptrOffset = record.DataOffset;
                var target = ReadDnsName(packet, ref ptrOffset).TrimEnd('.');
                if (normalized.Equals(ServiceType.TrimEnd('.'), StringComparison.OrdinalIgnoreCase)) ptrs.Add((target, 120));
            }
            else if (record.Type == 33 && record.DataLength >= 7)
            {
                var data = record.DataOffset;
                var port = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(data + 4, 2));
                var hostOffset = data + 6;
                srvs.Add((normalized, ReadDnsName(packet, ref hostOffset).TrimEnd('.'), port));
            }
            else if (record.Type == 1 && record.DataLength == 4)
                _addresses[normalized] = new IPAddress(packet.AsSpan(record.DataOffset, 4));
        }
        foreach (var ptr in ptrs) _services[ptr.Instance] = ("", 0, DateTime.UtcNow);
        foreach (var srv in srvs)
        {
            var prior = _services.TryGetValue(srv.Owner, out var value) ? value : ("", 0, DateTime.UtcNow);
            _services[srv.Owner] = (srv.Host, srv.Port, DateTime.UtcNow > prior.Seen ? DateTime.UtcNow : prior.Seen);
        }
        foreach (var old in _services.Where(x => DateTime.UtcNow - x.Value.Seen > TimeSpan.FromMinutes(2)).Select(x => x.Key).ToArray()) _services.TryRemove(old, out _);
        return isQuery && browseQuestion;
    }

    private void PublishPeers()
    {
        var suffix = "." + ServiceType;
        var peers = _services.Select(item =>
        {
            var instance = item.Key;
            var value = item.Value;
            if (value.Port == 0 || value.Host.Length == 0 || !_addresses.TryGetValue(value.Host, out var address)) return null;
            var name = instance.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? instance[..^suffix.Length] : instance;
            if (name.Equals(SanitizeInstance(_deviceName), StringComparison.OrdinalIgnoreCase)) return null;
            return new Peer(instance, name, address, value.Port);
        }).Where(x => x is not null).Cast<Peer>().ToArray();
        PeersChanged?.Invoke(peers);
    }

    private byte[] BuildBrowseQuery()
    {
        using var stream = new MemoryStream();
        WriteHeader(stream, 0, 1);
        WriteDnsName(stream, ServiceType);
        WriteUInt16(stream, 12);
        WriteUInt16(stream, 1);
        return stream.ToArray();
    }

    private byte[] BuildAnnouncement()
    {
        var hostAddress = GetLocalAddress();
        var hostName = (Environment.MachineName.Replace('.', '-') + ".local").Trim('.');
        var instance = SanitizeInstance(_deviceName) + "." + ServiceType;
        using var stream = new MemoryStream();
        WriteHeader(stream, 0x8400, 4);
        WriteRecord(stream, ServiceType, 12, body => WriteDnsName(body, instance));
        WriteRecord(stream, instance, 33, body => { WriteUInt16(body, 0); WriteUInt16(body, 0); WriteUInt16(body, (ushort)_port); WriteDnsName(body, hostName); });
        WriteRecord(stream, instance, 16, body => body.WriteByte(0));
        WriteRecord(stream, hostName, 1, body => body.Write(hostAddress.GetAddressBytes()));
        return stream.ToArray();
    }

    private static void WriteHeader(Stream output, ushort flags, ushort answers)
    {
        WriteUInt16(output, 0); WriteUInt16(output, flags); WriteUInt16(output, 0); WriteUInt16(output, answers); WriteUInt16(output, 0); WriteUInt16(output, 0);
    }
    private static void WriteRecord(Stream output, string name, ushort type, Action<Stream> body)
    {
        WriteDnsName(output, name); WriteUInt16(output, type); WriteUInt16(output, type == 12 ? (ushort)1 : (ushort)0x8001); output.Write(new byte[] { 0, 0, 0, 120 });
        using var data = new MemoryStream(); body(data); WriteUInt16(output, (ushort)data.Length); data.Position = 0; data.CopyTo(output);
    }
    private static void WriteDnsName(Stream output, string name)
    {
        foreach (var part in name.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(part);
            if (bytes.Length is 0 or > 63) throw new InvalidDataException("mDNS 이름 길이가 올바르지 않습니다.");
            output.WriteByte((byte)bytes.Length); output.Write(bytes);
        }
        output.WriteByte(0);
    }
    private static string ReadDnsName(byte[] packet, ref int offset)
    {
        var labels = new List<string>(); var cursor = offset; var jumped = false; var safety = 0;
        while (cursor < packet.Length && safety++ < 128)
        {
            var length = packet[cursor++];
            if (length == 0) { if (!jumped) offset = cursor; return string.Join('.', labels); }
            if ((length & 0xC0) == 0xC0)
            {
                if (cursor >= packet.Length) break;
                var pointer = ((length & 0x3F) << 8) | packet[cursor++];
                if (!jumped) { offset = cursor; jumped = true; }
                if (pointer >= packet.Length) break;
                cursor = pointer; continue;
            }
            if ((length & 0xC0) != 0 || cursor + length > packet.Length) break;
            labels.Add(Encoding.UTF8.GetString(packet, cursor, length)); cursor += length;
        }
        if (!jumped) offset = Math.Min(cursor, packet.Length);
        return string.Join('.', labels);
    }
    private static void WriteUInt16(Stream stream, ushort value) { Span<byte> bytes = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(bytes, value); stream.Write(bytes); }
    private static string SanitizeInstance(string name) => name.Replace('.', '-').Trim().Length == 0 ? "LanShare-Windows" : name.Replace('.', '-').Trim();
    private static IPAddress GetLocalAddress()
    {
        var address = NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet)
            .OrderBy(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? 0 : 1)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address)
            .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a) && !a.ToString().StartsWith("169.254.", StringComparison.Ordinal));
        return address ?? IPAddress.Loopback;
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var client = await _listener!.AcceptTcpClientAsync(token);
                _ = HandleIncomingAsync(client, token);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception ex) { if (!token.IsCancellationRequested) Error?.Invoke($"수신 서버 오류: {ex.Message}"); }
    }

    private async Task HandleIncomingAsync(TcpClient client, CancellationToken token)
    {
        using (client)
        {
            var stream = client.GetStream();
            string? destination = null;
            try
            {
                var line = await ReadLineAsync(stream, 4096, token);
                var request = JsonSerializer.Deserialize<TransferRequest>(line, JsonOptions) ?? throw new InvalidDataException("전송 요청이 비어 있습니다.");
                if (request.Version != 1 || request.Size < 0 || request.Size > 100_000_000_000L || !IsSafeFileName(request.FileName)) throw new InvalidDataException("지원하지 않는 전송 요청입니다.");
                var decision = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                IncomingRequest?.Invoke(new TransferPrompt(request.Sender, request.FileName, request.Size, accepted => decision.TrySetResult(accepted)));
                bool accepted;
                try { accepted = await decision.Task.WaitAsync(TimeSpan.FromMinutes(2), token); }
                catch (TimeoutException) { accepted = false; }
                if (!accepted) { await WriteLineAsync(stream, "REJECT", token); return; }
                destination = CreateDestination(request.FileName);
                await WriteLineAsync(stream, "ACCEPT", token);
                ProgressChanged?.Invoke(new TransferProgress($"받는 중 · {request.FileName}", 0, request.Size));
                await using var output = new FileStream(destination, FileMode.Open, FileAccess.Write, FileShare.None, 128 * 1024, useAsync: true);
                await CopyExactAsync(stream, output, request.Size, $"받는 중 · {request.FileName}", token);
                TransferCompleted?.Invoke($"파일을 받았습니다 · {Path.GetFileName(destination)}");
            }
            catch (Exception ex)
            {
                if (destination is not null) try { File.Delete(destination); } catch { }
                try { await WriteLineAsync(stream, "REJECT", CancellationToken.None); } catch { }
                Error?.Invoke($"수신 실패: {ex.Message}");
            }
        }
    }

    public async Task SendAsync(string path, Peer peer)
    {
        if (Interlocked.Exchange(ref _sending, 1) != 0) return;
        try
        {
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, useAsync: true);
            using var client = new TcpClient(peer.Address.AddressFamily);
            await client.ConnectAsync(peer.Address, peer.Port, _lifetime.Token);
            var stream = client.GetStream();
            var request = new TransferRequest(1, _deviceName, Path.GetFileName(path), file.Length);
            var header = JsonSerializer.Serialize(request, JsonOptions) + "\n";
            await stream.WriteAsync(Encoding.UTF8.GetBytes(header), _lifetime.Token);
            var answer = await ReadLineAsync(stream, 64, _lifetime.Token);
            if (answer != "ACCEPT") throw new InvalidOperationException("상대 기기가 전송을 거절했습니다.");
            await CopyExactAsync(file, stream, file.Length, $"보내는 중 · {Path.GetFileName(path)}", _lifetime.Token);
            TransferCompleted?.Invoke("전송을 완료했습니다");
        }
        catch (Exception ex) { Error?.Invoke($"전송 실패: {ex.Message}"); }
        finally { Interlocked.Exchange(ref _sending, 0); }
    }

    private async Task CopyExactAsync(Stream input, Stream output, long size, string label, CancellationToken token)
    {
        var buffer = new byte[128 * 1024]; long done = 0; var started = DateTime.UtcNow; var lastReport = DateTime.MinValue;
        while (done < size)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, size - done)), token);
            if (read == 0) throw new EndOfStreamException("파일을 다 받기 전에 연결이 끝났습니다.");
            await output.WriteAsync(buffer.AsMemory(0, read), token); done += read;
            if ((DateTime.UtcNow - lastReport).TotalMilliseconds >= 150 || done == size)
            {
                ProgressChanged?.Invoke(new TransferProgress(label, done, size)); lastReport = DateTime.UtcNow;
            }
        }
        await output.FlushAsync(token);
    }

    private static async Task<string> ReadLineAsync(Stream stream, int limit, CancellationToken token)
    {
        using var buffer = new MemoryStream(); var one = new byte[1];
        while (buffer.Length <= limit)
        {
            var read = await stream.ReadAsync(one, token);
            if (read == 0) throw new EndOfStreamException("전송 요청을 읽지 못했습니다.");
            if (one[0] == 10) return Encoding.UTF8.GetString(buffer.ToArray()).TrimEnd('\r');
            buffer.WriteByte(one[0]);
        }
        throw new InvalidDataException("전송 요청 헤더가 너무 큽니다.");
    }
    private static async Task WriteLineAsync(Stream stream, string value, CancellationToken token)
    {
        var bytes = Encoding.UTF8.GetBytes(value + "\n");
        await stream.WriteAsync(bytes.AsMemory(), token);
    }
    private static bool IsSafeFileName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name is "." or ".." || name.Length > 240 || name != Path.GetFileName(name) ||
            name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Any(char.IsControl)) return false;
        var stem = Path.GetFileNameWithoutExtension(name);
        return !new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(stem, StringComparer.OrdinalIgnoreCase);
    }
    private static string CreateDestination(string name)
    {
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "LanShare");
        Directory.CreateDirectory(folder);
        var stem = Path.GetFileNameWithoutExtension(name); var extension = Path.GetExtension(name);
        for (var i = 1; i <= 10_000; i++)
        {
            var candidate = i == 1 ? name : $"{stem} ({i}){extension}";
            var fullPath = Path.Combine(folder, candidate);
            try { using var _ = new FileStream(fullPath, FileMode.CreateNew, FileAccess.Write, FileShare.None); return fullPath; }
            catch (IOException) { }
        }
        throw new IOException("다운로드 폴더에 고유한 파일을 만들 수 없습니다.");
    }

    public void Dispose()
    {
        _lifetime.Cancel(); _listener?.Stop(); _mdns?.Dispose(); _lifetime.Dispose();
    }
}
