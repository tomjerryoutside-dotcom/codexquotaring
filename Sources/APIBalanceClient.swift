import Foundation

/// A user-triggered browser read. Never scheduled with the normal quota poll.
final class APIBalanceClient {
    private let queue = DispatchQueue(label: "local.quota-ring.api-balance")
    private let lock = NSLock()
    private var process: Process?
    private let prefs: UserDefaults
    init(prefs: UserDefaults = .standard) { self.prefs = prefs }

    enum SyncError: LocalizedError {
        case missingBrowser, needsLogin, failed
        var errorDescription: String? {
            switch self {
            case .missingBrowser: return "请先安装 ego lite，再同步 API 余额。"
            case .needsLogin: return "请在 ego lite 登录官方账单页，再点“同步 API 余额”。"
            case .failed: return "API 同步未完成；保留上次核实值，请稍后手动重试。"
            }
        }
    }

    static func cliURL() -> URL? {
        [NSHomeDirectory()+"/.local/bin/ego-browser", "/usr/local/bin/ego-browser", "/opt/homebrew/bin/ego-browser"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func sync(_ completion: @escaping (Result<APIBalanceSnapshot, Error>) -> Void) {
        queue.async {
            let result: Result<APIBalanceSnapshot, Error>
            do {
                guard let executable = Self.cliURL() else { throw SyncError.missingBrowser }
                guard let url = Bundle.main.url(forResource: "sync-api-balance", withExtension: "js") else { throw SyncError.failed }
                let context = self.prefs.dictionary(forKey: "apiBalancePendingTask") ?? [:]
                let data = try JSONSerialization.data(withJSONObject: context)
                let script = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: "__QUOTARING_CONTEXT__", with: String(decoding: data, as: UTF8.self))
                let p = Process(), input = Pipe(), output = Pipe()
                p.executableURL = executable; p.arguments = ["nodejs"]
                p.standardInput = input; p.standardOutput = output; p.standardError = output
                p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                self.lock.lock(); self.process = p; self.lock.unlock()
                try p.run()
                let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now()+75, execute: timeout)
                defer { timeout.cancel() }
                try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try input.fileHandleForWriting.close()
                var captured = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    guard captured.count + chunk.count <= 131_072 else { p.terminate(); throw SyncError.failed }
                    captured.append(chunk)
                }
                p.waitUntilExit()
                let lines = String(decoding: captured, as: UTF8.self).components(separatedBy: .newlines)
                var response: [String: Any]?
                for line in lines {
                    if let task = Self.message(line, prefix: "QUOTARING_API_TASK "),
                       let id = task["spaceId"] as? Int, id > 0 {
                        self.prefs.set(["spaceId": id, "handoff": task["handoff"] as? Bool ?? false], forKey: "apiBalancePendingTask")
                    }
                    if let message = Self.message(line, prefix: "QUOTARING_API_RESULT ") { response = message }
                }
                guard p.terminationStatus == 0, let response else { throw SyncError.failed }
                if response["status"] as? String == "needs_login" { throw SyncError.needsLogin }
                guard response["status"] as? String == "ok", let snapshot = APIBalanceSnapshot.parse(response) else { throw SyncError.failed }
                self.prefs.removeObject(forKey: "apiBalancePendingTask")
                snapshot.save(to: self.prefs)
                result = .success(snapshot)
            } catch { result = .failure(error) }
            self.lock.lock(); let remainingProcess = self.process; self.process = nil; self.lock.unlock()
            if remainingProcess?.isRunning == true { remainingProcess?.terminate() }
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func message(_ line: String, prefix: String) -> [String: Any]? {
        guard line.hasPrefix(prefix), let data = String(line.dropFirst(prefix.count)).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func stop() {
        lock.lock(); let p = process; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }
}
