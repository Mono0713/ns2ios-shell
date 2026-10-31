// Launcher settings, validation and persistence. Shared by the iOS UI and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note: String
    var def: String   // DM_LANG's follows the device's language (LauncherModel)
    let section: String?   // heading on the settings screen; absent in older bundles
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }
            return n >= lo && n <= hi
        case "memory":   // "-" (the package's value) or bytes in hex within the slider's range
            if v == "-" { return true }
            guard v.lowercased().hasPrefix("0x"), let n = UInt64(v.dropFirst(2), radix: 16), let lo = min, let hi = max else { return false }
            let g = Double(n) / 1073741824; return g >= lo - 0.01 && g <= hi + 0.01
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, options, min, max, step, on, off }
}
struct SettingsFile: Decodable { let settings: [Setting] }

// Where the launcher keeps a game's choices: Library/Application Support/launcher/<name>.json (name: the title ID in a package of several games,
// "app" otherwise), written whole as each choice changes. A file of the app's own rather than UserDefaults: those writes go to a system process
// that the game, once it runs, may keep from getting them, and choices were found missing after the app was closed. The UserDefaults ones of
// earlier builds are taken over the first time
final class SettingsStore {
    private static var open: [String: SettingsStore] = [:]
    static func named(_ name: String, from old: UserDefaults) -> SettingsStore {
        if let s = open[name] { return s }
        let s = SettingsStore(name, from: old); open[name] = s; return s
    }
    private let url: URL
    private var d: [String: Any] = [:]
    private init(_ name: String, from old: UserDefaults) {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name + ".json")
        if let data = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            d = j
            fputs("launcher: \(d.count) kept choices from \(url.lastPathComponent)\n", stderr)
        } else {
            d = old.dictionaryRepresentation().filter { $0.key.hasPrefix("launcher.") }
            if !d.isEmpty { write(); fputs("launcher: \(d.count) choices taken over from UserDefaults into \(url.lastPathComponent)\n", stderr) }
        }
    }
    private func write() {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        do { try data.write(to: url, options: .atomic) } catch { fputs("[RED] launcher: cannot keep the choices in \(url.path): \(error.localizedDescription)\n", stderr) }
    }
    func string(forKey k: String) -> String? { d[k] as? String }
    func object(forKey k: String) -> Any? { d[k] }
    func bool(forKey k: String) -> Bool { d[k] as? Bool ?? false }
    func set(_ v: Any, forKey k: String) {
        if let a = d[k] as? NSObject, let b = v as? NSObject, a == b { return }   // a slider sends the same value many times
        d[k] = v; write()
        fputs("launcher: kept \(k.dropFirst("launcher.".count))=\(v) in \(url.lastPathComponent)\n", stderr)
    }
    func removeObject(forKey k: String) { if d.removeValue(forKey: k) != nil { write() } }
    var runURL: URL { url.deletingPathExtension().appendingPathExtension("run") }   // MemoryAuto's run marker, beside the choices
}

// Automatic game memory: the memory pool (DM_APP_POOL) left at "-" is chosen by the launcher. Each run's marker (hle_runmark.c) says how the run ended, and only
// a failure that points at memory moves the size: iOS killing the app under memory pressure → smaller; the host refusing the game memory before a crash → larger;
// the game's own abort with no refusal is taken as "maybe too small" once, then as not memory. Any other crash, or the player leaving, leaves the size alone. A size
// that ran for 40 s is kept for good (until it fails for memory). Stored in the game's SettingsStore under auto.DM_APP_POOL: ok, failed {size: outcome}, last
struct MemoryAuto {
    enum Outcome: String { case worked, tooBig, tooSmall, maybeSmall, notMemory }
    static let key = "auto.DM_APP_POOL"
    static let ladder: [UInt64] = [0x40000000, 0x60000000, 0x80000000, 0xA0000000, 0xCCD00000]   // 1, 1.5, 2, 2.5, 3.2 GB (the slider's whole MiB)
    let package: UInt64
    private(set) var pick: UInt64
    private(set) var confirmed = false   // pick ran 40 s before
    private(set) var last: (pool: UInt64, outcome: Outcome)?   // what the previous automatic run told, when it told something
    private(set) var exhausted = false   // every size failed: back to the package's, the problem is not memory
    private let store: SettingsStore

