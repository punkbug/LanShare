import CoreImage
import Darwin
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct TransferRequest: Codable {
    let version: Int
    let sender: String
    let fileName: String
    let size: Int64
}

private struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

private struct Incoming: Identifiable {
    let id = UUID()
    let sender: String
    let fileName: String
    let size: Int64
    let answer: (Bool) -> Void
}

@MainActor
private final class LanShareModel: ObservableObject {
    @Published var peers: [Peer] = []
    @Published var selectedPeerID: String?
    @Published var selectedFile: URL?
    @Published var incoming: Incoming?
    @Published var status = "주변 기기를 찾는 중입니다…"
    @Published var progress = 0.0
    @Published var transferDetails = ""
    @Published var transferLabel = ""
    @Published var isTransferring = false

    // Web Bridge
    @Published var showWebBridgeSheet = false
    @Published var webBridgeURL: String = ""
    @Published var webBridgeQRCode: UIImage? = nil

    private let service = LanService()
    private let webBridge = IOSWebBridgeService()
    private var startedAt = ProcessInfo.processInfo.systemUptime

    init() {
        service.onPeers = { [weak self] peers in
            Task { @MainActor in
                self?.peers = peers
                self?.status = peers.isEmpty ? "같은 Wi-Fi의 LanShare 기기를 기다리는 중" : "\(peers.count)대의 기기를 찾았습니다"
            }
        }
        service.onIncoming = { [weak self] request in Task { @MainActor in self?.incoming = request } }
        service.onProgress = { [weak self] label, done, total in
            Task { @MainActor in self?.updateProgress(label: label, done: done, total: total) }
        }
        service.onComplete = { [weak self] message in Task { @MainActor in self?.isTransferring = false; self?.status = message } }
        service.onError = { [weak self] message in Task { @MainActor in self?.isTransferring = false; self?.status = message; self?.transferDetails = "" }
        }
        service.start()

        // Start Web Bridge
        webBridge.currentSharedFileProvider = { [weak self] in
            self?.selectedFile
        }
        webBridge.onUploadedFileReceived = { [weak self] fileName, size in
            Task { @MainActor in
                self?.status = "웹 브라우저에서 '\(fileName)' 수신 완료 (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        webBridge.start()
        refreshWebBridgeInfo()
    }

    func refreshWebBridgeInfo() {
        let ip = IOSWebBridgeService.getLocalIPAddress() ?? "127.0.0.1"
        let url = "http://\(ip):52521"
        self.webBridgeURL = url
        self.webBridgeQRCode = IOSWebBridgeService.generateQRCode(from: url)
    }

    func refresh() {
        peers = []
        selectedPeerID = nil
        status = "주변 기기를 다시 찾는 중입니다…"
        service.refresh()
        refreshWebBridgeInfo()
    }

    func sendSelectedFile() {
        guard let file = selectedFile, let peer = peers.first(where: { $0.id == selectedPeerID }) else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        isTransferring = true
        progress = 0
        transferLabel = "연결 중 · \(file.lastPathComponent)"
        transferDetails = "속도 계산 중…"
        service.send(file: file, to: peer)
    }

    func answerIncoming(_ accepted: Bool) {
        guard let request = incoming else { return }
        incoming = nil
        request.answer(accepted)
        if accepted {
            startedAt = ProcessInfo.processInfo.systemUptime
            isTransferring = true
            progress = 0
            transferLabel = "받는 중 · \(request.fileName)"
            transferDetails = "속도 계산 중…"
            status = "전송을 받는 중입니다…"
        } else { status = "전송 요청을 거절했습니다" }
    }

    private func updateProgress(label: String, done: Int64, total: Int64) {
        transferLabel = label
        progress = total > 0 ? min(1, Double(done) / Double(total)) : 1
        if done > 0, total > 0 {
            let elapsed = max(0.1, ProcessInfo.processInfo.systemUptime - startedAt)
            let rate = Double(done) / elapsed
            let speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file)
            let seconds = Int(ceil(Double(max(0, total - done)) / rate))
            transferDetails = "\(speed)/s · 남은 시간 \(Self.duration(seconds))"
        }
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(1, seconds))초" }
        if seconds < 3600 { return "\(seconds / 60)분 \(seconds % 60)초" }
        return "\(seconds / 3600)시간 \((seconds % 3600) / 60)분"
    }
}

@main
struct LanShareIOSApp: App {
    @StateObject private var model = LanShareModel()
    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}

