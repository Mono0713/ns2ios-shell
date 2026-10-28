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
    }
    func removeObject(forKey k: String) { if d.removeValue(forKey: k) != nil { write() } }
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

    init(_ settings: [Setting], defaults: SettingsStore) {
        self.defaults = defaults
        var settings = settings
        if let i = settings.firstIndex(where: { $0.env == "DM_LANG" }), let d = deviceLanguage(settings[i]) { settings[i].def = d }
        self.settings = settings
        fromFile = Set((ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        for s in settings {
            if fromFile.contains(s.env), let v = ProcessInfo.processInfo.environment[s.env] { values[s.env] = v; continue }
            let saved = defaults.string(forKey: "launcher." + s.env)
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    var changed: Bool { settings.contains { !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset every launcher choice to the game's defaults; an env file's values stay.
    func reset() {
        for s in settings {
            defaults.removeObject(forKey: "launcher." + s.env)
            if !fromFile.contains(s.env) { values[s.env] = s.def }
        }
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
    func apply() {
        save()
        for s in settings {
            let v = values[s.env] ?? s.def
            if fromFile.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (env file)\n", stderr); continue }
            if v == "-" { fputs("launcher: \(s.env) left at the package's value\n", stderr); continue }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }
}