    static func hex(_ v: UInt64) -> String { String(format: "0x%llX", v) }
    static func parse(_ s: String) -> UInt64? { let t = s.lowercased(); return t.hasPrefix("0x") ? UInt64(t.dropFirst(2), radix: 16) : UInt64(t) }
    // The marker's state and memory flag (hle_runmark.c) → outcome; nil = not counted (the player left, or the run is unknown)
    static func outcome(state: Character, flag: Character) -> Outcome? {
        switch state {
        case "k": return .worked
        case "w", "b": return .tooBig   // killed by iOS with no crash of ours: memory pressure, or a kill at the limit too fast to see
        case "x": return flag == "m" ? .tooSmall : .maybeSmall
        case "c", "h": return flag == "m" ? .tooSmall : .notMemory
        default: return nil
        }
    }
    // The next size to try after a failure at p: the nearest untried one in the failure's direction, else the nearest the other way
    static func next(after p: UInt64, smaller: Bool, candidates: [UInt64], failed: Set<UInt64>) -> UInt64? {
        let open = candidates.filter { !failed.contains($0) && $0 != p }.sorted()
        let up = open.first { $0 > p }, down = open.last { $0 < p }
        return smaller ? (down ?? up) : (up ?? down)
    }

    init(store: SettingsStore, package: UInt64) {
        self.store = store; self.package = package
        var d = store.object(forKey: Self.key) as? [String: Any] ?? [:]
        var failed = (d["failed"] as? [String: String] ?? [:]).reduce(into: [UInt64: Outcome]()) { r, e in
            if let p = Self.parse(e.key), let o = Outcome(rawValue: e.value) { r[p] = o } }
        var ok = (d["ok"] as? String).flatMap(Self.parse)
        var lastPool = (d["last"] as? String).flatMap(Self.parse)
        let cands = Array(Set(Self.ladder + [package])).filter { $0 >= 0x20000000 && $0 <= 0xCCD00000 }
        // the previous run's marker: read once, then removed
        if let data = try? Data(contentsOf: store.runURL), data.count >= 2, let txt = String(data: data, encoding: .utf8) {
            try? FileManager.default.removeItem(at: store.runURL)
            let chars = Array(txt) + ["-", "-"]
            let kv = Dictionary(txt.split(separator: "\n").dropFirst().compactMap { l -> (String, String)? in
                let p = l.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil }, uniquingKeysWith: { a, _ in a })
            if kv["auto"] == "1", let p = kv["pool"].flatMap(Self.parse), let o = Self.outcome(state: chars[0], flag: chars[1]) {
                var o = o
                if o == .maybeSmall && failed.values.contains(.maybeSmall) { o = .notMemory }   // already moved up once for an abort: it is not memory
                last = (p, o); lastPool = p
                switch o {
                case .worked: ok = p; failed = [:]
                case .notMemory: break
                default: failed[p] = o; if ok == p { ok = nil }
                }
                fputs("launcher: automatic memory: the last run at \(Self.hex(p)) → \(o.rawValue) (marker \(chars[0])\(chars[1]))\n", stderr)
            }
        }
        if let ok { pick = ok; confirmed = true }
        else if let p = lastPool, let o = failed[p] {
            if let n = Self.next(after: p, smaller: o == .tooBig, candidates: cands, failed: Set(failed.keys)) { pick = n }
            else { pick = package; exhausted = true; failed = [:]; fputs("launcher: automatic memory: every size failed; back to the package's \(Self.hex(package))\n", stderr) }
        } else { pick = lastPool ?? package }
        d["ok"] = ok.map(Self.hex); d["last"] = Self.hex(pick)
        d["failed"] = Dictionary(uniqueKeysWithValues: failed.map { (Self.hex($0.key), $0.value.rawValue) })
        store.set(d, forKey: Self.key)
    }

    // Before the game starts: the marker the host fills in (dm_run_mark_open opens it); returns its path. It starts as "not counted" (g): the host marks it running
    // (b) when the game itself starts, so a kill while shaders are still being prepared says nothing about the game's memory
    func begin(pool: UInt64, auto: Bool) -> String {
        let text = "g-\npool=\(Self.hex(pool))\nauto=\(auto ? 1 : 0)\n"
        do { try text.write(to: store.runURL, atomically: true, encoding: .utf8) } catch { fputs("[RED] launcher: run marker not written: \(error.localizedDescription)\n", stderr) }
        fputs("launcher: memory pool \(Self.hex(pool)) (\(auto ? "automatic" : "chosen by the player"))\n", stderr)
        return store.runURL.path
    }
}