private struct ContentView: View {
    @EnvironmentObject private var model: LanShareModel
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                // Web Bridge Banner
                Section {
                    Button {
                        model.refreshWebBridgeInfo()
                        model.showWebBridgeSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 26))
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("웹 브라우저와 직접 연결 (QR)")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("상대방 앱 없이 사파리/크롬으로 초고속 송수신")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    HStack {
                        Label("LanShare", systemImage: "arrow.up.arrow.down.circle.fill").font(.title2.bold())
                        Spacer()
                        Button("새로고침", systemImage: "arrow.clockwise") { model.refresh() }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("주변 기기 새로고침")
                    }
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }

                Section("주변 기기 (Bonjour)") {
                    if model.peers.isEmpty {
                        Text("상대 기기에서 LanShare를 열고 같은 Wi-Fi에 연결하세요.\n또는 상단의 [웹 브라우저 연결]을 사용하세요.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.peers) { peer in
                            Button {
                                model.selectedPeerID = peer.id
                            } label: {
                                Label(peer.name, systemImage: "desktopcomputer")
                                    .foregroundStyle(model.selectedPeerID == peer.id ? Color.accentColor : Color.primary)
                            }
                        }
                    }
                }

                Section("파일 보내기") {
                    Button { importing = true } label: {
                        Label(model.selectedFile?.lastPathComponent ?? "파일 선택", systemImage: "doc.badge.plus")
                    }
                    Button { model.sendSelectedFile() } label: {
                        Label("선택한 기기로 보내기", systemImage: "paperplane.fill")
                    }
                    .disabled(model.selectedFile == nil || model.selectedPeerID == nil || model.isTransferring)

                    if model.isTransferring {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.transferLabel)
                            ProgressView(value: model.progress)
                            Text("\(Int(model.progress * 100))% · \(model.transferDetails)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Label("개발용 전송 · 암호화 미지원", systemImage: "exclamationmark.shield.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("파일을 주고받는 동안에는 화면을 켜두세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("LanShare")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case let .success(urls) = result { model.selectedFile = urls.first }
            }
            .sheet(item: $model.incoming) { request in
                IncomingSheet(request: request, answer: model.answerIncoming)
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $model.showWebBridgeSheet) {
                IOSWebBridgeSheetView(
                    url: model.webBridgeURL,
                    qrImage: model.webBridgeQRCode,
                    sharedFile: model.selectedFile,
                    onDismiss: { model.showWebBridgeSheet = false }
                )
            }
        }
    }
}

private struct IOSWebBridgeSheetView: View {
    let url: String
    let qrImage: UIImage?
    let sharedFile: URL?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("상대방 기기에 앱이 없어도 괜찮습니다!\n상대방 폰/PC의 카메라로 아래 QR을 비추면 브라우저에서 즉시 송수신됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(radius: 4)
                }

                VStack(spacing: 6) {
                    Text("브라우저 직접 접속 주소:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(url).font(.system(.body, design: .monospaced).bold())
                        Button("복사") {
                            UIPasteboard.general.string = url
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let sharedFile {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("선택된 파일: \(sharedFile.lastPathComponent)")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: Capsule())
                }

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("웹 브라우저 연결 (QR)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onDismiss)
                }
            }
        }
    }
}

private struct IncomingSheet: View {
    let request: Incoming
    let answer: (Bool) -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 36)).foregroundStyle(.blue)
            Text("파일 전송 요청").font(.title2.bold())
            Text("\(request.sender)이(가) \(request.fileName) (\(ByteCountFormatter.string(fromByteCount: request.size, countStyle: .file))) 파일을 보내려 합니다.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("거절", role: .cancel) { answer(false) }.buttonStyle(.bordered)
                Button("받기") { answer(true) }.buttonStyle(.borderedProminent)
            }
        }.padding(28)
    }
}

