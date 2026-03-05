import Foundation
import os.log

private let logger = Logger(subsystem: "com.ronin.app", category: "BackendProcess")

@MainActor
class BackendProcessService: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .stopped: return "Backend stopped"
            case .starting: return "Starting backend…"
            case .running: return "Backend running"
            case .failed(let msg): return msg
            }
        }
    }

    @Published var status: Status = .stopped

    /// Recent backend log lines (last 200 lines, captured from stdout/stderr)
    @Published var recentLogs: [String] = []
    private let maxLogLines = 200

    private var process: Process?
    private var outputPipe: Pipe?
    private var healthCheckTask: Task<Void, Never>?

    /// Path to the backend's log file
    var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/Ronin/backend.log"
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil || !(process?.isRunning ?? false) else { return }

        status = .starting
        recentLogs = []

        // Determine paths — support both bundled (Resources/) and dev mode
        let resourcePath: String
        let pythonPath: String
        let backendDir: String
        let sitePackagesPath: String
        let modelCachePath: String?

        if let bundlePath = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: bundlePath + "/python/bin/python3.14") {
            // --- Bundled mode (inside .app) ---
            resourcePath = bundlePath
            pythonPath = bundlePath + "/python/bin/python3.14"
            backendDir = bundlePath + "/backend"
            sitePackagesPath = bundlePath + "/python/lib/python3.14/site-packages"
            modelCachePath = bundlePath + "/models/huggingface/hub"
            appendLog("[RONIN] Bundled mode — Resources: \(bundlePath)")
        } else {
            // --- Dev mode (running from Xcode) ---
            let projectRoot = findProjectRoot()
            pythonPath = projectRoot + "/backend/.venv/bin/python3.14"
            backendDir = projectRoot + "/backend"
            sitePackagesPath = projectRoot + "/backend/.venv/lib/python3.14/site-packages"
            resourcePath = projectRoot
            modelCachePath = nil
            appendLog("[RONIN] Dev mode — project: \(projectRoot)")
        }

        let runScript = backendDir + "/run.py"

        appendLog("[RONIN] Python: \(pythonPath)")
        appendLog("[RONIN] Backend: \(runScript)")
        if let mc = modelCachePath { appendLog("[RONIN] Model cache: \(mc)") }

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            status = .failed("Python not found at: \(pythonPath)")
            return
        }

        guard FileManager.default.fileExists(atPath: runScript) else {
            status = .failed("Backend not found at: \(runScript)")
            return
        }

        // If port 8000 is in use, try to kill the orphaned process
        if isPortInUse(port: 8000) {
            appendLog("[RONIN] Port 8000 in use — killing orphaned process...")
            if killProcessOnPort(8000) {
                appendLog("[RONIN] Orphaned process killed, port freed")
            } else {
                status = .failed("Port 8000 is in use by another application. Close it and try again.")
                return
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [runScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: backendDir)

        var env: [String: String] = [
            "PYTHONPATH": sitePackagesPath,
            "HF_HUB_OFFLINE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        if let modelCache = modelCachePath {
            env["HF_HUB_CACHE"] = modelCache
        }

        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe

        // Read stdout/stderr asynchronously and capture log lines
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                Task { @MainActor [weak self] in
                    for line in lines {
                        self?.appendLog(line)
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                self.appendLog("[RONIN] Backend process exited with code \(proc.terminationStatus)")
                if proc.terminationStatus != 0 && proc.terminationStatus != 15 {
                    self.status = .failed("Backend exited unexpectedly (code \(proc.terminationStatus))")
                } else if self.status == .running || self.status == .starting {
                    self.status = .stopped
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            appendLog("[RONIN] Backend process launched (PID: \(proc.processIdentifier))")
            healthCheckTask = Task { await waitForHealth() }
        } catch {
            status = .failed("Failed to launch backend: \(error.localizedDescription)")
        }
    }

    /// Async stop — used during normal app lifecycle (e.g. restart)
    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        guard let proc = process, proc.isRunning else {
            process = nil
            status = .stopped
            return
        }

        let pid = proc.processIdentifier
        appendLog("[RONIN] Stopping backend (PID: \(pid))...")
        proc.terminate() // SIGTERM

        // Give it 3 seconds then force kill
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            if proc.isRunning {
                logger.warning("Backend did not exit after SIGTERM, sending SIGKILL")
                kill(pid, SIGKILL)
            }
            Task { @MainActor in
                self?.process = nil
                self?.status = .stopped
            }
        }
    }

    /// Synchronous stop — used during app termination.
    /// Blocks the calling thread until the process is dead.
    /// MUST be called from applicationWillTerminate (main thread is fine — app is exiting).
    nonisolated func stopSync() {
        // Access the process directly (we're on the main thread during termination)
        MainActor.assumeIsolated {
            healthCheckTask?.cancel()
            healthCheckTask = nil
            outputPipe?.fileHandleForReading.readabilityHandler = nil

            guard let proc = process, proc.isRunning else {
                process = nil
                return
            }

            let pid = proc.processIdentifier
            logger.info("stopSync: sending SIGTERM to PID \(pid)")
            proc.terminate()

            // Wait up to 3 seconds for graceful exit
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            // Force kill if still running
            if proc.isRunning {
                logger.warning("stopSync: SIGTERM timeout, sending SIGKILL to PID \(pid)")
                kill(pid, SIGKILL)
                // Brief wait for SIGKILL to take effect
                Thread.sleep(forTimeInterval: 0.5)
            }

            logger.info("stopSync: backend process terminated")
            process = nil
        }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Logging

    private func appendLog(_ line: String) {
        logger.debug("\(line)")
        recentLogs.append(line)
        if recentLogs.count > maxLogLines {
            recentLogs.removeFirst(recentLogs.count - maxLogLines)
        }
    }

    // MARK: - Health Check

    private func waitForHealth() async {
        let api = BackendAPIService()
        for attempt in 1...30 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(1))

            if await api.checkHealth() {
                appendLog("[RONIN] Health check passed on attempt \(attempt)")
                status = .running
                return
            }

            // Check if process died during startup
            if let proc = process, !proc.isRunning {
                status = .failed("Backend process exited during startup")
                return
            }

            if attempt % 10 == 0 {
                appendLog("[RONIN] Still waiting for health... (attempt \(attempt))")
                status = .starting
            }
        }
        status = .failed("Backend did not respond within 30 seconds")
    }

    // MARK: - Helpers

    private func findProjectRoot() -> String {
        var url = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let backendPath = url.appendingPathComponent("backend/run.py").path
            if FileManager.default.fileExists(atPath: backendPath) {
                return url.path
            }
        }
        return "/Users/matthewjohnson/RONIN"
    }

    private func isPortInUse(port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.connect(sock, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Find and kill whatever process is listening on a given port.
    /// Returns true if we successfully freed the port.
    private func killProcessOnPort(_ port: UInt16) -> Bool {
        // Use lsof to find PID(s) listening on the port
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", ":\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // suppress stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logger.error("Failed to run lsof: \(error.localizedDescription)")
            return false
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        guard !pids.isEmpty else {
            logger.warning("lsof found no PIDs on port \(port)")
            return false
        }

        for pid in pids {
            logger.info("Killing orphaned process PID \(pid) on port \(port)")
            kill(pid, SIGTERM)
        }

        // Wait up to 3 seconds for process(es) to die
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            if !isPortInUse(port: port) {
                return true
            }
        }

        // Force kill
        for pid in pids {
            logger.warning("SIGTERM failed for PID \(pid), sending SIGKILL")
            kill(pid, SIGKILL)
        }
        Thread.sleep(forTimeInterval: 0.5)

        return !isPortInUse(port: port)
    }
}
