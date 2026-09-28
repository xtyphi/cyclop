import AppKit

/// Work sprints with a break after each one.
///
/// Fixed breaks rather than breaks taken when tired: people who decide for
/// themselves when to stop work longer, stop less, and end up more fatigued
/// and less focused for the same output (Biwer et al., 2023). The lengths are
/// the user's to pick — the popular 90-minute figure has no biological rhythm
/// behind it in waking work, so it is a preset, not a rule.
///
/// Time is kept as a moment on the clock, not as a counter being decremented:
/// a counter stops when the Mac sleeps or the app restarts, and a sprint does
/// not. Everything needed to pick up where it was is written down on every
/// change.
@MainActor
final class FocusTimer: ObservableObject {
    struct Preset: Equatable {
        var work: Int
        var rest: Int
        var label: String { "\(work)/\(rest)" }
    }

    static let presets = [
        Preset(work: 90, rest: 30),
        Preset(work: 60, rest: 20),
        Preset(work: 30, rest: 15),
    ]

    enum Phase: String {
        /// Waiting for a click. Also where a break lands when it ends: the
        /// next sprint is the user's decision, not the timer's.
        case idle
        case work
        case rest
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var presetIndex = 0
    /// When the running phase ends. Nil while idle or paused.
    @Published private(set) var endsAt: Date?
    /// What was left when paused. Nil unless paused.
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var completedToday = 0
    /// Clock for the pane, advanced only while the pane is on screen.
    @Published private(set) var now = Date()

    var preset: Preset { Self.presets[presetIndex] }
    var isPaused: Bool { pausedRemaining != nil }

    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endsAt else { return phaseLength(.work) }
        return max(endsAt.timeIntervalSince(now), 0)
    }

    /// 0 at the start of the phase, 1 at its end.
    var progress: Double {
        guard phase != .idle else { return 0 }
        let total = phaseLength(phase)
        guard total > 0 else { return 0 }
        return min(max(1 - remaining / total, 0), 1)
    }

    private var deadline: Timer?
    private var ticker: Timer?
    private var countedDay = ""

    // MARK: - Lifecycle

    func start() {
        restore()
        catchUp()
        scheduleDeadline()
    }

    /// The tab left the rail. The state stays written down, so bringing the
    /// tab back resumes where it stood; only the alarms stop.
    func stop() {
        deadline?.invalidate()
        deadline = nil
        setActive(false)
    }

    /// The pane's own clock. The phase change does not depend on it — that
    /// has its own one-shot timer — so a closed panel costs one wake-up per
    /// phase, not one a second.
    func setActive(_ active: Bool) {
        ticker?.invalidate()
        ticker = nil
        now = Date()
        guard active else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: - Controls

    func begin() {
        enter(.work, length: phaseLength(.work))
    }

    func pause() {
        guard phase != .idle, let endsAt else { return }
        pausedRemaining = max(endsAt.timeIntervalSinceNow, 0)
        self.endsAt = nil
        scheduleDeadline()
        save()
    }

    func resume() {
        guard let pausedRemaining else { return }
        self.pausedRemaining = nil
        endsAt = Date().addingTimeInterval(pausedRemaining)
        now = Date()
        scheduleDeadline()
        save()
    }

    /// Ends the running phase now, as if its time had run out — a sprint
    /// finished early still counts, and still earns its break.
    func skip() {
        guard phase != .idle else { return }
        finishPhase(at: Date(), announce: false)
    }

    /// Back to idle without counting anything.
    func reset() {
        phase = .idle
        endsAt = nil
        pausedRemaining = nil
        scheduleDeadline()
        save()
    }

    /// Changing the length mid-sprint would either stretch a sprint already
    /// judged against its old end or cut it short, so it is only offered at
    /// rest.
    func selectPreset(_ index: Int) {
        guard phase == .idle, Self.presets.indices.contains(index) else { return }
        presetIndex = index
        save()
    }

    // MARK: - Phases

    private func phaseLength(_ phase: Phase) -> TimeInterval {
        switch phase {
        case .work, .idle: return TimeInterval(preset.work * 60)
        case .rest: return TimeInterval(preset.rest * 60)
        }
    }

    private func enter(_ next: Phase, length: TimeInterval, from start: Date = Date()) {
        phase = next
        pausedRemaining = nil
        endsAt = next == .idle ? nil : start.addingTimeInterval(length)
        now = Date()
        scheduleDeadline()
        save()
    }

    /// Work ends in a break at once: the break is the point, and asking for
    /// a click first would be asking the tired person to decide to stop. A
    /// break ends in waiting instead — the next sprint starts when the user
    /// sits back down, not when the clock says so.
    private func finishPhase(at moment: Date, announce: Bool) {
        switch phase {
        case .work:
            countSprint(finishedAt: moment)
            enter(.rest, length: phaseLength(.rest), from: moment)
            if announce { NSSound(named: "Glass")?.play() }
        case .rest:
            enter(.idle, length: 0)
            if announce { NSSound(named: "Hero")?.play() }
        case .idle:
            break
        }
    }

    private func scheduleDeadline() {
        deadline?.invalidate()
        deadline = nil
        guard phase != .idle, let endsAt else { return }
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deadlineReached() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        deadline = timer
    }

    private func deadlineReached() {
        guard let endsAt, endsAt <= Date().addingTimeInterval(0.5) else {
            // Fired early — tolerance, or a clock change. Aim again.
            scheduleDeadline()
            return
        }
        finishPhase(at: endsAt, announce: true)
    }

    /// Whatever ran out while the app was not running — quit, crashed, or the
    /// Mac asleep with the timer suspended — is settled without a sound: a
    /// chime for a sprint that ended an hour ago only confuses.
    private func catchUp() {
        while phase != .idle, let endsAt, endsAt <= Date() {
            finishPhase(at: endsAt, announce: false)
        }
    }

    // MARK: - Today

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func countSprint(finishedAt moment: Date) {
        let day = Self.dayKey(moment)
        if day != countedDay {
            countedDay = day
            completedToday = 0
        }
        completedToday += 1
    }

    /// Yesterday's count is not today's. Checked when the pane is looked at,
    /// which is the only time the number is read.
    func refreshDay() {
        let today = Self.dayKey(Date())
        guard today != countedDay else { return }
        countedDay = today
        completedToday = 0
        save()
    }

    // MARK: - Persistence

    private static let key = "focusTimer"

    private func save() {
        var record: [String: Any] = [
            "phase": phase.rawValue,
            "preset": presetIndex,
            "completed": completedToday,
            "day": countedDay,
        ]
        if let endsAt { record["endsAt"] = endsAt.timeIntervalSince1970 }
        if let pausedRemaining { record["paused"] = pausedRemaining }
        UserDefaults.standard.set(record, forKey: Self.key)
    }

    private func restore() {
        guard let record = UserDefaults.standard.dictionary(forKey: Self.key) else { return }
        if let index = record["preset"] as? Int, Self.presets.indices.contains(index) {
            presetIndex = index
        }
        countedDay = record["day"] as? String ?? ""
        completedToday = record["completed"] as? Int ?? 0
        let restored = (record["phase"] as? String).flatMap(Phase.init(rawValue:)) ?? .idle
        let end = (record["endsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let paused = record["paused"] as? Double
        // A running phase needs exactly one of the two. A record with neither
        // is damaged, and idle is the only state that cannot mislead.
        if restored != .idle, end != nil || paused != nil {
            phase = restored
            endsAt = paused == nil ? end : nil
            pausedRemaining = paused
        } else {
            phase = .idle
        }
        now = Date()
        refreshDay()
    }
}
