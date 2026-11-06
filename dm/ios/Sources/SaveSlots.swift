// Save slots: several saves of one game, picked on the launcher (Launcher.swift) before the game starts, so a second player, a fresh
// run or a save brought from elsewhere does not replace the one in use.
//
// The save in use stays where the host reads it ($DM_SAVE, and <DM_SAVE>_device for a game that also mounts a device save; main.m,
// hle_fs.c), so the host and the PC tools (Switch Pad's saves_data.py) see it as before. The others wait in <DM_SAVE>.slots/<n>/ as
// save/ and device/ (with any .work / .new beside them), and <DM_SAVE>.slots/slots.json names every slot and the one in use:
//   {"active": 1, "slots": [{"id": 1, "name": "Save 1"}, {"id": 2, "name": "Save 2"}]}
// In a package of several games (the game library) that is Documents/save/<title ID>.slots, inside save/, so a backup of save/ takes
// every slot along; a one-game app's is Documents/save.slots. Switching moves folders (renames on one volume, nothing is copied) and is
// only offered before the game starts, while nothing has the save open. saves_data.py put --slot adds a slot from the PC the same way.
import Foundation
import Combine

struct SaveSlot: Identifiable, Codable, Equatable { var id: Int; var name: String }
struct SaveSlotProblem { let what, detail: String }   // what in English, which the launcher translates
private struct SlotsFile: Codable { var active: Int; var slots: [SaveSlot] }

final class SaveSlotsModel: ObservableObject {
    @Published private(set) var slots: [SaveSlot] = []
    @Published private(set) var active = 1
    @Published var problem: SaveSlotProblem?   // the last switch, copy or delete that failed, shown under the section
    let live: URL?                    // $DM_SAVE: the save in use
    private let defaultName: (Int) -> String
    private let fm = FileManager.default

    init(defaultName: @escaping (Int) -> String) {
        self.defaultName = defaultName
        live = ProcessInfo.processInfo.environment["DM_SAVE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        load()
    }

    var available: Bool { live != nil }
    var activeName: String { slots.first { $0.id == active }?.name ?? defaultName(active) }
    private var dir: URL? { live.map { URL(fileURLWithPath: $0.path + ".slots", isDirectory: true) } }
    private var file: URL? { dir?.appendingPathComponent("slots.json") }
    private func parked(_ id: Int) -> URL? { dir?.appendingPathComponent(String(id), isDirectory: true) }

    // Each folder of a save as it is in use and as it waits in its slot: the save, the device save, and the host's .work / .new of each
    private func pairs(_ id: Int) -> [(URL, URL)] {
        guard let live, let p = parked(id) else { return [] }
        return [("", "save"), ("_device", "device")].flatMap { suffix, name in
            ["", ".work", ".new"].map { x in (URL(fileURLWithPath: live.path + suffix + x, isDirectory: true), p.appendingPathComponent(name + x, isDirectory: true)) }
        }
    }
    private func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }

