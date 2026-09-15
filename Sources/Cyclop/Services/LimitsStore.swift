import Foundation

/// What is left of the Claude and Codex subscription limits.
///
/// - Claude: `GET api.anthropic.com/api/oauth/usage`, the endpoint behind
///   Claude Code's `/usage`, authorised with the token Claude Code keeps in the
///   Keychain. Undocumented, and the one grey-zone read in the app — so it is
///   kept as quiet as it can be: only while the tab is open, at most once every
///   five minutes, backing off on 429. The token is only ever read, never
///   refreshed: refresh tokens are single-use, and rotating one here would sign
///   Claude Code out. An expired token waits for Claude Code to renew it.
///   The status line file (`Scripts/claude-statusline.sh`) stays as a second
///   source for when the endpoint is unavailable; the newer of the two wins.
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

    /// The two Claude sources, kept apart and combined into `claude`.
    private var claudeFromAPI = Snapshot()
    private var claudeFromFile = Snapshot()
    private var claudeLoading = false
    private var claudeNextAttempt = Date.distantPast
    private var claudeBackoff: TimeInterval = 0

    private let refreshInterval: TimeInterval = 60
    private let claudeInterval: TimeInterval = 5 * 60
    private let codexTimeout: Duration = .seconds(20)

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

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
        readClaudeFile()
        if now >= claudeNextAttempt { fetchClaude() }
        let stale = codexFetchedAt.map { now.timeIntervalSince($0) >= refreshInterval - 1 } ?? true
        if force || stale { fetchCodex() }
    }

    // MARK: - Claude

    /// The newer source with numbers in it; a failure from the endpoint rides
    /// along so a stale figure is not mistaken for a live one.
    private func publishClaude() {
        let candidates = [claudeFromAPI, claudeFromFile].filter { $0.session != nil || $0.week != nil }
        if var best = candidates.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) {
            best.failure = claudeFromAPI.failure
            claude = best
        } else {
            claude = Snapshot(
                failure: claudeFromAPI.failure
                    ?? (claudeLoading ? nil : localized("Appears after a reply in Claude Code"))
            )
        }
    }

    private func readClaudeFile() {
        defer { publishClaude() }
        let url = Support.file(Self.claudeFileName)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            claudeFromFile = Snapshot()
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
        claudeFromFile = Snapshot(session: window("five_hour"), week: window("seven_day"), updatedAt: updated)
    }

    private enum ClaudeResult: Sendable {
        case data(Data)
        case signedOut
        case rateLimited(retryAfter: TimeInterval?)
        case failed
    }

    private func fetchClaude() {
        guard !claudeLoading else { return }
        claudeLoading = true
        claudeNextAttempt = Date().addingTimeInterval(claudeInterval)
        // The file was published a moment ago with loading still false; say
        // again, so "appears after a reply" does not stand in for a request
        // that is already on its way.
        publishClaude()
        Task { [session] in
            let result = await Self.requestClaudeUsage(session: session)
            self.claudeLoading = false
            self.handleClaude(result)
        }
    }

    private func handleClaude(_ result: ClaudeResult) {
        switch result {
        case .data(let data):
            if let snapshot = Self.parseClaudeUsage(data) {
                claudeFromAPI = snapshot
                claudeBackoff = 0
            } else {
                claudeFromAPI.failure = localized("Unexpected answer from Claude")
            }
        case .signedOut:
            claudeFromAPI.failure = localized("Open Claude Code to renew sign-in")
        case .rateLimited(let retryAfter):
            claudeBackoff = min(max(claudeBackoff * 2, claudeInterval), 30 * 60)
            let wait = max(retryAfter ?? 0, claudeBackoff)
            claudeNextAttempt = Date().addingTimeInterval(wait)
            claudeFromAPI.failure = localized("Claude asked to wait, retrying later")
        case .failed:
            claudeFromAPI.failure = localized("Claude did not answer")
        }
        publishClaude()
    }

    /// Off the main actor: `security` and the request both block for a while.
    /// The token lives only inside this function.
    private nonisolated static func requestClaudeUsage(session: URLSession) async -> ClaudeResult {
        let token: String
        switch await readClaudeToken() {
        case .token(let value): token = value
        case .missing: return .signedOut
        case .unavailable: return .failed
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Cyclop", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed }
        switch http.statusCode {
        case 200: return .data(data)
        case 401, 403: return .signedOut
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        default: return .failed
        }
    }

    /// A token missing or about to expire is `.missing` — Claude Code will put
    /// a fresh one there. A keychain that did not answer is `.unavailable`.
    private enum TokenRead: Sendable {
        case token(String)
        case missing
        case unavailable
    }

    /// Through `/usr/bin/security` rather than `SecItemCopyMatching`: Claude
    /// Code stores the item with that tool, so the tool is already on its access
    /// list and no dialog appears — while Cyclop itself, re-signed ad hoc on
    /// every build, would be asked about again after each one.
    ///
    private nonisolated static func readClaudeToken() async -> TokenRead {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .unavailable }
        // A locked keychain puts up an unlock dialog and `security` waits on it
        // for as long as it stays open. Without a deadline the read below would
        // never return, and the Claude column would stop updating for good.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if task.isRunning { task.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        // 44 is errSecItemNotFound: Claude Code has never signed in here.
        if task.terminationReason == .exit, task.terminationStatus == 44 { return .missing }
        guard task.terminationReason == .exit, task.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unavailable }
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .missing }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expires / 1000) < Date().addingTimeInterval(60) {
            return .missing
        }
        return .token(token)
    }

    /// Reads the `limits` list when present — the newer shape — and the flat
    /// `five_hour` / `seven_day` objects otherwise.
    private static func parseClaudeUsage(_ data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var session: Window?
        var week: Window?
        if let limits = root["limits"] as? [[String: Any]] {
            for item in limits {
                guard let percent = (item["percent"] as? NSNumber)?.doubleValue else { continue }
                let window = Window(usedPercent: percent, resetsAt: date(item["resets_at"]))
                switch item["kind"] as? String {
                case "session": session = window
                case "weekly_all": week = window
                default: break
                }
            }
        }
        func flat(_ key: String) -> Window? {
            guard let item = root[key] as? [String: Any],
                  let used = (item["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(usedPercent: used, resetsAt: date(item["resets_at"]))
        }
        session = session ?? flat("five_hour")
        week = week ?? flat("seven_day")
        guard session != nil || week != nil else { return nil }
        return Snapshot(session: session, week: week, updatedAt: Date())
    }

    /// ISO 8601 with microseconds, which `ISO8601DateFormatter` will not take:
    /// the fraction is dropped, a second is precise enough for a countdown.
    private static func date(_ value: Any?) -> Date? {
        guard var text = value as? String else { return nil }
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text.removeSubrange(dot..<zone)
        }
        return ISO8601DateFormatter().date(from: text)
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
