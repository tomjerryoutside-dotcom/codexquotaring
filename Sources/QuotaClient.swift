import Foundation

/// Read-only local stdio connection. No inference, debug ports, card redemption, or raw log output.
final class QuotaClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let queue = DispatchQueue(label: "local.quota-ring.rpc")
    private var buffer = Data()
    private var nextID = 10
    private var initialized = false
    private var waiting: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var ready: (() -> Void)?
    private var generation = 0
    private var runningRequest = false
    private var retryAfter = Date.distantPast
    private var failureCount = 0

    enum ClientError: LocalizedError {
        case missingCLI, failed(String)
        var errorDescription: String? {
            switch self { case .missingCLI: return "未找到 Codex CLI"; case .failed(let s): return s }
        }
    }
    static func cliURL() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            NSHomeDirectory()+"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            NSHomeDirectory()+"/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func fetch(_ completion: @escaping (Result<QuotaSnapshot, Error>) -> Void) {
        queue.async {
            guard !self.runningRequest, Date() >= self.retryAfter else { return }
            self.runningRequest = true
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                self.runningRequest = false
                switch result {
                case .success(let json):
                    self.failureCount = 0
                    DispatchQueue.main.async { completion(.success(.parse(json))) }
                case .failure(let error):
                    self.failureCount += 1
                    self.retryAfter = max(self.retryAfter, Date().addingTimeInterval(min(900, 60 * pow(2, Double(self.failureCount-1)))))
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
            if self.initialized, self.process?.isRunning == true {
                self.requestQuota(finish)
            } else {
                do {
                    try self.start()
                    self.ready = { self.requestQuota(finish) }
                    self.send(method: "initialize", params: ["clientInfo": ["name": "local_quota_ring", "title": "Quota Ring", "version": "0.1.0"], "capabilities": ["experimentalApi": true]]) { result in
                        switch result {
                        case .success:
                            self.initialized = true
                            self.write(["method": "initialized"])
                            let ready = self.ready; self.ready = nil; ready?()
                        case .failure(let error): self.ready = nil; finish(.failure(error))
                        }
                    }
                } catch { finish(.failure(error)) }
            }
        }
    }

    private func requestQuota(_ callback: @escaping (Result<[String: Any], Error>) -> Void) {
        send(method: "account/rateLimits/read", params: nil, completion: callback)
    }

    private func start() throws {
        stopOnQueue()
        guard let executable = Self.cliURL() else { throw ClientError.missingCLI }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = executable
        p.arguments = ["app-server", "--listen", "stdio://"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        generation += 1; let token = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                if chunk.isEmpty { self.failAll("额度连接已断开"); return }
                self.buffer.append(chunk)
                if self.buffer.count > 2_000_000 { self.failAll("额度返回格式异常"); return }
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    self.buffer.removeSubrange(...end)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.receive(obj) }
                }
            }
        }
        try p.run()
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }

    private func send(method: String, params: [String: Any]?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        nextID += 1; let id = nextID, token = generation
        waiting[id] = completion
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        write(message)
        queue.asyncAfter(deadline: .now()+25) { [weak self] in
            guard let self, self.generation == token, self.waiting[id] != nil else { return }
            self.failAll("额度读取超时，稍后自动重试")
        }
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        do { try input?.write(contentsOf: data + Data([10])) }
        catch { failAll("无法连接额度服务") }
    }

    private func receive(_ obj: [String: Any]) {
        guard let id = obj["id"] as? Int, let callback = waiting.removeValue(forKey: id) else { return }
        if let result = obj["result"] as? [String: Any] { callback(.success(result)) }
        else {
            let error = obj["error"] as? [String: Any]
            let raw = (error?["message"] as? String ?? "").lowercased()
            let message = raw.contains("429") || raw.contains("rate limit") ? "请求受限，稍后自动重试" : "额度读取失败，请检查 Codex 登录和网络"
            if raw.contains("429") || raw.contains("rate limit") { retryAfter = Date().addingTimeInterval(900) }
            callback(.failure(ClientError.failed(message)))
        }
    }

    private func failAll(_ message: String) {
        let callbacks = Array(waiting.values); waiting.removeAll(); ready = nil
        stopOnQueue()
        callbacks.forEach { $0(.failure(ClientError.failed(message))) }
    }
    private func stopOnQueue() {
        generation += 1; initialized = false
        output?.readabilityHandler = nil; try? input?.close(); try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; buffer.removeAll()
    }
    func stop() { queue.sync { stopOnQueue() } }
}
