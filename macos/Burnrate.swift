import AppKit
import Foundation

// MARK: - Konfiguration (aus Umgebungsvariablen, siehe config.env)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("burnrate: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

struct Config {
    let refreshSeconds: TimeInterval
    let burnMinutes: Double
    let claudeURL: URL
    let claudeBetaHeader: String
    let claudeKeychainService: String
    let claudeProjectsDir: URL
    let codexURL: URL
    let codexAuthFile: String
    let codexSessionsDir: URL

    static func fromEnvironment() -> Config {
        let env = ProcessInfo.processInfo.environment
        func required(_ key: String) -> String {
            guard let value = env[key], !value.isEmpty else {
                fail("Umgebungsvariable \(key) fehlt (siehe config.env)")
            }
            return value
        }
        func url(_ key: String) -> URL {
            guard let url = URL(string: required(key)) else { fail("\(key) ist keine gültige URL") }
            return url
        }
        func number(_ key: String, min: Double) -> Double {
            guard let value = Double(required(key)), value >= min else { fail("\(key) muss eine Zahl >= \(Int(min)) sein") }
            return value
        }
        return Config(
            refreshSeconds: number("CLAUDE_USAGE_REFRESH_SECONDS", min: 30),
            burnMinutes: number("CLAUDE_USAGE_BURN_MINUTES", min: 5),
            claudeURL: url("CLAUDE_USAGE_URL"),
            claudeBetaHeader: required("CLAUDE_USAGE_BETA_HEADER"),
            claudeKeychainService: required("CLAUDE_USAGE_KEYCHAIN_SERVICE"),
            claudeProjectsDir: URL(fileURLWithPath: required("CLAUDE_PROJECTS_DIR")),
            codexURL: url("CODEX_USAGE_URL"),
            codexAuthFile: required("CODEX_AUTH_FILE"),
            codexSessionsDir: URL(fileURLWithPath: required("CODEX_SESSIONS_DIR"))
        )
    }
}

// MARK: - Sprache (Deutsch bei deutscher Systemsprache, sonst Englisch)

let german = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
let uiLocale = Locale(identifier: german ? "de_DE" : "en_US")

func t(_ de: String, _ en: String) -> String { german ? de : en }

// MARK: - Daten vom Server

let hour: TimeInterval = 3600
let week: TimeInterval = 7 * 24 * hour

struct Limit {
    let title: String
    let percent: Double
    let severity: String
    let resetsAt: Date?
    let window: TimeInterval?
    /// Kurzform für die Mini-Ansicht, nil = dort nicht anzeigen
    var short: String? = nil
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func errorText(_ error: Error) -> String {
    (error as? UsageError)?.message ?? error.localizedDescription
}

func fetchJSON(_ request: URLRequest, tokenHint: String, completion: @escaping (Result<[String: Any], UsageError>) -> Void) {
    URLSession.shared.dataTask(with: request) { data, response, error in
        let result: Result<[String: Any], UsageError>
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error {
            result = .failure(UsageError(t("Netzwerk: ", "Network: ") + error.localizedDescription))
        } else if status == 401 || status == 403 {
            result = .failure(UsageError("HTTP \(status) – \(tokenHint)"))
        } else if status == 429 {
            result = .failure(UsageError(t("Rate-Limit (429) – später erneut", "Rate limited (429) – retrying later")))
        } else if status != 200 {
            result = .failure(UsageError("HTTP \(status)"))
        } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = .success(json)
        } else {
            result = .failure(UsageError(t("Antwort nicht lesbar", "Unreadable response")))
        }
        DispatchQueue.main.async { completion(result) }
    }.resume()
}

// Claude: OAuth-Token aus der Keychain (von Claude Code gepflegt)

func hasKeychainEntry(service: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func readClaudeCredentials(service: String) throws -> (token: String, plan: String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UsageError(t("Kein Keychain-Eintrag „\(service)“ – in Claude Code eingeloggt?", "No keychain entry \"\(service)\" – logged in to Claude Code?"))
    }
    guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let oauth = json["claudeAiOauth"] as? [String: Any],
        let token = oauth["accessToken"] as? String
    else {
        throw UsageError(t("Keychain-Eintrag hat unerwartetes Format", "Unexpected keychain entry format"))
    }
    if let expiresMs = oauth["expiresAt"] as? Double, Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
        throw UsageError(t("Token abgelaufen – Claude Code kurz starten", "Token expired – open Claude Code briefly"))
    }
    return (token, oauth["subscriptionType"] as? String)
}

func parseISODate(_ raw: String?) -> Date? {
    guard var s = raw else { return nil }
    // Mikrosekunden entfernen, ISO8601DateFormatter kann nur Millisekunden
    if let frac = s.range(of: #"\.\d+"#, options: .regularExpression) {
        s.removeSubrange(frac)
    }
    return ISO8601DateFormatter().date(from: s)
}

func parseClaudeLimit(_ limit: [String: Any]) -> Limit {
    let kind = limit["kind"] as? String ?? "?"
    let title: String
    let window: TimeInterval?
    var short: String? = nil
    switch kind {
    case "session":
        title = t("Aktuelle Session", "Current session")
        window = 5 * hour
        short = "5h"
    case "weekly_all":
        title = t("Aktuelle Woche · alle Modelle", "Current week · all models")
        window = week
        short = t("Wo", "wk")
    case "weekly_scoped":
        let scope = limit["scope"] as? [String: Any]
        let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
        let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
        title = t("Aktuelle Woche · ", "Current week · ") + (model ?? surface ?? t("eingeschränkt", "scoped"))
        window = week
        short = model ?? surface
    default:
        title = kind
        window = nil
    }
    return Limit(
        title: title,
        percent: (limit["percent"] as? NSNumber)?.doubleValue ?? 0,
        severity: limit["severity"] as? String ?? "normal",
        resetsAt: parseISODate(limit["resets_at"] as? String),
        window: window,
        short: short
    )
}

