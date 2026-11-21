import Darwin
import Foundation

@main
enum SaveSlotsTests {
    static let fm = FileManager.default

    static func put(_ value: String, at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    static func check(_ url: URL, _ expected: String) throws {
        let data = try Data(contentsOf: url)
        precondition(data == Data(expected.utf8), url.lastPathComponent)
    }

    static func fixture(_ name: String, in root: URL) -> (SaveSlotsModel, URL, URL, URL) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let live = base.appendingPathComponent("live", isDirectory: true)
        let device = base.appendingPathComponent("live_device", isDirectory: true)
        let parked = base.appendingPathComponent("live.slots", isDirectory: true)
        setenv("DM_SAVE", live.path, 1)
        return (SaveSlotsModel(defaultName: { "Save \($0)" }), live, device, parked)
    }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("switchpad-save-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let (model, live, device, parked) = fixture("committed", in: root)
        try put("progress", at: live.appendingPathComponent("game/slot.dat"))
        try put("settings", at: device.appendingPathComponent("settings.dat"))
        let work = live.deletingLastPathComponent().appendingPathComponent("live.work/pending.dat")
        try put("uncommitted", at: work)
        model.duplicate(name: "Copy")
        precondition(model.problem == nil && model.active == 1 && model.slots.map(\.name) == ["Save 1", "Copy"])
        try check(live.appendingPathComponent("game/slot.dat"), "progress")
        try check(device.appendingPathComponent("settings.dat"), "settings")
        try check(parked.appendingPathComponent("2/save/game/slot.dat"), "progress")
        try check(parked.appendingPathComponent("2/device/settings.dat"), "settings")
        precondition(!fm.fileExists(atPath: parked.appendingPathComponent("1").path))
        precondition(!fm.fileExists(atPath: parked.appendingPathComponent("2/save.work").path))
        try check(work, "uncommitted")
        let reloaded = SaveSlotsModel(defaultName: { "Save \($0)" })
        precondition(reloaded.active == 1 && reloaded.slots == model.slots)
        reloaded.switchTo(2)
        precondition(reloaded.problem == nil && reloaded.active == 2)
        try check(live.appendingPathComponent("game/slot.dat"), "progress")
        try check(device.appendingPathComponent("settings.dat"), "settings")
        for _ in 0..<5 {
            reloaded.switchTo(1)
            reloaded.switchTo(2)
        }
        precondition(reloaded.problem == nil && reloaded.slots.count == 2)
        reloaded.switchTo(1)
        reloaded.delete(2)
        let afterDeletion = SaveSlotsModel(defaultName: { "Save \($0)" })
        afterDeletion.addEmpty()
        precondition(afterDeletion.active == 3 && afterDeletion.slots.map(\.id) == [1, 3])
        try check(parked.appendingPathComponent("1/save/game/slot.dat"), "progress")

        let (blank, blankLive, _, _) = fixture("blank", in: root)
        blank.duplicate(name: "Blank copy")
        precondition(blank.problem == nil && blank.active == 1 && blank.slots.count == 2)
        precondition(!fm.fileExists(atPath: blankLive.path))

        let (occupied, occupiedLive, _, occupiedParked) = fixture("occupied", in: root)
        try put("source", at: occupiedLive.appendingPathComponent("state.dat"))
        let existing = occupiedParked.appendingPathComponent("2/save/keep.dat")
        try put("existing", at: existing)
        occupied.duplicate(name: "Collision")
        precondition(occupied.problem != nil && occupied.active == 1 && occupied.slots.count == 1)
        try check(existing, "existing")
        try check(occupiedLive.appendingPathComponent("state.dat"), "source")

        let (failed, failedLive, _, failedParked) = fixture("metadata-failure", in: root)
        try put("source", at: failedLive.appendingPathComponent("state.dat"))
        try fm.createDirectory(at: failedParked.appendingPathComponent("slots.json"), withIntermediateDirectories: true)
        failed.duplicate(name: "Unpublished")
        precondition(failed.problem != nil && failed.active == 1 && failed.slots.count == 1)
        try check(failedLive.appendingPathComponent("state.dat"), "source")
        let remaining = try fm.contentsOfDirectory(atPath: failedParked.path)
        precondition(remaining == ["slots.json"])

        let (switchFailure, switchLive, _, switchParked) = fixture("switch-metadata-failure", in: root)
        try put("original", at: switchLive.appendingPathComponent("state.dat"))
        switchFailure.duplicate(name: "Copy")
        let copyPath = switchParked.appendingPathComponent("2/save/state.dat")
        try put("different copy", at: copyPath)
        let metadata = switchParked.appendingPathComponent("slots.json")
        try fm.removeItem(at: metadata)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        switchFailure.switchTo(2)
        precondition(switchFailure.problem != nil && switchFailure.active == 1)
        try check(switchLive.appendingPathComponent("state.dat"), "original")
        try check(copyPath, "different copy")

        print("Save slots: committed data, device data, blank save and rollback checks passed")
    }
}