// The game language a player gets unless they choose one: the device's own when the game has it (Traditional Chinese, else Simplified, for a
// Chinese device; the same language for another region, such as en-GB for en-US), else English. Only a choice that differs from it is stored,
// so the game follows the device when its language changes
func deviceLanguage(_ s: Setting, preferred: [String] = Locale.preferredLanguages) -> String? {
    let codes = (s.options ?? []).map { $0[0] }
    func has(_ c: String) -> String? { codes.first { $0.caseInsensitiveCompare(c) == .orderedSame } }
    for p in preferred {
        let id = Locale(identifier: p), lang = id.language.languageCode?.identifier ?? "", region = id.region?.identifier ?? ""
        if lang == "zh" {
            let hant = id.language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(region)
            if let c = has(hant ? "zh-Hant" : "zh-Hans") ?? has(hant ? "zh-Hans" : "zh-Hant") { return c }
            continue
        }
        let regional: String? = switch lang {
            case "en": ["US", "CA", "PH", ""].contains(region) ? "en-US" : "en-GB"
            case "fr": region == "CA" ? "fr-CA" : "fr"
            case "es": ["ES", ""].contains(region) ? "es" : "es-419"
            case "pt": region == "BR" ? "pt-BR" : "pt"
            default: nil
        }
        if let r = regional, let c = has(r) { return c }
        if let c = codes.first(where: { $0.lowercased() == lang || $0.lowercased().hasPrefix(lang + "-") }) { return c }
    }
    return has("en-US") ?? has("en-GB")
}

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fromFile: Set<String>   // set by an env file: shown, not changed
    @Published var values: [String: String] = [:] { didSet { save() } }   // kept as soon as changed: closing the app or going back to the game list keeps them

    private let defaults: SettingsStore
    let memory: MemoryAuto?   // the memory pool at Auto ("-"): nil when an env file sets it or the package gives no size

    init(_ settings: [Setting], defaults: SettingsStore) {
        self.defaults = defaults
        var settings = settings
        if let i = settings.firstIndex(where: { $0.env == "DM_LANG" }), let d = deviceLanguage(settings[i]) { settings[i].def = d }
        self.settings = settings
        fromFile = Set((ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        let envFile = fromFile
        memory = settings.first { $0.env == "DM_APP_POOL" && $0.kind == "memory" && !envFile.contains($0.env) }
            .flatMap { ProcessInfo.processInfo.environment[$0.env].flatMap(MemoryAuto.parse) }
            .map { MemoryAuto(store: defaults, package: $0) }
        // Read every kept choice before assigning any: each assignment to values saves them all, and saving with the rest still unread
        // would store their defaults, deleting the choices about to be read (the language, and every setting after the first, came back as defaults)
        var loaded: [String: String] = [:]
        for s in settings {
            if fromFile.contains(s.env), let v = ProcessInfo.processInfo.environment[s.env] { loaded[s.env] = v; continue }
            let saved = defaults.string(forKey: "launcher." + s.env)
            loaded[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
            if let saved, !s.isDefault(loaded[s.env]!) { fputs("launcher: \(s.env)=\(saved) kept from before\n", stderr) }
        }
        values = loaded
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    var changed: Bool { settings.contains { !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset every launcher choice to the game's defaults; an env file's values stay.
    func reset() {
        var v = values
        for s in settings {
            defaults.removeObject(forKey: "launcher." + s.env)
            if !fromFile.contains(s.env) { v[s.env] = s.def }
        }
        values = v
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment, except the choice "-" (the package's own value, such as the bundle's
    // dm/env.txt memory layout for DM_APP_POOL, stays as it is; DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func save() {
        for s in settings where !fromFile.contains(s.env) {
            let v = values[s.env] ?? s.def
            if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) }
        }
    }
    // The run marker for this start (MemoryAuto.begin), after apply: nil without automatic memory
    func runMarker() -> String? {
        guard let a = memory else { return nil }
        let v = values["DM_APP_POOL"] ?? "-"
        return a.begin(pool: v == "-" ? a.pick : MemoryAuto.parse(v) ?? a.pick, auto: v == "-")
    }
    func apply() {
        save()
        for s in settings {
            let v = values[s.env] ?? s.def
            if fromFile.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (env file)\n", stderr); continue }
            if v == "-", s.kind == "memory", let a = memory { setenv(s.env, MemoryAuto.hex(a.pick), 1); fputs("launcher: \(s.env)=\(MemoryAuto.hex(a.pick)) (automatic)\n", stderr); continue }
            if v == "-" { fputs("launcher: \(s.env) left at the package's value\n", stderr); continue }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }
}
