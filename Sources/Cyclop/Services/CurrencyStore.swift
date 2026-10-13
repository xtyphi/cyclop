import AppKit
import Foundation

/// Live exchange rates from [fawazahmed0/exchange-api](https://github.com/fawazahmed0/exchange-api).
///
/// The CDN is the primary host; Cloudflare Pages is the documented fallback.
/// Rates land once a day upstream, so this store refreshes every few hours and
/// again whenever the source currency changes — that is the base the API
/// returns rates against.
@MainActor
final class CurrencyStore: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
        var displayCode: String { code.uppercased() }
    }

    /// Which amount field last drove the pair — typing on one side must not
    /// bounce back through the other and fight the caret.
    enum Side { case source, target }

    @Published private(set) var currencies: [Currency] = []
    /// Rates for `rateBase`, keyed by lowercase code: one unit of the base
    /// buys this many of the key.
    @Published private(set) var rates: [String: Double] = [:]
    @Published private(set) var rateBase = ""
    @Published private(set) var rateDate: String?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    @Published var sourceCode: String {
        didSet {
            guard sourceCode != oldValue else { return }
            persistPair()
            Task { await refreshRates(force: true) }
            if !suppressSideEffects { recompute(from: .source) }
        }
    }

    @Published var targetCode: String {
        didSet {
            guard targetCode != oldValue else { return }
            persistPair()
            if !suppressSideEffects { recompute(from: .source) }
        }
    }

    @Published var sourceText = "1"
    @Published var targetText = ""

    private var timer: Timer?
    private var editing: Side = .source
    /// Quiet while both ends of a swap are rewritten, so the intermediate
    /// equal-codes moment never fires a convert against the wrong rate table.
    private var suppressSideEffects = false
    private let refreshInterval: TimeInterval = 60 * 60
    private let defaults = UserDefaults.standard
    private let sourceKey = "currency.source"
    private let targetKey = "currency.target"
    /// Own session rather than `URLSession.shared`: jsDelivr sends
    /// `max-age=604800` on these files, and the shared cache would keep
    /// serving yesterday's rates for a week no matter how often we "refresh".
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static let primaryHost = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1"
    private static let fallbackHost = "https://latest.currency-api.pages.dev/v1"

    init() {
        let savedSource = defaults.string(forKey: sourceKey)?.lowercased()
        let savedTarget = defaults.string(forKey: targetKey)?.lowercased()
        sourceCode = savedSource ?? Self.defaultSource
        targetCode = savedTarget ?? Self.defaultTarget
        if sourceCode == targetCode {
            targetCode = sourceCode == "usd" ? "eur" : "usd"
        }
    }

    /// USD out, and the Mac's own currency in — or RUB when the locale has no
    /// currency of its own worth converting against.
    private static var defaultSource: String { "usd" }
    private static var defaultTarget: String {
        let code = Locale.current.currency?.identifier.lowercased()
        if let code, code != "usd", !code.isEmpty { return code }
        return "rub"
    }

    // MARK: - Lifecycle

    func start() {
        Task { await bootstrap() }
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRates(force: true) }
        }
        // Common Mode, not just the default one: while a tracking loop or a
        // scroll is running the default mode pauses, and a currency refresh
        // queued for "in an hour" would quietly slip past.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Opening the tab always asks the network again. Skipping when a table is
    /// already in memory is what made yesterday's rates look permanent: the
    /// timer alone is not enough if the app was quit overnight.
    func refreshIfNeeded() {
        Task { await refreshRates(force: true) }
    }

    // MARK: - Amounts

    func setSourceText(_ text: String) {
        editing = .source
        sourceText = text
        recompute(from: .source)
    }

    func setTargetText(_ text: String) {
        editing = .target
        targetText = text
        recompute(from: .target)
    }

    func swap() {
        let previousSource = sourceCode
        let previousSourceText = sourceText
        suppressSideEffects = true
        sourceCode = targetCode
        targetCode = previousSource
        suppressSideEffects = false
        // Keep the figure that was typed; the other side follows once rates
        // for the new source land. If they are already cached, recompute now.
        sourceText = previousSourceText
        editing = .source
        if rateBase == sourceCode {
            recompute(from: .source)
        }
    }

    func filtered(query: String) -> [Currency] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return currencies }
        return currencies.filter {
            $0.code.contains(q) || $0.name.lowercased().contains(q)
        }
    }

    func name(for code: String) -> String {
        currencies.first { $0.code == code }?.name ?? code.uppercased()
    }

    // MARK: - Networking

    private func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await loadCurrencies()
            try await loadRates(for: sourceCode)
            failure = nil
            recompute(from: editing)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refreshRates(force: Bool) async {
        if !force, rateBase == sourceCode, !rates.isEmpty, !isStaleDate { return }
        do {
            if currencies.isEmpty { try await loadCurrencies() }
            try await loadRates(for: sourceCode)
            failure = nil
            recompute(from: editing)
        } catch {
            // Keep whatever rates we already have; only surface the error when
            // there is nothing to convert with.
            if rates.isEmpty { failure = error.localizedDescription }
        }
    }

    /// Upstream publishes once a day. A table whose `date` is not today is the
    /// one case where skipping a refresh is definitely wrong.
    private var isStaleDate: Bool {
        guard let rateDate else { return true }
        return rateDate != Self.todayStamp()
    }

    private static func todayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func loadCurrencies() async throws {
        let data = try await fetch("currencies.min.json")
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        currencies = decoded
            .map { Currency(code: $0.key.lowercased(), name: $0.value.isEmpty ? $0.key.uppercased() : $0.value) }
            .sorted {
                if $0.code == $1.code { return false }
                // Everyday fiat first, then the long tail alphabetically.
                let a = Self.pinboard.contains($0.code)
                let b = Self.pinboard.contains($1.code)
                if a != b { return a && !b }
                if a, b {
                    return Self.pinboard.firstIndex(of: $0.code)! < Self.pinboard.firstIndex(of: $1.code)!
                }
                return $0.code < $1.code
            }
        if !currencies.contains(where: { $0.code == sourceCode }) {
            sourceCode = currencies.first?.code ?? "usd"
        }
        if !currencies.contains(where: { $0.code == targetCode }) {
            targetCode = currencies.first { $0.code != sourceCode }?.code ?? "eur"
        }
    }

    /// Both hosts are asked unless the first already has today's table, and
    /// the newer of the two wins. jsDelivr caches `@latest` for up to twelve
    /// hours, so for most of a morning it hands out yesterday's file while
    /// the Pages mirror already has today's: taking the first answer that
    /// arrived is what left the header stuck a day behind.
    private func loadRates(for base: String) async throws {
        let code = base.lowercased()
        var best: (date: String?, table: [String: Double])?
        var lastError: Error?
        for host in [Self.primaryHost, Self.fallbackHost] {
            do {
                let data = try await fetch("currencies/\(code).min.json", from: host)
                let parsed = try Self.parseRates(data, base: code)
                if best == nil || (parsed.date ?? "") > (best?.date ?? "") { best = parsed }
                if parsed.date == Self.todayStamp() { break }
            } catch {
                lastError = error
            }
        }
        guard let best else { throw lastError ?? URLError(.cannotConnectToHost) }
        // The source was changed while this was in flight: a newer request
        // for the new one is on its way, and this table belongs to nobody.
        guard code == sourceCode.lowercased() else { return }
        rates = best.table
        rateBase = code
        rateDate = best.date
    }

    private static func parseRates(_ data: Data, base code: String) throws -> (date: String?, table: [String: Double]) {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let date = object?["date"] as? String
        let table = object?[code] as? [String: Any] ?? [:]
        var parsed: [String: Double] = [code: 1]
        for (key, value) in table {
            if let number = value as? Double {
                parsed[key.lowercased()] = number
            } else if let number = value as? NSNumber {
                parsed[key.lowercased()] = number.doubleValue
            }
        }
        // A file without its own table converts nothing. Refused here, so a
        // newer date on an empty answer cannot push out a usable table.
        guard parsed.count > 1 else { throw URLError(.cannotParseResponse) }
        return (date, parsed)
    }

    /// Tries the jsDelivr CDN first, then the Cloudflare Pages mirror the
    /// upstream README asks every client to keep as a fallback.
    private func fetch(_ endpoint: String) async throws -> Data {
        var lastError: Error?
        for host in [Self.primaryHost, Self.fallbackHost] {
            do {
                return try await fetch(endpoint, from: host)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func fetch(_ endpoint: String, from host: String) async throws -> Data {
        guard let url = URL(string: "\(host)/\(endpoint)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Conversion

    private func recompute(from side: Side) {
        // Rates belong to a specific base. Stale tables from the previous
        // source must not invent a conversion.
        guard rateBase == sourceCode.lowercased(),
              let rate = rates[targetCode.lowercased()], rate > 0 else {
            return
        }
        switch side {
        case .source:
            let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                targetText = ""
                return
            }
            guard let amount = Self.parse(sourceText) else { return }
            targetText = Self.format(amount * rate)
        case .target:
            let trimmed = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                sourceText = ""
                return
            }
            guard let amount = Self.parse(targetText) else { return }
            sourceText = Self.format(amount / rate)
        }
    }

    private func persistPair() {
        defaults.set(sourceCode, forKey: sourceKey)
        defaults.set(targetCode, forKey: targetKey)
    }

    /// Currencies people actually reach for, pinned to the top of the picker.
    private static let pinboard: [String] = [
        "usd", "eur", "rub", "gbp", "cny", "jpy", "chf", "try", "kzt", "uah",
        "byn", "pln", "aed", "btc", "eth", "usdt",
    ]

    /// Accepts both "1 234,56" and "1234.56". Empty and lone separators are
    /// not numbers — the other field stays put so a mid-edit "1." does not
    /// wipe the result.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains(","), normalized.contains(".") {
            // "1,234.56" vs "1.234,56" — the rightmost separator is decimal.
            if let lastComma = normalized.lastIndex(of: ","),
               let lastDot = normalized.lastIndex(of: ".") {
                if lastComma > lastDot {
                    normalized = normalized.replacingOccurrences(of: ".", with: "")
                    normalized = normalized.replacingOccurrences(of: ",", with: ".")
                } else {
                    normalized = normalized.replacingOccurrences(of: ",", with: "")
                }
            }
        } else {
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// Compact enough for the panel: whole numbers stay whole, fiat keeps a
    /// couple of decimals, tiny crypto rates keep more.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let abs = abs(value)
        let fraction: Int
        if abs >= 1000 { fraction = 2 }
        else if abs >= 1 { fraction = 2 }
        else if abs >= 0.01 { fraction = 4 }
        else if abs >= 0.0001 { fraction = 6 }
        else { fraction = 8 }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fraction
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
