import Foundation

/// What is left of the Claude and Codex subscription limits.
///
/// Both come through the vendors' own clients, never through a login token
/// lifted out of them: Anthropic's terms keep subscription credentials to
/// Claude Code and claude.ai, and a usage tracker reading them is the grey
/// zone this tab stays out of.
///
/// - Claude: Claude Code hands its status line the current `rate_limits` on
///   every update; `Scripts/claude-statusline.sh` writes them to
///   `claude-limits.json` here. The numbers are as fresh as the last Claude
///   Code session.
/// - Codex: `codex app-server` answers `account/rateLimits/read` over JSON-RPC
///   on stdin/stdout — the same call Codex's own `/status` makes.
///
/// Nothing runs while the tab is not on screen: the store refreshes when the
/// tab is opened and once a minute while it stays open.
@MainActor
final class LimitsStore: ObservableObject {
    struct Window: Equatable {
        let usedPercent: Double
        let resetsAt: Date?

        var remainingPercent: Int { Int((100 - usedPercent).rounded()).clamped(0, 100) }

        /// A window whose reset time has passed is full again, whatever the
        /// last snapshot said.
        func current(at now: Date) -> Window {
            guard let resetsAt, resetsAt <= now else { return self }
            return Window(usedPercent: 0, resetsAt: nil)
        }
    }

    struct Snapshot: Equatable {
        var session: Window?
        var week: Window?
        var plan: String?
        var updatedAt: Date?
        var failure: String?
    }

    @Published private(set) var claude = Snapshot()
    @Published private(set) var codex = Snapshot()
    @Published private(set) var isLoadingCodex = false
    @Published private(set) var now = Date()

    static let claudeFileName = "claude-limits.json"

    private var enabled = false
    private var active = false
    private var timer: Timer?
    private var codexProcess: Process?
    private var codexBuffer = Data()
    private var codexFetchedAt: Date?

    private let refreshInterval: TimeInterval = 60
    private let codexTimeout: Duration = .seconds(20)

    func start() { enabled = true }

    func stop() {
        enabled = false
        setActive(false)
        finishCodex(nil)
    }

    /// True while the tab is on screen in an open panel.
    func setActive(_ value: Bool) {
        let value = value && enabled
        guard value != active else { return }
        active = value
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh(force: Bool = false) {
        now = Date()
        readClaude()
        let stale = codexFetchedAt.map { now.timeIntervalSince($0) >= refreshInterval - 1 } ?? true
        if force || stale { fetchCodex() }
    }

    // MARK: - Claude

    private func readClaude() {
        let url = Support.file(Self.claudeFileName)
        guard let data = try? Data(contentsOf: url) else {
            claude = Snapshot(failure: localized("Appears after a reply in Claude Code"))
            return
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            claude = Snapshot(failure: localized("Could not read the limits file"))
            return
        }
        let limits = root["rate_limits"] as? [String: Any] ?? [:]
        func window(_ key: String) -> Window? {
            guard let item = limits[key] as? [String: Any],
                  let used = (item["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            let reset = (item["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Window(usedPercent: used, resetsAt: reset)
        }
        let updated = (root["updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        claude = Snapshot(session: window("five_hour"), week: window("seven_day"), updatedAt: updated)
    }

    // MARK: - Codex

    /// Where Homebrew and npm put it. A GUI app starts with a bare PATH, so
    /// `/usr/bin/env codex` would find nothing.
    private static let codexCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
    }()

    private func fetchCodex() {
        guard codexProcess == nil else { return }
        guard let path = Self.codexCandidates.first(where: FileManager.default.isExecutableFile) else {
            codex = Snapshot(failure: localized("Codex CLI not found"))
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = environment["PATH"].map { "\(extra):\($0)" } ?? extra
        task.environment = environment

        let output = Pipe()
        let input = Pipe()
        task.standardOutput = output
        task.standardInput = input
        task.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // At end of file the handler keeps firing with empty data until it
            // is removed — hundreds of thousands of times a second.
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.consumeCodex(chunk) }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.codexProcess === task else { return }
                self.finishCodex(localized("Codex did not answer"))
            }
        }

        do {
            try task.run()
        } catch {
            codex.failure = localized("Codex did not answer")
            return
        }
        codexProcess = task
        codexBuffer = Data()
        isLoadingCodex = true

        // Stdin stays open: closing it tells the server to quit before it has
        // answered. The process is terminated once the reply is in.
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"cyclop","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
        ]
        // The throwing variant: a server that quit during start-up would make
        // the old `write(_:)` raise an exception and take the app down with it.
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
        } catch {
            finishCodex(localized("Codex did not answer"))
            return
        }

        Task { [weak self, codexTimeout] in
            try? await Task.sleep(for: codexTimeout)
            guard let self, self.codexProcess === task else { return }
            self.finishCodex(localized("Codex did not answer"))
        }
    }

    private func consumeCodex(_ chunk: Data) {
        guard codexProcess != nil else { return }
        codexBuffer.append(chunk)
        while let newline = codexBuffer.firstIndex(of: 0x0A) {
            let line = codexBuffer[codexBuffer.startIndex..<newline]
            codexBuffer.removeSubrange(codexBuffer.startIndex...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (message["id"] as? NSNumber)?.intValue == 2
            else { continue }

            if let error = message["error"] as? [String: Any] {
                finishCodex(error["message"] as? String ?? localized("Codex did not answer"))
                return
            }
            let result = message["result"] as? [String: Any] ?? [:]
            let limits = result["rateLimits"] as? [String: Any] ?? [:]
            func window(_ key: String) -> Window? {
                guard let item = limits[key] as? [String: Any],
                      let used = (item["usedPercent"] as? NSNumber)?.doubleValue
                else { return nil }
                let reset = (item["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return Window(usedPercent: used, resetsAt: reset)
            }
            codex = Snapshot(
                session: window("primary"),
                week: window("secondary"),
                plan: (limits["planType"] as? String)?.capitalized,
                updatedAt: Date()
            )
            codexFetchedAt = Date()
            finishCodex(nil)
            return
        }
    }

    /// Ends the running request. A failure keeps the last good numbers on
    /// screen and only adds the message.
    private func finishCodex(_ failure: String?) {
        guard let task = codexProcess else { return }
        codexProcess = nil
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if task.isRunning { task.terminate() }
        isLoadingCodex = false
        if let failure {
            codex.failure = failure
            codexFetchedAt = Date()
        }
    }
}

private extension Int {
    func clamped(_ lower: Int, _ upper: Int) -> Int { Swift.min(Swift.max(self, lower), upper) }
}