    private func load() {
        guard let file else { return }
        if let d = try? Data(contentsOf: file), let f = try? JSONDecoder().decode(SlotsFile.self, from: d), !f.slots.isEmpty {
            slots = f.slots; active = f.active
        } else {
            slots = [SaveSlot(id: 1, name: defaultName(1))]; active = 1
        }
        // a slot folder slots.json does not list (it was lost, or the PC copied one in) is listed again rather than left unseen
        if let dir, let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for n in names { if let id = Int(n), !slots.contains(where: { $0.id == id }) { slots.append(SaveSlot(id: id, name: defaultName(id))) } }
        }
        if !slots.contains(where: { $0.id == active }) { slots.insert(SaveSlot(id: active, name: defaultName(active)), at: 0) }
        // a switch cut short (the app killed between moves): the slot in use whose save is still parked gets it back
        for (l, p) in pairs(active) where exists(p) && !exists(l) { try? fm.moveItem(at: p, to: l) }
        if let p = parked(active), (try? fm.contentsOfDirectory(atPath: p.path))?.isEmpty == true { try? fm.removeItem(at: p) }
        slots.sort { $0.id < $1.id }
    }

    private func persist() throws {
        guard let dir, let file else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(SlotsFile(active: active, slots: slots)).write(to: file, options: .atomic)
    }

    private func fail(_ what: String, _ e: Error) {
        problem = SaveSlotProblem(what: what, detail: e.localizedDescription)
        fputs("[RED] save slots: \(what): \(e.localizedDescription)\n", stderr)
    }

    // Moves the save in use into its slot and the chosen slot's save in its place. Each move is a rename; one that fails puts back the ones done
    func switchTo(_ id: Int) {
        guard let live, id != active, slots.contains(where: { $0.id == id }), let from = parked(active), let to = parked(id) else { return }
        var done: [(URL, URL)] = []
        do {
            try fm.createDirectory(at: from, withIntermediateDirectories: true)
            for (l, p) in pairs(active) where exists(l) {
                if exists(p) { try fm.removeItem(at: p) }   // a leftover of an older switch: what is in use is the newer
                try fm.moveItem(at: l, to: p); done.append((l, p))
            }
            for (l, p) in pairs(id) where exists(p) { try fm.moveItem(at: p, to: l); done.append((p, l)) }
            if !exists(live) { try fm.createDirectory(at: live, withIntermediateDirectories: true) }   // a new slot starts empty, as a first start does
            try? fm.removeItem(at: to)
            let old = activeName
            active = id
            try persist()
            problem = nil
            fputs("save slots: \(old) put away, \(activeName) in use (\(live.path))\n", stderr)
        } catch {
            for (a, b) in done.reversed() { try? fm.moveItem(at: b, to: a) }
            if let f = file, let d = try? Data(contentsOf: f), let s = try? JSONDecoder().decode(SlotsFile.self, from: d) { active = s.active }
            fail("Could not switch saves", error)
        }
    }

    // The next slot, wrapping around (player 1's controller, left and right on the row)
    func step(_ d: Int) {
        guard let i = slots.firstIndex(where: { $0.id == active }), slots.count > 1 else { return }
        switchTo(slots[((i + d) % slots.count + slots.count) % slots.count].id)
    }

    private var nextId: Int { (slots.map(\.id).max() ?? 0) + 1 }

    // A new, empty save, at once in use: the game starts as on its first run, and the save that was in use waits in its slot
    func addEmpty() {
        let id = nextId
        slots.append(SaveSlot(id: id, name: defaultName(id)))
        do { try persist() } catch { slots.removeAll { $0.id == id }; fail("Could not add a save", error); return }
        switchTo(id)
        if active != id { slots.removeAll { $0.id == id }; try? persist() }
    }

    // A copy of the save in use as a slot of its own (not in use): a point to go back to
    func duplicate(name: String) {
        guard let p = parked(nextId) else { return }
        let id = nextId
        do {
            try fm.createDirectory(at: p, withIntermediateDirectories: true)
            for (l, q) in pairs(active) where exists(l) && !l.lastPathComponent.hasSuffix(".work") && !l.lastPathComponent.hasSuffix(".new") {
                try fm.copyItem(at: l, to: q)   // APFS clones the files
            }
            slots.append(SaveSlot(id: id, name: name))
            try persist()
            problem = nil
            fputs("save slots: \(activeName) copied as \(name)\n", stderr)
        } catch {
            try? fm.removeItem(at: p); slots.removeAll { $0.id == id }
            fail("Could not copy the save", error)
        }
    }

    func rename(_ id: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[i].name = String(n.prefix(40))
        do { try persist() } catch { fail("Could not rename the save", error) }
    }

    // A slot not in use, with its files
    func delete(_ id: Int) {
        guard id != active, let p = parked(id) else { return }
        do {
            if exists(p) { try fm.removeItem(at: p) }
            slots.removeAll { $0.id == id }
            try persist()
            problem = nil
            fputs("save slots: slot \(id) deleted\n", stderr)
        } catch { fail("Could not delete the save", error) }
    }
}
