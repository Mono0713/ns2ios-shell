// Save slots: several saves of one game, picked on the launcher (Launcher.swift) before the game starts, so a second player, a fresh
// run or a save brought from elsewhere does not replace the one in use.
//
// In the game library every save is a folder a person can see in the Files app (main.m, "Documents as a person reads it"):
//   存檔/<game>/<save name>/              the save itself: the files the game wrote, as an emulator, JKSV or Checkpoint exports them
//   存檔/<game>/.裝置存檔/<save name>/     the device save of a game that also has one (Mario Kart 8 Deluxe), hidden
//   存檔/<game>/.存檔.json                {"active": "<save name>", "order": ["<save name>", …]}: the one in use and the launcher's order
// The folder name is the save's name: renaming a save renames its folder, a folder copied in (the Files app, or the computer's
// saves_data.py) is a save of its own, and deleting the folder deletes the save. Switching changes which folder $DM_SAVE names (main.m set
// it for the save in use when the game was chosen; hle_fs.c reads it when the game mounts its save), so nothing moves; it is only offered
// before the game starts, while nothing has the save open. A package of one game (no $DM_SAVE_GAME) has no save slots.
import Foundation
import Combine

struct SaveSlot: Identifiable, Codable, Equatable { var id: Int; var name: String }
struct SaveSlotProblem { let what, detail: String }   // what in English, which the launcher translates

final class SaveSlotsModel: ObservableObject {
    @Published private(set) var slots: [SaveSlot] = []
    @Published private(set) var active = 1
    @Published var problem: SaveSlotProblem?   // the last switch, copy, rename or delete that failed, shown under the section
    let game: URL?                    // $DM_SAVE_GAME: 存檔/<game>/
    private let defaultName: (Int) -> String
    private let fm = FileManager.default
    private static let state = ".存檔.json", device = ".裝置存檔"

