import AppKit
import CoreImage
import Darwin
import Network
import SwiftUI
import UniformTypeIdentifiers

@main
struct LanShareApp: App {
    @StateObject private var model = LanShareModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}

struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

struct IncomingRequest: Identifiable {
    let id = UUID()
    let sender: String
    let fileName: String
    let size: Int64
    let respond: (Bool) -> Void
}

@MainActor
final class LanShareModel: ObservableObject {
    @Published var peers: [Peer] = []
    @Published var selectedPeerID: String?
    @Published var incoming: IncomingRequest?
    @Published var selectedFile: URL?
    @Published var status = "주변 기기를 찾는 중입니다…"
    @Published var progress: Double = 0
    @Published var transferLabel = ""
    @Published var transferDetails = ""
    @Published var isTransferring = false

    // Web Bridge (Web Browser Direct Transfer)
    @Published var showWebBridgeSheet = false
    @Published var webBridgeURL: String = ""
    @Published var webBridgeQRCode: NSImage? = nil

    private let service = LanService()
    private let webBridge = WebBridgeService()
    private var transferStartedAt = ProcessInfo.processInfo.systemUptime

    init() {
        service.onPeers = { [weak self] peers in
            Task { @MainActor in
                self?.peers = peers
                self?.status = peers.isEmpty ? "같은 네트워크의 LanShare 기기를 기다리는 중" : "\(peers.count)대의 기기를 찾았습니다"
            }
        }
        service.onIncoming = { [weak self] sender, name, size, respond in
            Task { @MainActor in
                self?.incoming = IncomingRequest(sender: sender, fileName: name, size: size, respond: respond)
            }
        }
        service.onReceiveProgress = { [weak self] name, done, total in
            Task { @MainActor in
                self?.updateTransferProgress(name: name, done: done, total: total, direction: "받는 중")
            }
        }
        service.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.status = message
                self?.isTransferring = false
                self?.transferDetails = ""
            }
        }
        service.start()

        // Start Web Bridge HTTP Streaming Server
        webBridge.currentSharedFileProvider = { [weak self] in
            self?.selectedFile
        }
        webBridge.onUploadedFileReceived = { [weak self] fileName, size in
            Task { @MainActor in
                self?.status = "웹 브라우저에서 '\(fileName)' 수신 완료 (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
                NSSound.beep()
            }
        }
        webBridge.start()
        refreshWebBridgeInfo()
    }

    func refreshWebBridgeInfo() {
        let ip = WebBridgeService.getLocalIPAddress() ?? "127.0.0.1"
        let urlString = "http://\(ip):52521"
        self.webBridgeURL = urlString
        self.webBridgeQRCode = WebBridgeService.generateQRCode(from: urlString)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK { selectedFile = panel.url }
    }

    func send() {
        guard let file = selectedFile,
              let peer = peers.first(where: { $0.id == selectedPeerID }) else { return }
        let total = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        transferStartedAt = ProcessInfo.processInfo.systemUptime
        isTransferring = true
        progress = 0
        transferDetails = "속도 계산 중…"
        transferLabel = "연결 중 · \(file.lastPathComponent)"
        service.send(file: file, to: peer) { [weak self] value in
            Task { @MainActor in
                self?.progress = value
                self?.updateTransferMetrics(done: Int64(Double(total) * value), total: total)
                if value >= 1 {
                    self?.isTransferring = false
                    self?.status = "전송을 완료했습니다"
                }
            }
        }
    }

    func respondToIncoming(_ accepted: Bool) {
        let request = incoming
        request?.respond(accepted)
        incoming = nil
        status = accepted ? "전송을 받는 중입니다…" : "전송 요청을 거절했습니다"
        isTransferring = accepted
        if accepted {
            transferStartedAt = ProcessInfo.processInfo.systemUptime
            progress = 0
            transferLabel = "받는 중 · \(request?.fileName ?? "파일")"
            transferDetails = "속도 계산 중…"
        } else {
            transferDetails = ""
        }
    }

    private func updateTransferProgress(name: String, done: Int64, total: Int64, direction: String) {
        transferLabel = "\(direction) · \(name)"
        progress = total > 0 ? min(1, Double(done) / Double(total)) : 1
        updateTransferMetrics(done: done, total: total)
        isTransferring = done < total
        if !isTransferring { status = "파일을 다운로드 폴더에 저장했습니다" }
    }

    private func updateTransferMetrics(done: Int64, total: Int64) {
        guard done > 0, total > 0 else {
            transferDetails = "속도 계산 중…"
            return
        }
        let elapsed = max(0.1, ProcessInfo.processInfo.systemUptime - transferStartedAt)
        let bytesPerSecond = Double(done) / elapsed
        let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        let remaining = max(0, Int(ceil(Double(max(0, total - done)) / bytesPerSecond)))
        transferDetails = "\(speed)/s · 남은 시간 \(Self.formatDuration(remaining))"
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(1, seconds))초" }
        if seconds < 3600 { return "\(seconds / 60)분 \(seconds % 60)초" }
        if seconds < 86400 { return "\(seconds / 3600)시간 \((seconds % 3600) / 60)분" }
        return "\(seconds / 86400)일 \((seconds % 86400) / 3600)시간"
    }

    func refreshPeers() {
        peers = []
        selectedPeerID = nil
        status = "주변 기기를 다시 찾는 중입니다…"
        service.refreshPeers()
        refreshWebBridgeInfo()
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LanShareModel

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar: Peers List & Web Share Button
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LanShare").font(.title2.bold())
                        Text("로컬 고속 다이렉트 전송").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Web Browser Direct Transfer Action Banner
                Button(action: {
                    model.refreshWebBridgeInfo()
                    model.showWebBridgeSheet = true
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("스마트폰 웹 브라우저 연결")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                            Text("앱 설치 없이 QR로 즉시 송수신")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                .buttonStyle(.plain)
                .help("스마트폰 카메라로 QR을 스캔하여 앱 없이 브라우저로 전송합니다")

                Divider()

                HStack {
                    Text("주변 기기 (LanShare)").font(.headline)
                    Spacer()
                    Button(action: model.refreshPeers) {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("주변 LanShare 기기 다시 검색")
                }

                if model.peers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("주변 기기 찾는 중").font(.subheadline.bold())
                        Text("상대 기기에서 LanShare를 켜거나,\n상단 [스마트폰 웹 연결]을 이용하세요.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.peers, selection: $model.selectedPeerID) { peer in
                        Label(peer.name, systemImage: "desktopcomputer")
                            .tag(peer.id)
                    }
                    .listStyle(.inset)
                }

                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(22)
            .frame(width: 310)

            Divider()

            // Right Main Panel: File Selection & Send
            VStack(alignment: .leading, spacing: 22) {
                Text("파일 보내기").font(.largeTitle.bold())
                Text("파일은 외부 인터넷 서버를 거치지 않고 로컬 네트워크에서 직접 고속 스트리밍됩니다.")
                    .foregroundStyle(.secondary)

                Button(action: model.chooseFile) {
                    VStack(spacing: 12) {
                        Image(systemName: model.selectedFile == nil ? "doc.badge.plus" : "doc.fill")
                            .font(.system(size: 40)).foregroundStyle(.blue)
                        Text(model.selectedFile?.lastPathComponent ?? "파일 선택 (또는 드래그 앤 드롭)")
                            .font(.headline).lineLimit(1)
                        if let file = model.selectedFile, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("이곳에 파일을 올리면 스마트폰 웹에서도 바로 다운로드 가능합니다")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [6])))
                }
                .buttonStyle(.plain)
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else { url = item as? URL }
                        if let url { DispatchQueue.main.async { model.selectedFile = url } }
                    }
                    return true
                }

                if model.isTransferring {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.transferLabel).font(.subheadline)
                        ProgressView(value: model.progress)
                        Text("\(Int(model.progress * 100))% 완료").font(.caption).foregroundStyle(.secondary)
                        Text(model.transferDetails).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack {
                    Label("로컬 직결 전송 · 외부 유출 위험 ZERO", systemImage: "lock.shield.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 14) {
                    Button(action: model.send) {
                        Label("선택한 기기로 보내기", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedFile == nil || model.selectedPeerID == nil || model.isTransferring)

                    Button(action: {
                        model.refreshWebBridgeInfo()
                        model.showWebBridgeSheet = true
                    }) {
                        Label("웹 브라우저로 공유 (QR)", systemImage: "qrcode")
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.background)
        .alert(item: Binding(get: { model.incoming }, set: { model.incoming = $0 })) { request in
            Alert(
                title: Text("파일 전송 요청"),
                message: Text("\(request.sender)이(가) \(request.fileName) (\(ByteCountFormatter.string(fromByteCount: request.size, countStyle: .file)) 파일) 전송을 요청합니다."),
                primaryButton: .default(Text("받기")) { model.respondToIncoming(true) },
                secondaryButton: .cancel(Text("거절")) { model.respondToIncoming(false) }
            )
        }
        .sheet(isPresented: $model.showWebBridgeSheet) {
            WebBridgeSheetView(
                url: model.webBridgeURL,
                qrImage: model.webBridgeQRCode,
                sharedFile: model.selectedFile,
                onDismiss: { model.showWebBridgeSheet = false }
            )
        }
    }
}

// Sheet View for Web Browser QR & Link Transfer
struct WebBridgeSheetView: View {
    let url: String
    let qrImage: NSImage?
    let sharedFile: URL?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("스마트폰 웹 브라우저와 직접 연결").font(.title3.bold())
                Spacer()
                Button("닫기", action: onDismiss).buttonStyle(.borderless)
            }

            Text("상대방 기기에 앱이 없어도 괜찮습니다!\n스마트폰 기본 카메라로 아래 QR 코드를 비추면 브라우저에서 즉시 송수신됩니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let qrImage {
                Image(nsImage: qrImage)
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
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
        .padding(28)
        .frame(width: 480, height: 490)
    }
}