func parseClaudeLimits(_ json: [String: Any]) throws -> [Limit] {
    guard let limits = json["limits"] as? [[String: Any]] else {
        throw UsageError(t("Antwort ohne „limits“ – API geändert?", "Response without \"limits\" – API changed?"))
    }
    return limits.map(parseClaudeLimit)
}

func parseClaudeSurfaces(_ json: [String: Any]) -> [(String, Double)] {
    let rows = (json["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
    return rows.compactMap { row in
        guard let name = row["display_name"] as? String, let percent = (row["percent"] as? NSNumber)?.doubleValue, percent > 0 else { return nil }
        return (name, percent)
    }
}

// Codex: ChatGPT-Token aus der auth.json (von der Codex CLI gepflegt)

func readCodexCredentials(path: String) throws -> (token: String, accountId: String?) {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw UsageError(path + t(" fehlt – in Codex eingeloggt?", " missing – logged in to Codex?"))
    }
    guard
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = json["tokens"] as? [String: Any],
        let token = tokens["access_token"] as? String
    else {
        throw UsageError(t("auth.json ohne ChatGPT-Login (API-Key-Modus?)", "auth.json without ChatGPT login (API key mode?)"))
    }
    return (token, tokens["account_id"] as? String)
}

func codexTitle(windowSeconds: Double, prefix: String) -> String {
    let hours = Int(windowSeconds / hour)
    let span: String
    switch hours {
    case 168: span = t("Aktuelle Woche", "Current week")
    case ..<24: span = t("Aktuelle Session", "Current session") + " (\(hours) h)"
    default: span = "\(hours / 24) " + t("Tage", "days")
    }
    return prefix.isEmpty ? span : "\(span) · \(prefix)"
}

func codexShort(windowSeconds: Double) -> String {
    let hours = Int(windowSeconds / hour)
    return hours == 168 ? t("Wo", "wk") : hours < 24 ? "\(hours)h" : "\(hours / 24)" + t("T", "d")
}

func parseCodexWindows(_ rateLimit: [String: Any]?, prefix: String) -> [Limit] {
    guard let rateLimit else { return [] }
    let reached = rateLimit["limit_reached"] as? Bool ?? false
    return ["primary_window", "secondary_window"].compactMap { key in
        guard let w = rateLimit[key] as? [String: Any] else { return nil }
        let seconds = (w["limit_window_seconds"] as? NSNumber)?.doubleValue
        return Limit(
            title: codexTitle(windowSeconds: seconds ?? 0, prefix: prefix),
            percent: (w["used_percent"] as? NSNumber)?.doubleValue ?? 0,
            severity: reached ? "limit_reached" : "normal",
            resetsAt: (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            window: seconds,
            short: prefix.isEmpty ? codexShort(windowSeconds: seconds ?? 0) : nil
        )
    }
}

func parseCodexLimits(_ json: [String: Any]) throws -> [Limit] {
    guard json.keys.contains("rate_limit") else {
        throw UsageError(t("Antwort ohne „rate_limit“ – API geändert?", "Response without \"rate_limit\" – API changed?"))
    }
    return parseCodexWindows(json["rate_limit"] as? [String: Any], prefix: "")
        + parseCodexWindows(json["code_review_rate_limit"] as? [String: Any], prefix: "Code Review")
}

// MARK: - Tempo & Prognose

struct Pace {
    let perHour: Double
    let projected: Double
    let untilFull: TimeInterval?
}

/// Lineare Hochrechnung: bisheriger Verbrauch im Fenster, aufs ganze Fenster gestreckt.
func pace(of limit: Limit, now: Date) -> Pace? {
    guard let window = limit.window, let reset = limit.resetsAt, limit.percent > 0 else { return nil }
    let elapsed = window - reset.timeIntervalSince(now)
    guard elapsed > window * 0.03 else { return nil }  // zu früh im Fenster für eine Aussage
    let perHour = limit.percent / (elapsed / hour)
    let projected = limit.percent * window / elapsed
    let untilFull = projected >= 100 ? (100 - limit.percent) / perHour * hour : nil
    return Pace(perHour: perHour, projected: projected, untilFull: untilFull)
}

// MARK: - Lokale Logs (echte Token-Zahlen)

/// Kompakt gehalten (32 Byte), weil pro Woche zehntausende davon im Speicher liegen
struct TokenEvent {
    let time: TimeInterval  // seit 1970
    let model: UInt16       // Index in LogScanner.models
    let input: Int32
    let output: Int32
    let cacheRead: Int32
    let cacheWrite: Int32
    /// Tokens ohne Cache-Reads (die sind billig und würden alles überdecken)
    var tokens: Int { Int(input) + Int(output) + Int(cacheWrite) }
}

struct ScanResult {
    let events: [TokenEvent]
    let models: [String]
}

struct TokenTotals {
    var tokens = 0
    var output = 0
    var cacheRead = 0
    var requests = 0

    mutating func add(_ e: TokenEvent) {
        tokens += e.tokens
        output += Int(e.output)
        cacheRead += Int(e.cacheRead)
        requests += 1
    }
}

struct LocalStats {
    let burnPerMinute: Double
    let outputPerMinute: Double
    let last5h: TokenTotals
    let today: TokenTotals
    let week: TokenTotals
    let models: [(String, Int)]
    let buckets: [Int]

    static let bucketCount = 20
    static let bucketSeconds: TimeInterval = 15 * 60

    static func compute(_ scan: ScanResult, weekStart: Date, burnMinutes: Double, now: Date) -> LocalStats {
        let nowSeconds = now.timeIntervalSince1970
        let burnStart = nowSeconds - burnMinutes * 60
        let fiveHoursAgo = nowSeconds - 5 * hour
        let midnight = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let weekStart = weekStart.timeIntervalSince1970
        let bucketStart = nowSeconds - Double(bucketCount) * bucketSeconds
        var burn = TokenTotals(), last5h = TokenTotals(), today = TokenTotals(), weekTotals = TokenTotals()
        var models = [Int](repeating: 0, count: scan.models.count)
        var buckets = [Int](repeating: 0, count: bucketCount)

        for e in scan.events {
            if e.time >= burnStart { burn.add(e) }
            if e.time >= fiveHoursAgo { last5h.add(e) }
            if e.time >= midnight { today.add(e) }
            if e.time >= weekStart {
                weekTotals.add(e)
                models[Int(e.model)] += e.tokens
            }
            if e.time >= bucketStart {
                let index = min(bucketCount - 1, Int((e.time - bucketStart) / bucketSeconds))
                buckets[index] += e.tokens
            }
        }
        return LocalStats(
            burnPerMinute: Double(burn.tokens) / burnMinutes,
            outputPerMinute: Double(burn.output) / burnMinutes,
            last5h: last5h,
            today: today,
            week: weekTotals,
            models: zip(scan.models, models).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 },
            buckets: buckets
        )
    }
}

/// Byte-Suche direkt im Puffer (Data.range(of:) legt bei langen Zeilen temporäre Kopien an)
func find(_ needle: Data, in line: Data, last: Bool = false) -> Range<Data.Index>? {
    line.withUnsafeBytes { hay -> Range<Data.Index>? in
        needle.withUnsafeBytes { pattern -> Range<Data.Index>? in
            guard let hayBase = hay.baseAddress, let patternBase = pattern.baseAddress else { return nil }
            var found: Int?
            var from = 0
            while from <= hay.count - pattern.count,
                  let hit = memmem(hayBase + from, hay.count - from, patternBase, pattern.count) {
                found = hayBase.distance(to: UnsafeRawPointer(hit))
                guard last else { break }
                from = found! + 1
            }
            return found.map { line.startIndex + $0 ..< line.startIndex + $0 + needle.count }
        }
    }
}

/// Liest JSONL-Logs inkrementell: pro Datei wird nur gelesen, was seit dem letzten Lauf angehängt wurde.
final class LogScanner {
    enum Format { case claude, codex }

    let format: Format
    let root: URL
    let retention: TimeInterval = 8 * 24 * hour
    private var offsets: [String: UInt64] = [:]
    private var events: [Int: TokenEvent] = [:]  // Schlüssel: Hash der Message-ID (dedupliziert Wiederholungen)
    private var models: [String] = []
    private var modelIndex: [String: UInt16] = [:]
    private var codexModel: [String: String] = [:]
    private var lastScan: Date?
    private var buffer = [UInt8](repeating: 0, count: 1 << 20)
    private var pending = Data(capacity: 2 << 20)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let claudeNeedle = Data(#""type":"assistant""#.utf8)
    private static let tokenCountNeedle = Data(#""type":"token_count""#.utf8)
    private static let turnContextNeedle = Data(#""type":"turn_context""#.utf8)

    init(format: Format, root: URL) {
        self.format = format
        self.root = root
    }

    func scan() throws -> ScanResult {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError(root.path + t(" fehlt", " missing"))
        }
        let now = Date()
        let cutoff = now.addingTimeInterval(-retention)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard let mtime = try? url.resourceValues(forKeys: keys).contentModificationDate, mtime > cutoff else { continue }
                if let lastScan, mtime < lastScan.addingTimeInterval(-5) { continue }
                readAppended(url)
            }
        }
        let expiry = cutoff.timeIntervalSince1970
        for key in events.compactMap({ $0.value.time < expiry ? $0.key : nil }) {
            events.removeValue(forKey: key)
        }
        lastScan = now
        return ScanResult(events: Array(events.values), models: models)
    }

    private func readAppended(_ url: URL) {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var offset = offsets[path] ?? 0
        if let size = try? handle.seekToEnd(), size < offset { offset = 0 }  // Datei wurde neu geschrieben
        guard (try? handle.seek(toOffset: offset)) != nil else { return }

        // In 1-MB-Stücken lesen statt die ganze Datei (bis zu 35 MB) in den Speicher zu holen
        // Ein wiederverwendeter 1-MB-Puffer statt neuer Allokationen pro Stück
        let fd = handle.fileDescriptor
        pending.removeAll(keepingCapacity: true)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            pending.append(buffer, count: count)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            autoreleasepool {
                for line in pending[pending.startIndex..<lastNewline].split(separator: 0x0A) {
                    switch format {
                    case .claude: parseClaude(line)
                    case .codex: parseCodex(line, path: path)
                    }
                }
            }
            offset += UInt64(lastNewline - pending.startIndex + 1)
            pending.removeSubrange(pending.startIndex...lastNewline)  // angefangene Zeile bleibt fürs nächste Stück
        }
        offsets[path] = offset
        if pending.count > 4 << 20 { pending = Data(capacity: 2 << 20) }  // nach einer Riesenzeile nicht ewig festhalten
    }

    private func int(_ dict: [String: Any], _ key: String) -> Int32 {
        Int32(clamping: (dict[key] as? NSNumber)?.intValue ?? 0)
    }

    private func modelId(_ name: String) -> UInt16 {
        if let id = modelIndex[name] { return id }
        let id = UInt16(models.count)
        models.append(name)
        modelIndex[name] = id
        return id
    }

    /// Wert eines String-Felds direkt aus den Bytes, ohne die (oft riesige) Zeile komplett zu parsen
    private func stringField(_ key: Data, in line: Data, last: Bool = false) -> String? {
        guard
            let range = find(key, in: line, last: last),
            let end = line[range.upperBound...].firstIndex(of: 0x22)
        else { return nil }
        return String(decoding: line[range.upperBound..<end], as: UTF8.self)
    }

    /// Nur das JSON-Objekt hinter `key` parsen (Klammern zählen, Strings überspringen)
    private func objectField(_ key: Data, in line: Data) -> [String: Any]? {
        guard let range = find(key, in: line, last: true) else { return nil }
        let start = range.upperBound - 1  // öffnende Klammer gehört zum Suchmuster
        var depth = 0, inString = false, escaped = false
        var index = start
        while index < line.endIndex {
            let byte = line[index]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    return try? JSONSerialization.jsonObject(with: Data(line[start...index])) as? [String: Any]
                }
            }
            index += 1
        }
        return nil
    }

    private static let messageIdKey = Data(#""id":"msg_"#.utf8)
    private static let modelKey = Data(#""model":""#.utf8)
    private static let timestampKey = Data(#""timestamp":""#.utf8)
    private static let requestIdKey = Data(#""requestId":""#.utf8)
    private static let usageKey = Data(#""usage":{"#.utf8)

    private func parseClaude(_ line: Data) {
        // Struktur: {..., "message": {"model", "id", ..., "content": [...], "usage": {...}}, "requestId", ..., "timestamp"}
        guard
            find(Self.claudeNeedle, in: line) != nil,
            let id = stringField(Self.messageIdKey, in: line),
            let usage = objectField(Self.usageKey, in: line),
            let time = stringField(Self.timestampKey, in: line, last: true).flatMap(iso.date(from:))
        else { return }
        let model = stringField(Self.modelKey, in: line) ?? "?"
        guard model != "<synthetic>" else { return }
        // Claude Code schreibt pro Content-Block eine Zeile mit derselben Message-ID → letzte gewinnt
        events["\(id):\(stringField(Self.requestIdKey, in: line, last: true) ?? "")".hashValue] = TokenEvent(
            time: time.timeIntervalSince1970,
            model: modelId(model),
            input: int(usage, "input_tokens"),
            output: int(usage, "output_tokens"),
            cacheRead: int(usage, "cache_read_input_tokens"),
            cacheWrite: int(usage, "cache_creation_input_tokens")
        )
    }

    private func parseCodex(_ line: Data, path: String) {
        if find(Self.turnContextNeedle, in: line) != nil {
            if let model = stringField(Self.modelKey, in: line) {
                codexModel[path] = model
            }
            return
        }
        // token_count-Zeilen sind klein, die dürfen komplett geparst werden
        guard
            find(Self.tokenCountNeedle, in: line) != nil,
            let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let info = (json["payload"] as? [String: Any])?["info"] as? [String: Any],
            let last = info["last_token_usage"] as? [String: Any],
            let total = info["total_token_usage"] as? [String: Any],
            let time = (json["timestamp"] as? String).flatMap(iso.date(from:))
        else { return }
        // Codex wiederholt token_count-Events mit identischer Gesamtsumme → darüber deduplizieren
        let cached = int(last, "cached_input_tokens")
        events["\(path):\(int(total, "total_tokens"))".hashValue] = TokenEvent(
            time: time.timeIntervalSince1970,
            model: modelId(codexModel[path] ?? "codex"),
            input: max(0, int(last, "input_tokens") - cached),
            output: int(last, "output_tokens"),
            cacheRead: cached,
            cacheWrite: int(last, "cache_write_input_tokens")
        )
    }
}

// MARK: - Formatierung

func formatNumber(_ value: Double, digits: Int) -> String {
    let f = NumberFormatter()
    f.locale = uiLocale
    f.minimumFractionDigits = digits
    f.maximumFractionDigits = digits
    return f.string(from: NSNumber(value: value)) ?? "\(value)"
}

func formatTokens(_ n: Double) -> String {
    switch n {
    case 1_000_000...: return formatNumber(n / 1_000_000, digits: 1) + t(" Mio", " M")
    case 10_000...: return formatNumber(n / 1000, digits: 0) + " k"
    case 1000...: return formatNumber(n / 1000, digits: 1) + " k"
    default: return formatNumber(n, digits: 0)
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
    if days > 0 { return "\(days) " + t("T", "d") + " \(hours) h" }
    if hours > 0 { return "\(hours) h \(mins) min" }
    return "\(mins) min"
}

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let remaining = date.timeIntervalSinceNow
    if remaining <= 0 { return t("Reset fällig", "Reset due") }
    if remaining < 24 * hour { return "Reset in " + formatDuration(remaining) }
    let f = DateFormatter()
    f.locale = uiLocale
    f.dateFormat = german ? "EE, HH:mm" : "EEE HH:mm"
    return "Reset " + f.string(from: date)
}

func shortModel(_ model: String) -> String {
    let name = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    return name.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
}

// MARK: - UI-Bausteine

func color(forPercent percent: Double, severity: String = "normal") -> NSColor {
    if severity != "normal" || percent >= 90 { return .systemRed }
    if percent >= 70 { return .systemOrange }
    return .systemGreen
}

final class BarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var projected: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    private func fill(_ value: CGFloat, _ color: NSColor) {
        guard value > 0 else { return }
        var rect = bounds
        rect.size.width = max(bounds.height, bounds.width * min(1, value))
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(1, NSColor.white.withAlphaComponent(0.15))
        fill(projected, color.withAlphaComponent(0.3))  // Prognose bis Reset
        fill(fraction, color)
    }
}

final class SparklineView: NSView {
    var values: [Int] = [] { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let maxValue = CGFloat(values.max() ?? 0)
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
        for (i, value) in values.enumerated() {
            let height = maxValue > 0 ? max(1, bounds.height * CGFloat(value) / maxValue) : 1
            let rect = NSRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: height)
            (value > 0 ? NSColor.systemTeal : NSColor.white.withAlphaComponent(0.15)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

/// Zeile mit Text links und Text rechts
func splitRow(_ left: NSView, _ right: NSView) -> NSStackView {
    left.setContentHuggingPriority(.defaultLow, for: .horizontal)
    left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    right.setContentHuggingPriority(.required, for: .horizontal)
    right.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = NSStackView(views: [left, right])
    row.orientation = .horizontal
    row.distribution = .fill
    row.spacing = 6
    return row
}

// MARK: - Widget

struct Section {
    let name: String
    let localName: String
    var plan: String?
    var limits: [Limit] = []
    var surfaces: [(String, Double)] = []
    var installed = false
    var error: String?
    var scan: ScanResult?
    var localError: String?

    /// Beginn des Wochenfensters laut Server; ist es noch nicht angelaufen (Codex startet es erst
    /// mit der ersten Nutzung), gelten die letzten 7 Tage.
    var weekStart: (date: Date, isCurrentWeek: Bool, label: String) {
        let rolling = (Date().addingTimeInterval(-week), false, t("Letzte 7 Tage", "Last 7 days"))
        guard let reset = limits.first(where: { $0.window == week })?.resetsAt else { return rolling }
        let start = reset.addingTimeInterval(-week)
        return start < Date().addingTimeInterval(-5 * 60) ? (start, true, t("Aktuelle Woche", "Current week")) : rolling
    }
}

final class Widget: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let config: Config
    let panel: NSPanel
    let stack = NSStackView()
    var claude = Section(name: "Claude", localName: "Claude Code")
    var codex = Section(name: "Codex", localName: "Codex CLI")
    let claudeScanner: LogScanner
    let codexScanner: LogScanner
    let scanQueue = DispatchQueue(label: "burnrate.scan", qos: .utility)
    var scanning = false
    var samples: [String: [(Date, Double)]] = [:]
    var updatedAt: Date?
    var timer: Timer?
    var widthConstraint: NSLayoutConstraint!

    enum Mode: String, CaseIterable {
        case mini, compact, details

        var title: String {
            switch self {
            case .mini: return "Mini"
            case .compact: return t("Kompakt", "Compact")
            case .details: return "Details"
            }
        }
        var width: CGFloat {
            switch self {
            case .mini: return 0  // ergibt sich aus dem Inhalt
            case .compact: return 250
            case .details: return 290
            }
        }
        var padding: CGFloat { self == .mini ? 10 : 12 }
    }

    var mode: Mode {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: "mode"), let mode = Mode(rawValue: raw) { return mode }
            return defaults.bool(forKey: "expanded") ? .details : .compact  // Einstellung älterer Versionen
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mode") }
    }
    var expanded: Bool { mode == .details }
    var modeItems: [Mode: NSMenuItem] = [:]

    /// Codex-Werte anzeigen (Rechtsklick-Menü); aus = kein Abruf, kein Log-Scan, keine Anzeige
    var showCodex: Bool {
        get { UserDefaults.standard.object(forKey: "showCodex") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showCodex") }
    }
    var codexItem: NSMenuItem!

    static let screenMargin: CGFloat = 10

    var miniWidth: CGFloat?
    /// Mini passt sich dem Inhalt an, die anderen Ansichten haben feste Breiten
    var width: CGFloat { mode == .mini ? (miniWidth ?? 0) + 2 * padding : mode.width }
    var padding: CGFloat { mode.padding }
    var stackConstraints: [NSLayoutConstraint] = []

    init(config: Config) {
        self.config = config
        claudeScanner = LogScanner(format: .claude, root: config.claudeProjectsDir)
        codexScanner = LogScanner(format: .codex, root: config.codexSessionsDir)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Mode.compact.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        setupPanel()
    }

    func setupPanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .vibrantDark)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        let menu = NSMenu()
        for (index, mode) in Mode.allCases.enumerated() {
            let item = menu.addItem(withTitle: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.representedObject = mode.rawValue
            modeItems[mode] = item
        }
        menu.addItem(.separator())
        codexItem = menu.addItem(withTitle: t("Codex anzeigen", "Show Codex"), action: #selector(toggleCodex), keyEquivalent: "")
        codexItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: t("Jetzt aktualisieren", "Refresh now"), action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: t("Nach oben links", "Move to top left"), action: #selector(moveToCorner), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: t("Beenden", "Quit"), action: #selector(quit), keyEquivalent: "q").target = self
        background.menu = menu

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        widthConstraint = stack.widthAnchor.constraint(equalToConstant: width - 2 * padding)
        stackConstraints = [
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -padding),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: padding),
        ]
        NSLayoutConstraint.activate(stackConstraints + [widthConstraint])
        render()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        restorePosition()
        panel.delegate = self
        panel.orderFrontRegardless()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: config.refreshSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Zuletzt gespeicherte Position (obere linke Ecke), sofern sie noch auf einem Bildschirm liegt
    func restorePosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "positionX") != nil {
            let point = NSPoint(x: defaults.double(forKey: "positionX"), y: defaults.double(forKey: "positionY"))
            let probe = NSPoint(x: point.x + 20, y: point.y - 20)
            if NSScreen.screens.contains(where: { $0.frame.contains(probe) }) {
                panel.setFrameTopLeftPoint(point)
                return
            }
        }
        moveToCorner()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(panel.frame.minX, forKey: "positionX")
        UserDefaults.standard.set(panel.frame.maxY, forKey: "positionY")
    }

    @objc func moveToCorner() {
        guard let screen = NSScreen.screens.first else { return }  // Hauptbildschirm (mit Menüleiste)
        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + Widget.screenMargin, y: visible.maxY - Widget.screenMargin))
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Mode(rawValue: raw) else { return }
        self.mode = mode
        render()
    }

    @objc func toggleCodex() {
        showCodex.toggle()
        refresh()
    }

    @objc func showMini() { mode = .mini; render() }
    @objc func showCompact() { mode = .compact; render() }
    @objc func showDetails() { mode = .details; render() }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func refresh() {
        let fm = FileManager.default
        claude.installed = fm.fileExists(atPath: config.claudeProjectsDir.path)
            || hasKeychainEntry(service: config.claudeKeychainService)
        codex.installed = showCodex
            && (fm.fileExists(atPath: config.codexAuthFile) || fm.fileExists(atPath: config.codexSessionsDir.path))
        if claude.installed { refreshClaude() }
        if codex.installed { refreshCodex() }
        refreshLocal()
        render()
    }

    // MARK: Abfragen

    func refreshClaude() {
        let credentials: (token: String, plan: String?)
        do {
            credentials = try readClaudeCredentials(service: config.claudeKeychainService)
        } catch {
            claude.error = errorText(error)
            render()
            return
        }
        claude.plan = credentials.plan
        var request = URLRequest(url: config.claudeURL)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.claudeBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20
        fetchJSON(request, tokenHint: t("Claude Code kurz starten", "open Claude Code briefly")) { [weak self] result in
            guard let self else { return }
            if case .success(let json) = result {
                self.claude.surfaces = parseClaudeSurfaces(json)
            }
            self.apply(result.flatMap { json in Result { try parseClaudeLimits(json) }.mapError { UsageError(errorText($0)) } }, to: \.claude)
        }
    }

    func refreshCodex() {
        let credentials: (token: String, accountId: String?)
        do {
            credentials = try readCodexCredentials(path: config.codexAuthFile)
        } catch {
            codex.error = errorText(error)
            render()
            return
        }
        var request = URLRequest(url: config.codexURL)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 20
        fetchJSON(request, tokenHint: t("Codex kurz starten", "open Codex briefly")) { [weak self] result in
            guard let self else { return }
            if case .success(let json) = result {
                self.codex.plan = json["plan_type"] as? String
            }
            self.apply(result.flatMap { json in Result { try parseCodexLimits(json) }.mapError { UsageError(errorText($0)) } }, to: \.codex)
        }
    }

    func refreshLocal() {
        guard !scanning else { return }
        scanning = true
        let claudeScanner = claude.installed ? claudeScanner : nil
        let codexScanner = codex.installed ? codexScanner : nil
        scanQueue.async { [weak self] in
            let (claudeResult, codexResult) = autoreleasepool {
                (claudeScanner.map { s in Result { try s.scan() } }, codexScanner.map { s in Result { try s.scan() } })
            }
            malloc_zone_pressure_relief(nil, 0)  // freigegebene Lese-Puffer wirklich an macOS zurückgeben
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                for (result, section) in [(claudeResult, \Widget.claude), (codexResult, \Widget.codex)] {
                    guard let result else { continue }
                    switch result {
                    case .success(let events):
                        self[keyPath: section].scan = events
                        self[keyPath: section].localError = nil
                    case .failure(let error):
                        self[keyPath: section].localError = errorText(error)
                    }
                }
                self.render()
            }
        }
    }

    func apply(_ result: Result<[Limit], UsageError>, to section: ReferenceWritableKeyPath<Widget, Section>) {
        switch result {
        case .success(let limits):
            self[keyPath: section].limits = limits
            self[keyPath: section].error = nil
            updatedAt = Date()
            recordSamples(limits, section: self[keyPath: section].name)
        case .failure(let error):
            // letzte Werte bleiben stehen, Fehler wird darunter angezeigt
            self[keyPath: section].error = error.message
        }
        render()
    }

    func recordSamples(_ limits: [Limit], section: String) {
        let now = Date()
        for limit in limits {
            let key = "\(section)|\(limit.title)"
            var list = samples[key, default: []].filter { now.timeIntervalSince($0.0) < 2 * hour }
            // Fenster-Reset → Verlauf neu beginnen
            if let last = list.last, limit.percent < last.1 { list.removeAll() }
            list.append((now, limit.percent))
            samples[key] = list
        }
    }

    /// Zuwachs in der letzten Stunde (bzw. seit Start des Widgets, wenn kürzer)
    func recentDelta(section: String, limit: Limit) -> (delta: Double, since: TimeInterval)? {
        guard let list = samples["\(section)|\(limit.title)"], let last = list.last else { return nil }
        let reference = list.first { last.0.timeIntervalSince($0.0) <= hour } ?? list[0]
        let span = last.0.timeIntervalSince(reference.0)
        guard span >= 10 * 60 else { return nil }
        return (last.1 - reference.1, span)
    }

    // MARK: Darstellung

    func addFullWidth(_ view: NSView, spacingAfter: CGFloat? = nil) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    func keyValue(_ key: String, _ value: String, indent: Bool = false) {
        addFullWidth(splitRow(
            label((indent ? "   " : "") + key, size: 10, color: .secondaryLabelColor),
            label(value, size: 10, weight: .medium, mono: true)
        ))
    }

    func renderHeader(_ section: Section, stats: LocalStats?) {
        let heading = [section.name, section.plan].compactMap { $0 }.joined(separator: " · ").uppercased()
        let title = label(heading, size: 10, weight: .bold, color: .secondaryLabelColor)
        guard let stats else {
            addFullWidth(title, spacingAfter: 6)
            return
        }
        // Burn Rate: Tokens/min der letzten Minuten aus den lokalen Logs
        let flame = NSImageView(image: NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Burn Rate")!)
        flame.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        flame.contentTintColor = stats.burnPerMinute > 0 ? .systemOrange : .tertiaryLabelColor
        let burn = label("\(formatTokens(stats.burnPerMinute))/min", size: 10, weight: .bold,
                         color: stats.burnPerMinute > 0 ? .labelColor : .tertiaryLabelColor, mono: true)
        let right = NSStackView(views: [flame, burn])
        right.spacing = 3
        right.toolTip = t("Tokens pro Minute (ohne Cache-Reads), letzte", "Tokens per minute (excluding cache reads), last") + " \(Int(config.burnMinutes)) min"
        addFullWidth(splitRow(title, right), spacingAfter: 6)
    }

    func renderLimit(_ limit: Limit, section: Section, now: Date) {
        let limitColor = color(forPercent: limit.percent, severity: limit.severity)
        let title = label(limit.title, size: 12, weight: .semibold)
        let percent = label("\(Int(limit.percent.rounded())) %", size: 12, weight: .bold, color: limitColor, mono: true)
        addFullWidth(splitRow(title, percent))

        let p = pace(of: limit, now: now)
        let bar = BarView()
        bar.fraction = CGFloat(limit.percent / 100)
        bar.projected = CGFloat((p?.projected ?? 0) / 100)
        bar.color = limitColor
        addFullWidth(bar)

        let paceLabel: NSTextField
        if let p, let untilFull = p.untilFull, let reset = limit.resetsAt, untilFull < reset.timeIntervalSince(now) {
            // Rot nur, wenn es bald eng wird – früh im Fenster schwankt die Hochrechnung stark
            paceLabel = label(t("voll in ~", "full in ~") + formatDuration(untilFull), size: 10, weight: .semibold,
                              color: untilFull < 6 * hour ? .systemRed : .systemOrange)
        } else if let p {
            paceLabel = label("\(formatNumber(p.perHour, digits: 1)) %/h → \(Int(p.projected.rounded())) %", size: 10,
                              color: p.projected >= 90 ? .systemOrange : .secondaryLabelColor, mono: true)
        } else {
            paceLabel = label("", size: 10)
        }
        paceLabel.toolTip = t("Ø Tempo seit Fensterbeginn → Prognose bei Reset", "Avg. pace since window start → projection at reset")
        let reset = label(resetText(limit.resetsAt), size: 10, color: .secondaryLabelColor)
        addFullWidth(splitRow(reset, paceLabel), spacingAfter: expanded ? 2 : 8)

        if expanded {
            if let recent = recentDelta(section: section.name, limit: limit) {
                let span = recent.since >= hour - 120 ? t("letzte Stunde", "last hour") : t("letzte ", "last ") + formatDuration(recent.since)
                let sign = recent.delta > 0 ? "+" : ""
                keyValue(span, "\(sign)\(Int(recent.delta.rounded())) %")
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(8, after: last) }
        }
    }

    func renderDetails(_ section: Section, stats: LocalStats) {
        let weekSuffix = section.weekStart.isCurrentWeek ? t("Woche", "week") : t("7 Tage", "7 days")
        addFullWidth(label(t("LOKAL · ", "LOCAL · ") + section.localName.uppercased(), size: 9, weight: .bold, color: .tertiaryLabelColor), spacingAfter: 3)
        keyValue("Burn (\(Int(config.burnMinutes)) min)",
                 "\(formatTokens(stats.burnPerMinute))/min · Out \(formatTokens(stats.outputPerMinute))/min")
        for (name, totals) in [(t("Letzte 5 h", "Last 5 h"), stats.last5h), (t("Heute", "Today"), stats.today), (section.weekStart.label, stats.week)] {
            keyValue(name, "\(formatTokens(Double(totals.tokens))) · \(totals.requests) Req")
        }
        keyValue(t("Cache-Reads", "Cache reads") + " (\(weekSuffix))", formatTokens(Double(stats.week.cacheRead)))

        let modelTotal = Double(stats.models.reduce(0) { $0 + $1.1 })
        if modelTotal > 0 {
            keyValue(t("Modelle", "Models") + " (\(weekSuffix))", "")
            for (model, tokens) in stats.models.prefix(4) {
                keyValue(shortModel(model), "\(Int((Double(tokens) / modelTotal * 100).rounded())) %", indent: true)
            }
        }
        if !section.surfaces.isEmpty {
            keyValue(t("Oberflächen (Woche)", "Surfaces (week)"), "")
            for (name, percent) in section.surfaces {
                keyValue(name, "\(Int(percent.rounded())) %", indent: true)
            }
        }

        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(6, after: last) }
        let spark = SparklineView()
        spark.values = stats.buckets
        spark.toolTip = t("Tokens pro 15 min, letzte 5 h", "Tokens per 15 min, last 5 h")
        addFullWidth(spark, spacingAfter: 2)
        addFullWidth(splitRow(
            label(t("vor 5 h", "5 h ago"), size: 9, color: .tertiaryLabelColor),
            label("Tok / 15 min · max \(formatTokens(Double(stats.buckets.max() ?? 0)))", size: 9, color: .tertiaryLabelColor)
        ), spacingAfter: 8)
    }

    /// Kleine Tabelle: eine Zeile pro Tool, eine Spalte pro Zeitfenster (5h, Woche, …)
    func renderMini(_ sections: [Section]) {
        var columns: [String] = []
        for limit in sections.flatMap(\.limits) {
            if let short = limit.short, !columns.contains(short) { columns.append(short) }
        }
        // Spalte für Warnung/Laden nur, wenn sie gebraucht wird (sonst bleibt rechts Leerraum)
        let needsStatus = sections.contains { $0.error != nil || $0.limits.isEmpty }
        let rows: [[NSView]] = sections.map { section in
            let name = label(section.name, size: 11, weight: .bold, color: .secondaryLabelColor)
            let cells: [NSView] = columns.map { column in
                guard let limit = section.limits.first(where: { $0.short == column }) else { return NSGridCell.emptyContentView }
                let short = label(column, size: 9, weight: .semibold, color: .tertiaryLabelColor)
                let percent = label("\(Int(limit.percent.rounded())) %", size: 12, weight: .bold,
                                    color: color(forPercent: limit.percent, severity: limit.severity), mono: true)
                let pair = NSStackView(views: [short, percent])
                pair.spacing = 3
                pair.alignment = .firstBaseline
                pair.toolTip = "\(limit.title): \(Int(limit.percent.rounded())) % · \(resetText(limit.resetsAt))"
                return pair
            }
            guard needsStatus else { return [name] + cells }
            var status: NSView = NSGridCell.emptyContentView
            if let error = section.error {
                let warning = label("⚠︎", size: 11, weight: .bold, color: .systemOrange)
                warning.toolTip = error
                status = warning
            } else if section.limits.isEmpty {
                status = label("…", size: 11, color: .tertiaryLabelColor)
            }
            return [name] + cells + [status]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        for index in 1..<grid.numberOfColumns { grid.column(at: index).xPlacement = .trailing }
        grid.rowAlignment = .firstBaseline
        stack.addArrangedSubview(grid)
        miniWidth = grid.fittingSize.width
    }

    func render(_ section: Section) {
        let now = Date()
        let stats = section.scan.map {
            LocalStats.compute($0, weekStart: section.weekStart.date, burnMinutes: config.burnMinutes, now: now)
        }
        renderHeader(section, stats: stats)

        for limit in section.limits {
            renderLimit(limit, section: section, now: now)
        }

        for message in [section.error, section.localError.map { t("Lokale Logs: ", "Local logs: ") + $0 }].compactMap({ $0 }) {
            addFullWidth(label("⚠︎ " + message, size: 10, color: .systemOrange), spacingAfter: 8)
        }
        if section.error == nil && section.limits.isEmpty {
            addFullWidth(label(t("lädt …", "loading …"), size: 10, color: .secondaryLabelColor), spacingAfter: 8)
        }

        if expanded {
            if let stats {
                renderDetails(section, stats: stats)
            } else if section.localError == nil {
                addFullWidth(label(t("lokale Logs werden gelesen …", "reading local logs …"), size: 10, color: .tertiaryLabelColor), spacingAfter: 8)
            }
        }
    }

    func footerButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return button
    }

    func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        widthConstraint.constant = width - 2 * padding
        stackConstraints[0].constant = padding
        stackConstraints[1].constant = -padding
        stackConstraints[2].constant = padding
        for (mode, item) in modeItems { item.state = mode == self.mode ? .on : .off }
        codexItem.state = showCodex ? .on : .off

        let visible = [claude, codex].filter(\.installed)
        if visible.isEmpty {
            addFullWidth(label(t("Weder Claude Code noch Codex gefunden", "Neither Claude Code nor Codex found"), size: 11, color: .secondaryLabelColor), spacingAfter: 8)
        }

        if mode == .mini {
            if visible.isEmpty { miniWidth = Mode.compact.width - 2 * padding } else { renderMini(visible) }
            widthConstraint.constant = width - 2 * padding
        } else {
            for section in visible {
                render(section)
                if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
            }

            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            let buttons = mode == .details
                ? NSStackView(views: [footerButton(t("Weniger ▴", "Less ▴"), #selector(showCompact))])
                : NSStackView(views: [footerButton("Mini ▴", #selector(showMini)), footerButton("Details ▾", #selector(showDetails))])
            buttons.spacing = 10
            buttons.setHuggingPriority(.required, for: .horizontal)
            addFullWidth(splitRow(
                label(updatedAt.map { t("Stand ", "Updated ") + f.string(from: $0) } ?? "", size: 10, color: .tertiaryLabelColor),
                buttons
            ))
        }
        if expanded {
            addFullWidth(label(t("Tok = Input + Output + Cache-Write (ohne Cache-Reads)", "Tok = input + output + cache write (excl. cache reads)"), size: 9, color: .tertiaryLabelColor))
        }

        // Größe an Inhalt anpassen, obere linke Ecke bleibt stehen
        let top = panel.frame.maxY
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 2 * padding
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: width, height: height), display: true)
    }
}

// MARK: - Start

let config = Config.fromEnvironment()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let widget = Widget(config: config)
app.delegate = widget
app.run()