private final class LanService {
    private let queue = DispatchQueue(label: "app.lanshare.ios.network", qos: .userInitiated)
    private let deviceName = UIDevice.current.name
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pending: [UUID: NWConnection] = [:]
    private var active: NWConnection?
    var onPeers: (([Peer]) -> Void)?
    var onIncoming: ((Incoming) -> Void)?
    var onProgress: ((String, Int64, Int64) -> Void)?
    var onComplete: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: deviceName, type: "_lanshare._tcp")
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state { self?.onError?("수신 서버 오류: \(error.localizedDescription)") }
            }
            self.listener = listener
            listener.start(queue: queue)
            browse()
        } catch { onError?("로컬 네트워크를 시작하지 못했습니다: \(error.localizedDescription)") }
    }

    func refresh() { queue.async { [weak self] in self?.browser?.cancel(); self?.browse() } }
    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: "_lanshare._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error): self?.onError?("기기 검색 대기 중: \(error.localizedDescription)")
            case .failed(let error): self?.onError?("기기 검색 오류: \(error.localizedDescription)")
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let peers = results.compactMap { result -> Peer? in
                guard case let .service(name, _, _, _) = result.endpoint, name != self.deviceName else { return nil }
                return Peer(id: name, name: name, endpoint: result.endpoint)
            }
            self.onPeers?(peers)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, buffer: Data())
    }
    private func readHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var bytes = buffer
            if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 4096 else { connection.cancel(); return }
            guard let end = bytes.firstIndex(of: 10) else {
                if complete { connection.cancel(); self.onError?("전송 요청 헤더가 끝나기 전에 연결이 종료됐습니다"); return }
                self.readHeader(connection, buffer: bytes)
                return
            }
            do {
                let req = try JSONDecoder().decode(TransferRequest.self, from: bytes[..<end])
                guard req.version == 1, req.size >= 0, req.size <= 100_000_000_000,
                      Self.safe(req.fileName) != nil else { connection.cancel(); return }
                let id = UUID()
                self.pending[id] = connection
                self.onIncoming?(Incoming(sender: req.sender, fileName: req.fileName, size: req.size) { [weak self] ok in
                    guard let self, let conn = self.pending.removeValue(forKey: id) else { return }
                    if !ok { conn.send(content: Data("REJECT\n".utf8), completion: .contentProcessed { _ in conn.cancel() }); return }
                    self.receivePayload(conn, name: req.fileName, size: req.size)
                })
            } catch { connection.cancel() }
        }
    }

    private func receivePayload(_ conn: NWConnection, name: String, size: Int64) {
        guard let url = Self.saveURL(name: name), let handle = try? FileHandle(forWritingTo: url) else {
            conn.cancel(); onError?("저장 위치를 열 수 없습니다"); return
        }
        conn.send(content: Data("ACCEPT\n".utf8), completion: .contentProcessed { [weak self] err in
            if let err { handle.closeFile(); conn.cancel(); self?.onError?(err.localizedDescription); return }
            self?.streamIn(conn, handle: handle, expected: size, done: 0, url: url, name: name)
        })
    }

    private func streamIn(_ conn: NWConnection, handle: FileHandle, expected: Int64, done: Int64, url: URL, name: String) {
        if done == expected {
            handle.closeFile(); conn.cancel(); onProgress?("완료 · \(name)", expected, expected); onComplete?("다운로드 완료: \(name)"); return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { handle.closeFile(); try? FileManager.default.removeItem(at: url); conn.cancel(); self.onError?(error.localizedDescription); return }
            guard let data, !data.isEmpty else {
                if complete { handle.closeFile(); try? FileManager.default.removeItem(at: url); self.onError?("전송 도중 연결이 끊겼습니다") }
                else { self.streamIn(conn, handle: handle, expected: expected, done: done, url: url, name: name) }
                return
            }
            let slice = data.prefix(Int(min(Int64(data.count), expected - done)))
            handle.write(Data(slice))
            let next = done + Int64(slice.count)
            self.onProgress?("받는 중 · \(name)", next, expected)
            self.streamIn(conn, handle: handle, expected: expected, done: next, url: url, name: name)
        }
    }

    func send(file: URL, to peer: Peer) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) else { onError?("파일 크기를 확인할 수 없습니다"); return }
        let total = Int64(size)
        let conn = NWConnection(to: peer.endpoint, using: .tcp)
        active = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onError?("연결 실패: \(error.localizedDescription)") }
        }
        conn.start(queue: queue)
        let req = TransferRequest(version: 1, sender: deviceName, fileName: file.lastPathComponent, size: total)
        guard var json = try? JSONEncoder().encode(req) else { onError?("요청 인코딩 실패"); return }
        json.append(10)
        conn.send(content: json, completion: .contentProcessed { [weak self] err in
            if let err { conn.cancel(); self?.onError?(err.localizedDescription); return }
            self?.awaitAnswer(conn, file: file, total: total)
        })
    }

    private func awaitAnswer(_ conn: NWConnection, file: URL, total: Int64) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self] data, _, _, err in
            guard let self, err == nil, let data, let s = String(data: data, encoding: .utf8), s.hasPrefix("ACCEPT") else {
                conn.cancel(); self?.onError?("상대방이 거절했거나 응답이 없습니다"); return
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { conn.cancel(); self.onError?("파일을 열 수 없습니다"); return }
            self.streamOut(conn, handle: handle, total: total, sent: 0, name: file.lastPathComponent)
        }
    }

    private func streamOut(_ conn: NWConnection, handle: FileHandle, total: Int64, sent: Int64, name: String) {
        if sent == total {
            handle.closeFile()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                conn.cancel()
                self?.onProgress?("전송 완료", total, total)
                self?.onComplete?("전송을 완료했습니다")
            })
            return
        }
        let chunk = handle.readData(ofLength: 64 * 1024)
        guard !chunk.isEmpty else { handle.closeFile(); conn.cancel(); onError?("파일 읽기 오류"); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if let err { handle.closeFile(); conn.cancel(); self?.onError?(err.localizedDescription); return }
            let next = sent + Int64(chunk.count)
            self?.onProgress?("보내는 중 · \(name)", next, total)
            self?.streamOut(conn, handle: handle, total: total, sent: next, name: name)
        })
    }

    static func safe(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }

    static func saveURL(name: String) -> URL? {
        guard let base = safe(name) else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("LanShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        for index in 1...10_000 {
            let name = index == 1 ? base : "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            let file = dir.appendingPathComponent(name)
            let fd = file.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
            if fd >= 0 { close(fd); return file }
            if errno != EEXIST { return nil }
        }
        return nil
    }
}