private struct TransferRequest: Codable {
    let version: Int
    let sender: String
    let fileName: String
    let size: Int64
}

// MARK: - Native LanService (Bonjour + TCP Raw Sockets)
final class LanService {
    private let queue = DispatchQueue(label: "app.lanshare.network", qos: .userInitiated)
    private let deviceName = Host.current().localizedName ?? "Mac"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private var pending: [UUID: NWConnection] = [:]
    private let lock = NSLock()
    var onPeers: (([Peer]) -> Void)?
    var onIncoming: ((String, String, Int64, @escaping (Bool) -> Void) -> Void)?
    var onReceiveProgress: ((String, Int64, Int64) -> Void)?
    var onFailure: ((String) -> Void)?

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: deviceName, type: "_lanshare._tcp")
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.onFailure?("네트워크 수신을 시작하지 못했습니다") }
            }
            self.listener = listener
            listener.start(queue: queue)
            startBrowser()
        } catch { onFailure?("로컬 네트워크를 시작하지 못했습니다: \(error.localizedDescription)") }
    }

    func refreshPeers() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.cancel()
            self.browser = nil
            self.startBrowser()
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_lanshare._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error):
                self?.onFailure?("주변 기기 검색 대기 중: \(error.localizedDescription)")
            case .failed(let error):
                self?.onFailure?("주변 기기 검색 오류: \(error.localizedDescription)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { result -> Peer? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      name != self?.deviceName else { return nil }
                return Peer(id: name, name: name, endpoint: result.endpoint)
            }
            self?.onPeers?(peers)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, data: Data())
    }

    private func receiveRequest(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, _, error in
            guard let self else { return }
            var buffer = data
            if let chunk { buffer.append(chunk) }
            if let error { self.onFailure?("연결을 읽지 못했습니다: \(error.localizedDescription)"); connection.cancel(); return }
            guard let newline = buffer.firstIndex(of: 10) else {
                if buffer.count > 4096 { connection.cancel(); return }
                self.receiveRequest(on: connection, data: buffer)
                return
            }
            do {
                let request = try JSONDecoder().decode(TransferRequest.self, from: buffer[..<newline])
                guard request.version == 1, request.size >= 0, request.size <= 100_000_000_000,
                      Self.safeFileName(request.fileName) != nil else { throw TransferError.invalidRequest }
                let id = UUID()
                self.lock.lock(); self.pending[id] = connection; self.lock.unlock()
                self.onIncoming?(request.sender, request.fileName, request.size) { [weak self] accepted in
                    guard let self else { return }
                    self.lock.lock(); let conn = self.pending.removeValue(forKey: id); self.lock.unlock()
                    guard let conn else { return }
                    guard accepted else { conn.send(content: Data("REJECT\n".utf8), completion: .contentProcessed { _ in conn.cancel() }); return }
                    self.beginReceive(request, connection: conn)
                }
            } catch {
                connection.send(content: Data("REJECT\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func beginReceive(_ request: TransferRequest, connection: NWConnection) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let base = Self.safeFileName(request.fileName)!
        guard let (destination, output) = Self.createSafeDestination(directory: directory, name: base) else {
            connection.cancel(); onFailure?("다운로드 폴더에 파일을 만들 수 없습니다"); return
        }
        connection.send(content: Data("ACCEPT\n".utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { output.closeFile(); connection.cancel(); self.onFailure?("연결 오류: \(error.localizedDescription)"); return }
            self.receiveBytes(connection, output: output, fileName: base, expected: request.size, received: 0, url: destination)
        })
    }

    private func receiveBytes(_ connection: NWConnection, output: FileHandle, fileName: String, expected: Int64, received: Int64, url: URL) {
        if received == expected {
            output.closeFile(); connection.cancel(); onReceiveProgress?(fileName, expected, expected); return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            if let error { output.closeFile(); try? FileManager.default.removeItem(at: url); connection.cancel(); self.onFailure?("수신 중 연결이 끊겼습니다: \(error.localizedDescription)"); return }
            guard let chunk, !chunk.isEmpty else {
                if complete { output.closeFile(); try? FileManager.default.removeItem(at: url); self.onFailure?("파일을 다 받기 전에 연결이 종료됐습니다") }
                else { self.receiveBytes(connection, output: output, fileName: fileName, expected: expected, received: received, url: url) }
                return
            }
            let remaining = expected - received
            let part = chunk.prefix(Int(min(Int64(chunk.count), remaining)))
            output.write(Data(part))
            let count = received + Int64(part.count)
            self.onReceiveProgress?(fileName, count, expected)
            self.receiveBytes(connection, output: output, fileName: fileName, expected: expected, received: count, url: url)
        }
    }

    func send(file: URL, to peer: Peer, progress: @escaping (Double) -> Void) {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]), let rawSize = values.fileSize else {
            onFailure?("파일 크기를 읽을 수 없습니다"); return
        }
        let size = Int64(rawSize)
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onFailure?("기기에 연결하지 못했습니다: \(error.localizedDescription)") }
        }
        connection.start(queue: queue)
        let request = TransferRequest(version: 1, sender: deviceName, fileName: file.lastPathComponent, size: size)
        guard var message = try? JSONEncoder().encode(request) else { onFailure?("전송 요청을 만들지 못했습니다"); return }
        message.append(10)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { connection.cancel(); self.onFailure?("전송 요청을 보내지 못했습니다: \(error.localizedDescription)"); return }
            self.readDecision(connection, file: file, size: size, progress: progress)
        })
    }

    private func readDecision(_ connection: NWConnection, file: URL, size: Int64, progress: @escaping (Double) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, let answer = String(data: data, encoding: .utf8) else {
                connection.cancel(); self.onFailure?("상대 기기에서 응답을 받지 못했습니다"); return
            }
            guard answer.hasPrefix("ACCEPT") else { connection.cancel(); self.onFailure?("상대 기기가 전송을 거절했습니다"); return }
            guard let input = try? FileHandle(forReadingFrom: file) else { connection.cancel(); self.onFailure?("파일을 열지 못했습니다"); return }
            self.sendChunk(connection, input: input, size: size, sent: 0, progress: progress)
        }
    }

    private func sendChunk(_ connection: NWConnection, input: FileHandle, size: Int64, sent: Int64, progress: @escaping (Double) -> Void) {
        if sent == size { input.closeFile(); connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel(); progress(1) }); return }
        let data = input.readData(ofLength: 64 * 1024)
        guard !data.isEmpty else { input.closeFile(); connection.cancel(); onFailure?("파일을 읽는 중 예상보다 일찍 끝났습니다"); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { input.closeFile(); connection.cancel(); self?.onFailure?("파일을 보내지 못했습니다: \(error.localizedDescription)"); return }
            let count = sent + Int64(data.count)
            progress(size == 0 ? 1 : min(1, Double(count) / Double(size)))
            self?.sendChunk(connection, input: input, size: size, sent: count, progress: progress)
        })
    }

    static func safeFileName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 240 else { return nil }
        return name
    }

    static func createSafeDestination(directory: URL, name: String) -> (URL, FileHandle)? {
        let original = URL(fileURLWithPath: name)
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        for index in 1...10_000 {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let candidateName = index == 1 ? name : "\(stem) (\(index))\(suffix)"
            let url = directory.appendingPathComponent(candidateName)
            let descriptor = url.path.withCString { path in
                Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            if descriptor >= 0 { return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)) }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    enum TransferError: Error { case invalidRequest }
}