    init(defaultName: @escaping (Int) -> String) {
        self.defaultName = defaultName
        game = ProcessInfo.processInfo.environment["DM_SAVE_GAME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        load()
    }

    var available: Bool { game != nil }
    var activeName: String { slots.first { $0.id == active }?.name ?? defaultName(active) }
    /// The save in use ($DM_SAVE)
    var live: URL? { folder(active) }
    private func folder(_ id: Int) -> URL? {
        guard let game, let s = slots.first(where: { $0.id == id }) else { return nil }
        return game.appendingPathComponent(s.name, isDirectory: true)
    }
    private func deviceFolder(_ name: String) -> URL? {
        game?.appendingPathComponent(Self.device, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
    private func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    // Every folder of 存檔/<game>/ is a save, except hidden ones and the host's .work / .new beside the save in use (main.m shell_save_names)
    private func folderNames() -> [String] {
        guard let game, let names = try? fm.contentsOfDirectory(atPath: game.path) else { return [] }
        return names.filter { n in
            var dir: ObjCBool = false
            return !n.hasPrefix(".") && !n.hasSuffix(".work") && !n.hasSuffix(".new")
                && fm.fileExists(atPath: game.appendingPathComponent(n).path, isDirectory: &dir) && dir.boolValue
        }
    }
    private func readState() -> [String: Any] {
        guard let game, let d = try? Data(contentsOf: game.appendingPathComponent(Self.state)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    private func load() {
        guard game != nil else { return }
        let st = readState()
        let order = st["order"] as? [String] ?? []
        let names = folderNames().sorted { a, b in   // the order shown last time, then new folders by name
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a.localizedStandardCompare(b) == .orderedAscending
        }
        slots = names.enumerated().map { SaveSlot(id: $0.offset + 1, name: $0.element) }
        let want = st["active"] as? String
        active = slots.first { $0.name == want }?.id ?? slots.first?.id ?? 1
        if slots.isEmpty { addFolder(defaultName(1)).map { slots = [SaveSlot(id: 1, name: $0)] }; active = 1 }
        apply()
    }

    private func persist() throws {
        guard let game else { return }
        var st = readState()
        st["active"] = activeName
        st["order"] = slots.map(\.name)
        let d = try JSONSerialization.data(withJSONObject: st, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: game.appendingPathComponent(Self.state), options: .atomic)
    }

    // The host reads the save in use from the environment when the game mounts it
    private func apply() {
        guard let live else { return }
        setenv("DM_SAVE", live.path, 1)
        if let dv = deviceFolder(live.lastPathComponent) {
            try? fm.createDirectory(at: dv.deletingLastPathComponent(), withIntermediateDirectories: true)
            setenv("DM_SAVE_DEVICE", dv.path, 1)
        }
    }

    private func fail(_ what: String, _ e: Error) {
        problem = SaveSlotProblem(what: what, detail: e.localizedDescription)
        fputs("[RED] save slots: \(what): \(e.localizedDescription)\n", stderr)
    }

    // A save's name as a folder name: what Windows also accepts (the computer keeps the same folders), never empty, never one that exists
    private func freeName(_ want: String, except: String? = nil) -> String {
        var base = want.unicodeScalars.map { c -> String in
            if "\\/:*?\"<>|".unicodeScalars.contains(c) || c.value < 0x20 { return " " }
            return String(c)
        }.joined().split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if base.isEmpty { base = defaultName(slots.count + 1) }
        base = String(base.prefix(60))
        let taken = Set(folderNames().map { $0.lowercased() }).subtracting(except.map { [$0.lowercased()] } ?? [])
        var n = base, k = 2
        while taken.contains(n.lowercased()) { n = "\(base) (\(k))"; k += 1 }
        return n
    }
    @discardableResult private func addFolder(_ want: String) -> String? {
        guard let game else { return nil }
        let n = freeName(want)
        do { try fm.createDirectory(at: game.appendingPathComponent(n, isDirectory: true), withIntermediateDirectories: true); return n }
        catch { fail("Could not add a save", error); return nil }
    }
    private var nextId: Int { (slots.map(\.id).max() ?? 0) + 1 }

    func switchTo(_ id: Int) {
        guard id != active, slots.contains(where: { $0.id == id }) else { return }
        let old = activeName
        active = id
        do {
            if let live, !exists(live) { try fm.createDirectory(at: live, withIntermediateDirectories: true) }   // deleted by hand meanwhile: starts empty
            try persist(); apply(); problem = nil
            fputs("save slots: \(old) put away, \(activeName) in use (\(live?.path ?? "?"))\n", stderr)
        } catch {
            active = slots.first { $0.name == old }?.id ?? active
            apply()
            fail("Could not switch saves", error)
        }
    }

    // The next slot, wrapping around (player 1's controller, left and right on the row)
    func step(_ d: Int) {
        guard let i = slots.firstIndex(where: { $0.id == active }), slots.count > 1 else { return }
        switchTo(slots[((i + d) % slots.count + slots.count) % slots.count].id)
    }

    // A new, empty save, at once in use: the game starts as on its first run, and the save that was in use stays as it is
    func addEmpty() {
        let id = nextId
        guard let n = addFolder(defaultName(id)) else { return }
        slots.append(SaveSlot(id: id, name: n))
        switchTo(id)
        if active != id { slots.removeAll { $0.id == id } }
    }

    // A copy of the save in use as a save of its own (not in use): a point to go back to
    func duplicate(name: String) {
        guard let game, let live else { return }
        let n = freeName(name), id = nextId
        let to = game.appendingPathComponent(n, isDirectory: true)
        do {
            if exists(live) { try fm.copyItem(at: live, to: to) } else { try fm.createDirectory(at: to, withIntermediateDirectories: true) }   // APFS clones the files
            if let a = deviceFolder(live.lastPathComponent), let b = deviceFolder(n), exists(a) { try fm.copyItem(at: a, to: b) }
            slots.append(SaveSlot(id: id, name: n))
            try persist()
            problem = nil
            fputs("save slots: \(activeName) copied as \(n)\n", stderr)
        } catch {
            try? fm.removeItem(at: to); deviceFolder(n).map { try? fm.removeItem(at: $0) }
            slots.removeAll { $0.id == id }
            fail("Could not copy the save", error)
        }
    }

    // Renames the save's folder (and its device save's)
    func rename(_ id: Int, _ name: String) {
        guard let game, let i = slots.firstIndex(where: { $0.id == id }) else { return }
        let old = slots[i].name, want = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty, want != old else { return }
        let n = freeName(want, except: old)
        do {
            let from = game.appendingPathComponent(old, isDirectory: true)
            if exists(from) { try fm.moveItem(at: from, to: game.appendingPathComponent(n, isDirectory: true)) }
            if let a = deviceFolder(old), let b = deviceFolder(n), exists(a) { try fm.moveItem(at: a, to: b) }
            slots[i].name = n
            try persist()
            if id == active { apply() }
            problem = nil
        } catch { fail("Could not rename the save", error) }
    }

    // A save not in use, with its files
    func delete(_ id: Int) {
        guard id != active, let p = folder(id), let s = slots.first(where: { $0.id == id }) else { return }
        do {
            if exists(p) { try fm.removeItem(at: p) }
            if let dv = deviceFolder(s.name), exists(dv) { try fm.removeItem(at: dv) }
            slots.removeAll { $0.id == id }
            try persist()
            problem = nil
            fputs("save slots: \(s.name) deleted\n", stderr)
        } catch { fail("Could not delete the save", error) }
    }
}
