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

    func refresh() { peers = []; selectedPeerID = nil; status = "주변 기기를 다시 찾는 중입니다…"; service.refresh() }
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
                    HStack {
                        Label("LanShare", systemImage: "arrow.up.arrow.down.circle.fill").font(.title2.bold())
                        Spacer()
                        Button("새로고침", systemImage: "arrow.clockwise") { model.refresh() }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("주변 기기 새로고침")
                    }
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section("주변 기기") {
                    if model.peers.isEmpty {
                        Text("상대 기기에서 LanShare를 열고 같은 Wi-Fi에 연결하세요.").font(.footnote).foregroundStyle(.secondary)
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
                    Label("개발용 프로토콜 · 전송 암호화 미지원", systemImage: "exclamationmark.shield.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("전송 중 앱을 닫거나 백그라운드로 보내면 iOS가 연결을 중단할 수 있습니다. 파일을 받는 동안 앱을 열어 두세요.")
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
                let request = try JSONDecoder().decode(TransferRequest.self, from: bytes[..<end])
                guard request.version == 1, request.size >= 0, request.size <= 100_000_000_000, Self.safeName(request.fileName) != nil else { throw TransferError.invalidRequest }
                let id = UUID()
                self.pending[id] = connection
                self.onIncoming?(Incoming(sender: request.sender, fileName: request.fileName, size: request.size) { [weak self] accepted in
                    self?.queue.async { self?.decide(id: id, request: request, accepted: accepted) }
                })
            } catch {
                connection.send(content: Data("REJECT\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    private func decide(id: UUID, request: TransferRequest, accepted: Bool) {
        guard let connection = pending.removeValue(forKey: id) else { return }
        guard accepted else { connection.send(content: Data("REJECT\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("LanShare", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { connection.cancel(); onError?("저장 폴더를 만들 수 없습니다: \(error.localizedDescription)"); return }
        guard let (url, output) = createSafeDestination(directory: directory, name: request.fileName) else {
            connection.cancel(); onError?("파일을 저장할 수 없습니다"); return
        }
        active = connection
        connection.send(content: Data("ACCEPT\n".utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { try? output.close(); try? FileManager.default.removeItem(at: url); connection.cancel(); self.onError?("연결 오류: \(error.localizedDescription)"); return }
            self.readPayload(connection, output: output, url: url, name: request.fileName, total: request.size, received: 0)
        })
    }
    private func readPayload(_ connection: NWConnection, output: FileHandle, url: URL, name: String, total: Int64, received: Int64) {
        if received == total {
            try? output.close(); connection.cancel(); active = nil
            onProgress?("받는 중 · \(name)", total, total); onComplete?("파일을 파일 앱의 LanShare 폴더에 저장했습니다")
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else {
                try? output.close(); try? FileManager.default.removeItem(at: url); connection.cancel(); self.active = nil
                self.onError?(complete ? "파일 전송이 끝나기 전에 연결이 종료됐습니다" : "전송 중 연결이 끊겼습니다")
                return
            }
            let part = data.prefix(Int(min(Int64(data.count), total - received)))
            do { try output.write(contentsOf: Data(part)) }
            catch {
                try? output.close(); try? FileManager.default.removeItem(at: url); connection.cancel(); self.active = nil
                self.onError?("파일을 저장하지 못했습니다: \(error.localizedDescription)"); return
            }
            let count = received + Int64(part.count)
            self.onProgress?("받는 중 · \(name)", count, total)
            self.readPayload(connection, output: output, url: url, name: name, total: total, received: count)
        }
    }
    func send(file: URL, to peer: Peer) {
        queue.async { [weak self] in
            guard let self else { return }
            let scoped = file.startAccessingSecurityScopedResource()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let rawSize = attributes[.size] as? NSNumber,
                  let input = try? FileHandle(forReadingFrom: file) else {
                if scoped { file.stopAccessingSecurityScopedResource() }
                self.onError?("파일을 읽을 수 없습니다"); return
            }
            let size = rawSize.int64Value
            let request = TransferRequest(version: 1, sender: self.deviceName, fileName: file.lastPathComponent, size: size)
            guard var header = try? JSONEncoder().encode(request) else { try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }; return }
            header.append(10)
            let connection = NWConnection(to: peer.endpoint, using: .tcp)
            self.active = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state { try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }; self?.active = nil; self?.onError?("기기에 연결하지 못했습니다: \(error.localizedDescription)") }
            }
            connection.start(queue: self.queue)
            connection.send(content: header, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error { try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }; connection.cancel(); self.onError?("전송 요청 오류: \(error.localizedDescription)"); return }
                self.readDecision(connection, file: file, input: input, scoped: scoped, size: size, sent: 0)
            })
        }
    }
    private func readDecision(_ connection: NWConnection, file: URL, input: FileHandle, scoped: Bool, size: Int64, sent: Int64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, String(data: data, encoding: .utf8)?.hasPrefix("ACCEPT") == true else {
                try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }; connection.cancel(); self.active = nil; self.onError?("상대 기기가 전송을 거절했거나 응답하지 않았습니다"); return
            }
            self.sendChunk(connection, file: file, input: input, scoped: scoped, size: size, sent: sent)
        }
    }
    private func sendChunk(_ connection: NWConnection, file: URL, input: FileHandle, scoped: Bool, size: Int64, sent: Int64) {
        if sent == size {
            try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                connection.cancel(); self?.active = nil; self?.onProgress?("보내는 중 · \(file.lastPathComponent)", size, size); self?.onComplete?("전송을 완료했습니다")
            })
            return
        }
        guard let data = try? input.read(upToCount: 64 * 1024), !data.isEmpty else {
            try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }; connection.cancel(); active = nil; onError?("파일을 읽는 중 예상보다 일찍 끝났습니다"); return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { try? input.close(); if scoped { file.stopAccessingSecurityScopedResource() }; connection.cancel(); self.active = nil; self.onError?("파일 전송 오류: \(error.localizedDescription)"); return }
            let count = sent + Int64(data.count)
            self.onProgress?("보내는 중 · \(file.lastPathComponent)", count, size)
            self.sendChunk(connection, file: file, input: input, scoped: scoped, size: size, sent: count)
        })
    }
    private static func safeName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains(":"), name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    private func createSafeDestination(directory: URL, name: String) -> (URL, FileHandle)? {
        guard Self.safeName(name) != nil else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 1...10_000 {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let candidate = index == 1 ? name : "\(stem) (\(index))\(suffix)"
            let url = directory.appendingPathComponent(candidate)
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