// MARK: - Web Bridge Service (HTTP Server for Zero-Install Browser Direct Transfer)
final class WebBridgeService {
    private let queue = DispatchQueue(label: "app.lanshare.webbridge", qos: .userInitiated)
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
                self?.handleHTTPConnection(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            print("WebBridgeService start failed: \(error)")
        }
    }

    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func readRequest() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if error != nil { connection.cancel(); return }

                if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerString = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
                    let bodyData = buffer[headerRange.upperBound...]
                    self.dispatchHTTP(requestHeader: headerString, body: Data(bodyData), connection: connection)
                } else if buffer.count < 32768 {
                    readRequest()
                } else {
                    connection.cancel()
                }
            }
        }
        readRequest()
    }

    private func dispatchHTTP(requestHeader: String, body: Data, connection: NWConnection) {
        let firstLine = requestHeader.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = parts[0]
        let path = parts[1]

        if method == "GET" && path == "/" {
            sendHTMLPage(connection: connection)
        } else if method == "GET" && path.hasPrefix("/download") {
            serveFileDownload(connection: connection)
        } else if method == "POST" && path.hasPrefix("/upload") {
            handleFileUpload(header: requestHeader, body: body, connection: connection)
        } else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func sendHTMLPage(connection: NWConnection) {
        let deviceName = Host.current().localizedName ?? "Mac"
        let currentFile = currentSharedFileProvider?()
        let fileName = currentFile?.lastPathComponent ?? ""
        let fileSizeStr: String
        if let currentFile, let size = try? currentFile.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            fileSizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            fileSizeStr = ""
        }

        let downloadSection: String
        if !fileName.isEmpty {
            downloadSection = """
            <div class="card">
              <h3>📥 Mac에서 파일 다운로드</h3>
              <p>파일명: <strong>\(fileName)</strong> (\(fileSizeStr))</p>
              <a href="/download" class="btn btn-primary" download>스마트폰에 저장하기</a>
            </div>
            """
        } else {
            downloadSection = """
            <div class="card" style="opacity: 0.7;">
              <h3>📥 Mac에서 파일 다운로드</h3>
              <p>현재 Mac의 LanShare 앱에서 선택된 파일이 없습니다.</p>
            </div>
            """
        }

        let html = """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>LanShare Web Bridge</title>
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
          </style>
        </head>
        <body>
          <div class="container">
            <div class="header">
              <h2>🌐 LanShare Web Bridge</h2>
              <p style="color: #94a3b8; font-size: 0.9rem;">연결된 Mac: <strong>\(deviceName)</strong></p>
            </div>

            \(downloadSection)

            <div class="card">
              <h3>📤 Mac으로 파일 / 사진 전송</h3>
              <form action="/upload" method="post" enctype="multipart/form-data">
                <input type="file" name="file" class="file-input" required>
                <button type="submit" class="btn btn-primary">Mac으로 직접 전송하기</button>
              </form>
            </div>
          </div>
        </body>
        </html>
        """

        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func serveFileDownload(connection: NWConnection) {
        guard let file = currentSharedFileProvider?(),
              let input = try? FileHandle(forReadingFrom: file),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        let encodedName = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/octet-stream\r
        Content-Disposition: attachment; filename="\(encodedName)"\r
        Content-Length: \(size)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.streamFileChunks(connection: connection, fileHandle: input, total: Int64(size), sent: 0)
        })
    }

    private func streamFileChunks(connection: NWConnection, fileHandle: FileHandle, total: Int64, sent: Int64) {
        if sent >= total {
            fileHandle.closeFile()
            connection.cancel()
            return
        }
        let chunk = fileHandle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty {
            fileHandle.closeFile()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { fileHandle.closeFile(); connection.cancel(); return }
            self?.streamFileChunks(connection: connection, fileHandle: fileHandle, total: total, sent: sent + Int64(chunk.count))
        })
    }

    private func handleFileUpload(header: String, body: Data, connection: NWConnection) {
        // Quick multipart boundary parsing
        let defaultName = "upload-\(Int(Date().timeIntervalSince1970)).bin"
        var targetFileName = defaultName
        if let filenameRange = header.range(of: "filename=\"") {
            let sub = header[filenameRange.upperBound...]
            if let endQuote = sub.firstIndex(of: "\"") {
                targetFileName = LanService.safeFileName(String(sub[..<endQuote])) ?? defaultName
            }
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        if let (_, handle) = LanService.createSafeDestination(directory: downloads, name: targetFileName) {
            handle.write(body)
            handle.closeFile()
            onUploadedFileReceived?(targetFileName, Int64(body.count))
        }

        let successHTML = """
        <!DOCTYPE html><html><body style="background:#0f172a;color:#fff;font-family:sans-serif;text-align:center;padding:40px;">
          <h2>🎉 전송 완료!</h2>
          <p>Mac의 다운로드 폴더에 안전하게 저장되었습니다.</p>
          <a href="/" style="color:#38bdf8;text-decoration:none;">← 돌아가기</a>
        </body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(successHTML.utf8.count)\r
        Connection: close\r
        \r
        \(successHTML)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" || name == "wlan0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }

    static func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
