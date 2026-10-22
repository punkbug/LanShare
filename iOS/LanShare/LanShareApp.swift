import Darwin
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

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

    @Published var showWebTransferSheet = false

    private let service = LanService()
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
    }

    func refresh() {
        peers = []
        selectedPeerID = nil
        status = "주변 기기를 다시 찾는 중입니다…"
        service.refresh()
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
                Section {
                    Button {
                        model.showWebTransferSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 26))
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("4자리 코드 / QR로 전송")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("웹과 같은 보안 코드로 연결")
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
                        Text("상대 기기에서 LanShare를 열고 같은 Wi-Fi에 연결하세요.\n또는 상단의 [4자리 코드 / QR]을 이용하세요.")
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
            .sheet(isPresented: $model.showWebTransferSheet) {
                NavigationStack {
                    WebTransferView { name in model.status = "웹에서 파일을 받았습니다 · \(name)" }
                        .navigationTitle("4자리 코드 / QR로 전송")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { model.showWebTransferSheet = false } } }
                }
            }
        }
    }
}

private struct WebTransferView: UIViewRepresentable {
    let onSaved: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSaved: onSaved) }
    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "lanShareNative")
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "https://lanshare-five.vercel.app/#web-direct-transfer")!))
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static let bridgeScript = """
    window.lanShareNative={beginFile:(name,mime,size)=>webkit.messageHandlers.lanShareNative.postMessage({type:'begin',name,mime,size}),writeChunk:data=>webkit.messageHandlers.lanShareNative.postMessage({type:'chunk',data}),completeFile:()=>webkit.messageHandlers.lanShareNative.postMessage({type:'complete'})};
    """

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let queue = DispatchQueue(label: "app.lanshare.ios.web-download")
        private let onSaved: (String) -> Void
        private var output: FileHandle?
        private var destination: URL?
        private var fileName: String?
        init(onSaved: @escaping (String) -> Void) { self.onSaved = onSaved }
        deinit {
            output?.closeFile()
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let data = message.body as? [String: Any], let type = data["type"] as? String else { return }
            queue.async { [weak self] in self?.handle(data: data, type: type) }
        }
        private func handle(data: [String: Any], type: String) {
            switch type {
            case "begin":
                guard let name = data["name"] as? String, let safe = LanService.safe(name),
                      let url = LanService.saveURL(name: safe), let handle = try? FileHandle(forWritingTo: url) else { return }
                output?.closeFile()
                output = handle
                destination = url
                fileName = url.lastPathComponent
            case "chunk":
                guard let encoded = data["data"] as? String, let bytes = Data(base64Encoded: encoded) else { return }
                output?.write(bytes)
            case "complete":
                output?.closeFile()
                output = nil
                destination = nil
                let name = fileName ?? "파일"
                fileName = nil
                DispatchQueue.main.async { self.onSaved(name) }
            default: break
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