// MARK: - iOS Web Bridge Service (HTTP Server for Browser Direct Transfer)
private final class IOSWebBridgeService {
    private let queue = DispatchQueue(label: "app.lanshare.ios.webbridge", qos: .userInitiated)
    private var listener: NWListener?
    let port: UInt16 = 52521

    var currentSharedFileProvider: (() -> URL?)?
    var onUploadedFileReceived: ((String, Int64) -> Void)?

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleHTTP(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            print("iOS WebBridge start failed: \(error)")
        }
    }

    private func handleHTTP(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, err in
                guard let self else { conn.cancel(); return }
                if let data { buffer.append(data) }
                if err != nil { conn.cancel(); return }

                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    let body = buffer[range.upperBound...]
                    self.dispatch(header: header, body: Data(body), conn: conn)
                } else if buffer.count < 32768 {
                    read()
                } else {
                    conn.cancel()
                }
            }
        }
        read()
    }

    private func dispatch(header: String, body: Data, conn: NWConnection) {
        let first = header.components(separatedBy: "\r\n").first ?? ""
        let parts = first.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0]
        let path = parts[1]

        if method == "GET" && path == "/" {
            serveHTML(conn: conn)
        } else if method == "GET" && path.hasPrefix("/download") {
            serveDownload(conn: conn)
        } else if method == "POST" && path.hasPrefix("/upload") {
            serveUpload(header: header, path: path, body: body, conn: conn)
        } else {
            let res = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(res.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func serveHTML(conn: NWConnection) {
        let name = UIDevice.current.name
        let file = currentSharedFileProvider?()
        let fileName = file?.lastPathComponent ?? ""
        let sizeStr: String
        if let file, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            sizeStr = ""
        }

        let downloadCard: String
        if !fileName.isEmpty {
            downloadCard = """
            <div class="card">
              <h3>📥 iPhone/iPad에서 다운로드</h3>
              <p>파일명: <strong>\(fileName)</strong> (\(sizeStr))</p>
              <a href="/download" class="btn btn-primary" download>스마트폰/PC에 저장하기</a>
            </div>
            """
        } else {
            downloadCard = """
            <div class="card" style="opacity: 0.7;">
              <h3>📥 iPhone/iPad에서 다운로드</h3>
              <p>현재 기기에서 선택된 파일이 없습니다.</p>
            </div>
            """
        }

        let html = """
        <!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>LanShare iOS Bridge</title>
        <style>
          :root { --accent: #38bdf8; --bg: #0f172a; --card: #1e293b; --text: #f8fafc; }
          body { font-family: -apple-system, system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 24px; display: flex; flex-direction: column; align-items: center; }
          .container { max-width: 500px; width: 100%; }
          .header { text-align: center; margin-bottom: 24px; }
          .card { background: var(--card); border-radius: 16px; padding: 22px; margin-bottom: 20px; box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
          .card h3 { margin-top: 0; font-size: 1.15rem; color: var(--accent); }
          .btn { display: inline-block; width: 100%; box-sizing: border-box; text-align: center; padding: 14px; border-radius: 10px; font-weight: 700; text-decoration: none; cursor: pointer; border: none; font-size: 1rem; }
          .btn-primary { background: linear-gradient(135deg, #38bdf8, #6366f1); color: #fff; }
          .file-input { width: 100%; box-sizing: border-box; padding: 12px; background: rgba(0,0,0,0.2); border-radius: 8px; border: 1px dashed #64748b; color: #fff; margin-bottom: 14px; }
        </style></head><body><div class="container">
          <div class="header">
            <h2>📱 LanShare iOS Bridge</h2>
            <p style="color: #94a3b8; font-size: 0.9rem;">연결된 기기: <strong>\(name)</strong></p>
          </div>
          \(downloadCard)
          <div class="card">
            <h3>📤 iPhone/iPad로 파일 전송</h3>
            <form id="upload"><input id="file" type="file" class="file-input" required>
              <button type="submit" class="btn btn-primary">iPhone으로 직접 전송하기</button></form><p id="status"></p>
            <script>upload.onsubmit=async e=>{e.preventDefault();const f=file.files[0];status.textContent='전송 중…';const r=await fetch('/upload?name='+encodeURIComponent(f.name),{method:'POST',body:f});status.textContent=r.ok?'전송 완료':'전송 실패'};</script>
          </div>
        </div></body></html>
        """
        let res = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        conn.send(content: Data(res.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveDownload(conn: NWConnection) {
        guard let file = currentSharedFileProvider?(),
              let handle = try? FileHandle(forReadingFrom: file),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) else {
            let res = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(res.utf8), completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        let encoded = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(encoded)\"\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.streamFile(conn: conn, handle: handle, total: Int64(size), sent: 0)
        })
    }

    private func streamFile(conn: NWConnection, handle: FileHandle, total: Int64, sent: Int64) {
        if sent >= total { handle.closeFile(); conn.cancel(); return }
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { handle.closeFile(); conn.cancel(); return }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { handle.closeFile(); conn.cancel(); return }
            self?.streamFile(conn: conn, handle: handle, total: total, sent: sent + Int64(chunk.count))
        })
    }

    private func serveUpload(header: String, path: String, body: Data, conn: NWConnection) {
        let length = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
            .flatMap { Int64($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? -1
        guard length >= 0, length <= 100_000_000_000 else { respond(conn, message: "파일 크기가 잘못되었습니다", status: "413 Payload Too Large"); return }
        let rawName = URLComponents(string: "http://localhost\(path)")?.queryItems?.first(where: { $0.name == "name" })?.value ?? "upload.bin"
        let target = LanService.safe(rawName) ?? "upload.bin"
        guard let dest = LanService.saveURL(name: target), let handle = try? FileHandle(forWritingTo: dest) else {
            respond(conn, message: "저장 위치를 열 수 없습니다", status: "500 Internal Server Error"); return
        }
        func fail(_ message: String) {
            handle.closeFile()
            try? FileManager.default.removeItem(at: dest)
            self.respond(conn, message: message, status: "500 Internal Server Error")
        }
        func finish() {
            handle.closeFile()
            self.onUploadedFileReceived?(target, length)
            self.respond(conn, message: "전송 완료", status: "200 OK")
        }
        func readMore(_ received: Int64) {
            if received >= length { finish(); return }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { fail(error.localizedDescription); return }
                guard let data, !data.isEmpty else {
                    if complete { fail("업로드 연결이 끊겼습니다") } else { readMore(received) }
                    return
                }
                let chunk = data.prefix(Int(min(Int64(data.count), length - received)))
                handle.write(Data(chunk))
                readMore(received + Int64(chunk.count))
            }
        }
        let initial = body.prefix(Int(min(Int64(body.count), length)))
        handle.write(Data(initial))
        readMore(Int64(initial.count))
    }

    private func respond(_ conn: NWConnection, message: String, status: String) {
        let html = "<!doctype html><meta charset=\"utf-8\"><p>\(message)</p><a href=\"/\">돌아가기</a>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" || name == "en1" || name == "pdp_ip0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: host)
                    break
                }
            }
        }
        return address
    }

    static func generateQRCode(from string: String) -> UIImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
