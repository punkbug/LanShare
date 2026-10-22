using System.IO;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using System.Windows;

namespace LanShare.Windows;

public partial class WebTransferWindow : Window
{
    private const string TransferUrl = "https://lanshare-five.vercel.app/#web-direct-transfer";
    private FileStream? _output;
    private string? _destination;

    public WebTransferWindow()
    {
        InitializeComponent();
        Loaded += InitializeBrowser;
        Closed += (_, _) =>
        {
            _output?.Dispose();
            if (_destination is not null) { try { File.Delete(_destination); } catch { } }
        };
    }

    private async void InitializeBrowser(object sender, RoutedEventArgs e)
    {
        try
        {
            await Browser.EnsureCoreWebView2Async();
            await Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync("window.lanShareNative={beginFile:(name,mime,size)=>chrome.webview.postMessage({type:'begin',name,mime,size}),writeChunk:data=>chrome.webview.postMessage({type:'chunk',data}),completeFile:()=>chrome.webview.postMessage({type:'complete'})};");
            Browser.CoreWebView2.WebMessageReceived += ReceiveNativeMessage;
            Browser.CoreWebView2.Navigate(TransferUrl);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"웹 전송 화면을 열지 못했습니다.\n{ex.Message}", "LanShare", MessageBoxButton.OK, MessageBoxImage.Error);
            Close();
        }
    }

    private void ReceiveNativeMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var message = JsonDocument.Parse(e.WebMessageAsJson);
            var root = message.RootElement;
            var type = root.GetProperty("type").GetString();
            if (type == "begin")
            {
                _output?.Dispose();
                var name = Path.GetFileName(root.GetProperty("name").GetString() ?? "received-file");
                if (string.IsNullOrWhiteSpace(name) || name is "." or "..") name = "received-file";
                var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "LanShare");
                Directory.CreateDirectory(folder);
                _destination = CreateUniquePath(folder, name);
                _output = new FileStream(_destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, true);
            }
            else if (type == "chunk")
            {
                var bytes = Convert.FromBase64String(root.GetProperty("data").GetString() ?? "");
                _output?.Write(bytes);
            }
            else if (type == "complete")
            {
                _output?.Dispose();
                _output = null;
                var name = Path.GetFileName(_destination ?? "received-file");
                _destination = null;
                Dispatcher.Invoke(() => Title = $"LanShare · 저장 완료: {name}");
            }
        }
        catch (Exception ex)
        {
            _output?.Dispose();
            _output = null;
            if (_destination is not null) { try { File.Delete(_destination); } catch { } }
            _destination = null;
            Dispatcher.Invoke(() => MessageBox.Show(this, $"파일을 저장하지 못했습니다.\n{ex.Message}", "LanShare", MessageBoxButton.OK, MessageBoxImage.Error));
        }
    }

    private static string CreateUniquePath(string folder, string name)
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

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
