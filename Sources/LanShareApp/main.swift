import AppKit
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
    let code: String
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

    @Published var codeEntry = ""

    private let service = LanService()
    var localCode: String { service.localCode }
    private var transferStartedAt = ProcessInfo.processInfo.systemUptime

    init() {
        service.onPeers = { [weak self] peers in
            Task { @MainActor in
                self?.peers = peers
                if let self, self.codeEntry.count == 4, peers.contains(where: { $0.code == self.codeEntry }) {
                    self.connectByCode()
                } else {
                    self?.status = peers.isEmpty ? "같은 네트워크의 기기 코드를 찾는 중" : "\(peers.count)대의 같은 네트워크 기기를 찾았습니다"
                }
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
    }

    func connectByCode() {
        let code = codeEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 4, code.allSatisfy(\.isNumber) else {
            status = "상대방의 4자리 코드를 입력하세요"
            selectedPeerID = nil
            return
        }
        let matches = peers.filter { $0.code == code }
        guard matches.count == 1, let peer = matches.first else {
            selectedPeerID = nil
            status = matches.isEmpty
                ? "코드 \(code) 기기를 찾지 못했습니다. 같은 네트워크인지 확인하세요."
                : "같은 코드 기기가 여러 대입니다. 앱을 다시 열어 새 코드를 발급하세요."
            return
        }
        selectedPeerID = peer.id
        status = "코드 \(code) 기기에 연결했습니다. 파일을 선택해 보내세요."
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LanShareModel

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar: Local code and discovered peers
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LanShare").font(.title2.bold())
                        Text("로컬 고속 다이렉트 전송").font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("내 연결 코드").font(.caption).foregroundStyle(.secondary)
                    Text(model.localCode).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.blue)
                    TextField("상대방 4자리 코드", text: $model.codeEntry)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.codeEntry) { value in
                            let digits = String(value.filter(\.isNumber).prefix(4))
                            if digits != value { model.codeEntry = digits }
                        }
                        .onSubmit { model.connectByCode() }
                    Button("코드 연결", action: model.connectByCode)
                        .buttonStyle(.borderedProminent)
                    Text("같은 Wi-Fi 또는 로컬 네트워크에서만 연결됩니다.").font(.caption2).foregroundStyle(.secondary)
                }

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
                        Text("상대 기기에서 LanShare를 열고 표시된 4자리 코드를 입력하세요.")
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
                            Text("같은 네트워크의 LanShare 기기에 직접 전송합니다")
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
    let localCode = String(Int.random(in: 1000...9999))
    private var serviceName: String { "LanShare-\(localCode)" }
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
            listener.service = NWListener.Service(name: serviceName, type: "_lanshare._tcp")
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
                      name != self?.serviceName,
                      name.hasPrefix("LanShare-") else { return nil }
                let code = String(name.dropFirst("LanShare-".count))
                guard code.count == 4, code.allSatisfy(\.isNumber) else { return nil }
                return Peer(id: name, code: code, name: "LanShare · 코드 \(code)", endpoint: result.endpoint)
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
