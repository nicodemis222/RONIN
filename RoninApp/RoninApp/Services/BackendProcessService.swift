import AVFoundation
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

    /// Auth token received from the backend at startup.
    /// Used to authenticate all HTTP and WebSocket requests.
    @Published var authToken: String = ""

    /// Startup dependency check states
    @Published var dependencies: [DependencyCheck] = [
        .pythonRuntime(.pending),
        .backendProcess(.pending),
        .whisperModel(.pending),
        .llmProvider(.pending, detail: ""),
        .microphoneAccess(.pending),
    ]

    /// True when every dependency has passed (or been acceptably skipped)
    var allDependenciesPassed: Bool {
        dependencies.allSatisfy { dep in
            dep.state.isPassed || dep.state.isSkipped
        }
    }

    /// Recent backend log lines (last 200 lines, captured from stdout/stderr)
    @Published var recentLogs: [String] = []
    private let maxLogLines = 200

    private var process: Process?
    private var outputPipe: Pipe?
    private var healthCheckTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?

    /// Path to the backend's log file
    var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/Ronin/backend.log"
    }

    // MARK: - Lifecycle

    /// Start observing LLM settings changes.
    /// Call once from app startup so changing provider in Settings triggers a restart.
    func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .roninLLMSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appendLog("[RONIN] LLM settings changed — restarting backend")
                self?.restart()
            }
        }
    }

    func start() {
        guard process == nil || !(process?.isRunning ?? false) else { return }

        status = .starting
        recentLogs = []

        // Reset dependency states
        dependencies = [
            .pythonRuntime(.checking),
            .backendProcess(.pending),
            .whisperModel(.pending),
            .llmProvider(.pending, detail: ""),
            .microphoneAccess(.pending),
        ]

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
            // Only set model cache if models were bundled (may be absent if built without Whisper)
            let candidateCache = bundlePath + "/models/huggingface/hub"
            modelCachePath = FileManager.default.fileExists(atPath: candidateCache) ? candidateCache : nil
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
            updateDependency(.pythonRuntime(.failed("Not found at: \(pythonPath)")))
            status = .failed("Python not found at: \(pythonPath)")
            return
        }
        updateDependency(.pythonRuntime(.passed))

        guard FileManager.default.fileExists(atPath: runScript) else {
            updateDependency(.backendProcess(.failed("run.py not found")))
            status = .failed("Backend not found at: \(runScript)")
            return
        }

        // If port 8000 is in use, try to kill the orphaned process
        if isPortInUse(port: 8000) {
            appendLog("[RONIN] Port 8000 in use — killing orphaned process...")
            if killProcessOnPort(8000) {
                appendLog("[RONIN] Orphaned process killed, port freed")
            } else {
                updateDependency(.backendProcess(.failed("Port 8000 in use")))
                status = .failed("Port 8000 is in use by another application. Close it and try again.")
                return
            }
        }

        updateDependency(.backendProcess(.checking))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [runScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: backendDir)

        var env: [String: String] = [
            "PYTHONPATH": sitePackagesPath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        if let modelCache = modelCachePath {
            // Bundled mode: models are pre-cached, no network needed
            env["HF_HUB_CACHE"] = modelCache
            env["HF_HUB_OFFLINE"] = "1"
        }
        // Dev mode: allow HuggingFace downloads so the Whisper model can be
        // fetched on first run (HF_HUB_OFFLINE is intentionally NOT set).

        // LLM provider settings from UserDefaults + Keychain
        let llmProvider = UserDefaults.standard.string(forKey: "ronin.llm.provider") ?? "local"

        // Apple Intelligence runs copilot natively in Swift — backend runs in transcription-only mode
        if llmProvider == "apple_intelligence" {
            env["LLM_PROVIDER"] = "none"
            appendLog("[RONIN] LLM provider: Apple Intelligence (backend in transcription-only mode)")
        } else {
            env["LLM_PROVIDER"] = llmProvider
            appendLog("[RONIN] LLM provider: \(llmProvider)")
        }

        let llmModel = UserDefaults.standard.string(forKey: "ronin.llm.model") ?? ""
        if !llmModel.isEmpty {
            env["LLM_MODEL"] = llmModel
        }

        let localURL = UserDefaults.standard.string(forKey: "ronin.llm.localURL")
            ?? "http://localhost:1234/v1"
        env["LM_STUDIO_URL"] = localURL

        // API keys from Keychain (never stored in UserDefaults)
        if let openaiKey = KeychainHelper.load(key: "ronin.openai-api-key"), !openaiKey.isEmpty {
            env["OPENAI_API_KEY"] = openaiKey
        }

        if let anthropicKey = KeychainHelper.load(key: "ronin.anthropic-api-key"), !anthropicKey.isEmpty {
            env["ANTHROPIC_API_KEY"] = anthropicKey
        }

        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outputPipe = pipe

        // Read stdout/stderr asynchronously and capture log lines + auth token
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                Task { @MainActor [weak self] in
                    for line in lines {
                        // Capture auth token from backend stdout
                        if line.hasPrefix("RONIN_AUTH_TOKEN=") {
                            let token = String(line.dropFirst("RONIN_AUTH_TOKEN=".count))
                            self?.authToken = token
                            self?.appendLog("[RONIN] Auth token received")
                        } else {
                            self?.appendLog(line)
                        }
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
            updateDependency(.backendProcess(.failed("Launch failed")))
            status = .failed("Failed to launch backend: \(error.localizedDescription)")
        }
    }

    /// Async stop — used during normal app lifecycle (e.g. restart)
    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }

        guard let proc = process, proc.isRunning else {
            process = nil
            status = .stopped
            return
        }

        let pid = proc.processIdentifier
        appendLog("[RONIN] Stopping backend (PID: \(pid))...")

        // Request graceful shutdown (saves active transcript) before SIGTERM
        let api = BackendAPIService()
        api.authToken = authToken
        Task {
            let saved = await api.requestGracefulShutdown()
            appendLog(saved
                ? "[RONIN] Graceful shutdown: transcript saved"
                : "[RONIN] Graceful shutdown: no transcript to save (or timeout)")
        }

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

            // Synchronous graceful shutdown — save active transcript before SIGTERM
            _syncGracefulShutdown()

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

    /// Blocking HTTP call to /meeting/shutdown (2s timeout).
    /// Called from stopSync() during app termination where async is unavailable.
    private func _syncGracefulShutdown() {
        guard !authToken.isEmpty,
              let url = URL(string: "http://127.0.0.1:8000/meeting/shutdown") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var success = false

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            success = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }
        task.resume()

        let result = semaphore.wait(timeout: .now() + 2)
        if result == .timedOut {
            logger.warning("stopSync: graceful shutdown timed out")
            task.cancel()
        } else {
            logger.info("stopSync: graceful shutdown \(success ? "saved transcript" : "no active transcript")")
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
                updateDependency(.backendProcess(.passed))

                // If auth token wasn't received via pipe, try the fallback file
                if authToken.isEmpty {
                    readAuthTokenFromFallbackFile()
                }

                status = .running

                // Fetch detailed subsystem status
                await checkDetailedHealth(api: api)

                // Check microphone permission
                checkMicrophonePermission()
                return
            }

            // Check if process died during startup
            if let proc = process, !proc.isRunning {
                let exitCode = proc.terminationStatus
                appendLog("[RONIN] Backend exited during startup (code \(exitCode))")
                // Try to read logs for diagnosis
                if let logData = FileManager.default.contents(atPath: logFilePath),
                   let logText = String(data: logData, encoding: .utf8) {
                    let lastLines = logText.components(separatedBy: .newlines).suffix(5)
                    for line in lastLines where !line.isEmpty {
                        appendLog("[BACKEND] \(line)")
                    }
                }
                updateDependency(.backendProcess(.failed("Exited during startup (code \(exitCode))")))
                status = .failed("Backend process exited during startup (code \(exitCode)). Check ~/Library/Logs/Ronin/backend.log")
                return
            }

            if attempt % 10 == 0 {
                appendLog("[RONIN] Still waiting for health... (attempt \(attempt))")
                status = .starting
            }
        }
        updateDependency(.backendProcess(.failed("Health timeout")))
        status = .failed("Backend did not respond within 30 seconds")
    }

    /// Fallback: read auth token from temp file written by the backend
    /// when the stdout pipe is broken (BrokenPipeError).
    private func readAuthTokenFromFallbackFile() {
        let fallbackPath = NSTemporaryDirectory() + "ronin_auth_token"
        guard let data = FileManager.default.contents(atPath: fallbackPath),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            appendLog("[RONIN] ⚠️ No auth token from pipe or fallback file")
            return
        }
        authToken = token
        appendLog("[RONIN] Auth token recovered from fallback file")

        // Clean up the file
        try? FileManager.default.removeItem(atPath: fallbackPath)
    }

    // MARK: - Detailed Health

    /// Query /health?details=true and update whisper + LLM dependency states.
    private func checkDetailedHealth(api: BackendAPIService) async {
        api.authToken = authToken

        guard let details = await api.checkHealthDetailed() else {
            appendLog("[RONIN] Detailed health check failed — skipping dependency update")
            updateDependency(.whisperModel(.skipped("Could not query")))
            updateDependency(.llmProvider(.skipped("Could not query"), detail: ""))
            return
        }

        // Whisper
        if let whisper = details.dependencies["whisper"] {
            if whisper.status == "loaded" || whisper.status == "available" {
                updateDependency(.whisperModel(.passed))
                appendLog("[RONIN] Whisper: \(whisper.status) (\(whisper.model ?? "unknown"))")
            } else {
                updateDependency(.whisperModel(.failed(whisper.detail ?? "Not loaded")))
                appendLog("[RONIN] Whisper: \(whisper.status)")
            }
        } else {
            updateDependency(.whisperModel(.failed("Not reported")))
        }

        // LLM
        let selectedProvider = UserDefaults.standard.string(forKey: "ronin.llm.provider") ?? "local"
        if selectedProvider == "apple_intelligence" {
            // Apple Intelligence is handled natively in Swift, not by the backend
            if FoundationModelsAvailability.isAvailable {
                updateDependency(.llmProvider(.passed, detail: "Apple Intelligence"))
                appendLog("[RONIN] LLM: Apple Intelligence (on-device)")
            } else {
                updateDependency(.llmProvider(.failed("Apple Intelligence not available on this device"), detail: "Apple Intelligence"))
                appendLog("[RONIN] LLM: Apple Intelligence not available")
            }
        } else if let llm = details.dependencies["llm"] {
            let provider = llm.provider ?? "unknown"
            if llm.status == "ok" || llm.status == "connected" {
                let detail = llm.model ?? provider
                updateDependency(.llmProvider(.passed, detail: detail))
                appendLog("[RONIN] LLM: \(provider) (\(llm.model ?? "default"))")
            } else if llm.status == "none" {
                updateDependency(.llmProvider(.skipped("Transcription-only mode"), detail: "none"))
                appendLog("[RONIN] LLM: none (transcription-only)")
            } else {
                updateDependency(.llmProvider(.failed(llm.detail ?? "Unreachable"), detail: provider))
                appendLog("[RONIN] LLM: \(llm.status) — \(llm.detail ?? "")")
            }
        } else {
            updateDependency(.llmProvider(.skipped("Not reported"), detail: ""))
        }
    }

    // MARK: - Microphone Permission

    /// Check current microphone authorization without prompting.
    /// .notDetermined is treated as "skipped" — the OS will prompt when the meeting starts.
    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            updateDependency(.microphoneAccess(.passed))
            appendLog("[RONIN] Microphone: authorized")
        case .notDetermined:
            updateDependency(.microphoneAccess(.skipped("Will request when meeting starts")))
            appendLog("[RONIN] Microphone: not yet requested")
        case .denied:
            updateDependency(.microphoneAccess(.failed("Denied — enable in System Settings > Privacy > Microphone")))
            appendLog("[RONIN] Microphone: denied")
        case .restricted:
            updateDependency(.microphoneAccess(.failed("Restricted by system policy")))
            appendLog("[RONIN] Microphone: restricted")
        @unknown default:
            updateDependency(.microphoneAccess(.skipped("Unknown status")))
        }
    }

    // MARK: - Dependency Helpers

    /// Update a single dependency in the array by matching on its `id`.
    private func updateDependency(_ dep: DependencyCheck) {
        if let idx = dependencies.firstIndex(where: { $0.id == dep.id }) {
            dependencies[idx] = dep
        }
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
        return "/Users/matthewjohnson/Projects/RONIN"
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
