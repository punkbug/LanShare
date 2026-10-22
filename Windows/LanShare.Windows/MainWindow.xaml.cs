using Microsoft.Win32;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace LanShare.Windows;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<Peer> _peers = [];
    private readonly LanShareService _service = new();
    private string? _selectedFile;
    private DateTime _startedAt;

    public MainWindow()
    {
        InitializeComponent();
        LocalCodeText.Text = _service.LocalCode;
        PeersList.ItemsSource = _peers;
        _service.PeersChanged += peers => Dispatcher.Invoke(() =>
        {
            var selectedId = (PeersList.SelectedItem as Peer)?.Id;
            _peers.Clear();
            foreach (var peer in peers) _peers.Add(peer);
            if (selectedId is not null) PeersList.SelectedItem = _peers.FirstOrDefault(peer => peer.Id == selectedId);
            StatusText.Text = peers.Count == 0 ? "같은 네트워크의 기기 코드를 찾는 중" : $"{peers.Count}대의 같은 네트워크 기기를 찾았습니다";
            if (CodeInput.Text.Trim().Length == 4 && _peers.Any(peer => peer.Code == CodeInput.Text.Trim()))
                ConnectByCode_Click(this, new RoutedEventArgs());
            else UpdateSendEnabled();
        });
        _service.StatusChanged += message => Dispatcher.Invoke(() => StatusText.Text = message);
        _service.IncomingRequest += request => Dispatcher.Invoke(() =>
        {
            var bytes = FormatBytes(request.Size);
            var result = MessageBox.Show(this,
                $"{request.Sender} 기기에서 다음 파일을 보내려 합니다.\n\n{request.FileName}\n{bytes}\n\n받으시겠습니까?",
                "파일 전송 요청", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (result == MessageBoxResult.Yes)
            {
                _startedAt = DateTime.UtcNow;
                TransferPanel.Visibility = Visibility.Visible;
                TransferProgress.Value = 0;
            }
            request.Respond(result == MessageBoxResult.Yes);
        });
        _service.ProgressChanged += progress => Dispatcher.Invoke(() =>
        {
            TransferPanel.Visibility = Visibility.Visible;
            TransferLabel.Text = progress.Label;
            TransferProgress.Value = progress.Total == 0 ? 100 : Math.Clamp(progress.Bytes * 100.0 / progress.Total, 0, 100);
            var elapsed = Math.Max(0.1, (DateTime.UtcNow - _startedAt).TotalSeconds);
            var rate = progress.Bytes / elapsed;
            var remaining = rate > 0 ? Math.Max(0, (int)Math.Ceiling((progress.Total - progress.Bytes) / rate)) : 0;
            TransferDetails.Text = $"{TransferProgress.Value:0}% · {FormatBytes((long)rate)}/s · 남은 시간 {FormatDuration(remaining)}";
        });
        _service.TransferCompleted += message => Dispatcher.Invoke(() =>
        {
            StatusText.Text = message;
            if (message.StartsWith("전송을 완료", StringComparison.Ordinal) || message.StartsWith("파일을 받았습니다", StringComparison.Ordinal))
                TransferProgress.Value = 100;
            SendButton.IsEnabled = _selectedFile is not null && PeersList.SelectedItem is Peer;
        });
        _service.Error += message => Dispatcher.Invoke(() =>
        {
            StatusText.Text = message;
            SendButton.IsEnabled = _selectedFile is not null && PeersList.SelectedItem is Peer;
        });
        Loaded += async (_, _) => await _service.StartAsync();
        Closed += (_, _) => _service.Dispose();
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => _service.Refresh();
    private void ConnectByCode_Click(object sender, RoutedEventArgs e)
    {
        var code = CodeInput.Text.Trim();
        if (code.Length != 4 || !code.All(char.IsAsciiDigit))
        {
            StatusText.Text = "상대방의 4자리 코드를 입력하세요.";
            PeersList.SelectedItem = null;
            return;
        }
        var matches = _peers.Where(peer => peer.Code == code).ToArray();
        if (matches.Length != 1)
        {
            StatusText.Text = matches.Length == 0
                ? $"코드 {code} 기기를 찾지 못했습니다. 같은 네트워크인지 확인하세요."
                : "같은 코드 기기가 여러 대입니다. 상대 앱을 다시 열어 새 코드를 발급하세요.";
            PeersList.SelectedItem = null;
            return;
        }
        PeersList.SelectedItem = matches[0];
        StatusText.Text = $"코드 {code} 기기에 연결했습니다. 파일을 선택해 보내세요.";
    }
    private void PeersList_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateSendEnabled();

    private void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "전송할 파일 선택", CheckFileExists = true, Multiselect = false };
        if (dialog.ShowDialog(this) == true) SetFile(dialog.FileName);
    }

    private void FileDrop_DragOver(object sender, DragEventArgs e) => e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
    private void FileDrop_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0 && File.Exists(files[0])) SetFile(files[0]);
    }

    private void SetFile(string file)
    {
        _selectedFile = file;
        SelectedFileText.Text = Path.GetFileName(file);
        SelectedFileSize.Text = FormatBytes(new FileInfo(file).Length);
        UpdateSendEnabled();
    }

    private async void Send_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedFile is null || PeersList.SelectedItem is not Peer peer) return;
        SendButton.IsEnabled = false;
        _startedAt = DateTime.UtcNow;
        TransferProgress.Value = 0;
        TransferPanel.Visibility = Visibility.Visible;
        try { await _service.SendAsync(_selectedFile, peer); }
        finally { UpdateSendEnabled(); }
    }

    private void UpdateSendEnabled() => SendButton.IsEnabled = _selectedFile is not null && PeersList.SelectedItem is Peer && !_service.IsSending;
    private static string FormatBytes(long bytes) => $"{bytes / 1024d / 1024d:0.0} MB";
    private static string FormatDuration(int seconds) => seconds < 60 ? $"{Math.Max(1, seconds)}초" : seconds < 3600 ? $"{seconds / 60}분 {seconds % 60}초" : $"{seconds / 3600}시간 {(seconds % 3600) / 60}분";
}
