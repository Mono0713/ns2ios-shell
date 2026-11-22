// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once, as an app without launcher.json does
import SwiftUI
import Combine
import UIKit
import CoreImage.CIFilterBuiltins
import GameController
import os

// A package of several games (main.m, GamePicker.swift): the chosen game's folder, its game.json standing in for the app's own name and version,
// and its own UserDefaults suite, so each game keeps its settings. Read each time: the launcher can go back to the picker, which may choose another game
private var gameRoot: URL? { ProcessInfo.processInfo.environment["DM_SHELL_GAME_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
private var gameInfo: [String: Any] {
    gameRoot.flatMap { try? Data(contentsOf: $0.appendingPathComponent("game.json")) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}
var gameDefaults: SettingsStore {   // LauncherSettings.swift; earlier builds kept these in UserDefaults (the suite game.<title ID>, or the app's own)
    let g = ProcessInfo.processInfo.environment["DM_SHELL_GAME"]
    return SettingsStore.named(g ?? "app", from: g.flatMap { UserDefaults(suiteName: "game." + $0) } ?? .standard)
}
@_silgen_name("front_ios_back_to_picker") private func frontIosBackToPicker()
@_silgen_name("dm_run_mark_open") private func dmRunMarkOpen(_ path: UnsafePointer<CChar>)   // hle_runmark.c: the host records how this run ends

// The launcher and the game picker move with player 1's controller themselves (DMLauncherInput). Without this, iPadOS also moves its own focus over their
// buttons with it, and A then pressed whichever button that focus was left on (Open game folder, once tapped) as well as the highlighted row
func controllerNotForUIKit(_ view: UIView) {
    if #available(iOS 17.0, *) {
        let i = GCEventInteraction(); i.handledEventTypes = .gamepad
        view.addInteraction(i)
    }
}
// And iPadOS's focus never enters these screens at all: the interaction above did not keep it out everywhere (a row once tapped kept the focus, and A on a
// player's row also pressed New empty save or Rename this save, which made a save each time or opened the keyboard). Every row here is reached with the
// controller through DMLauncherInput, so the system's focus has nothing to do on them
final class NoFocusHostingController<Content: View>: UIHostingController<Content> {
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { false }
}
private let severalGames = Int(ProcessInfo.processInfo.environment["DM_SHELL_GAMES"] ?? "") ?? 0 > 1
private func info(_ key: String) -> Any? {
    if gameRoot != nil, key == "CFBundleDisplayName", let n = gameInfo["name"] { return n }
    if gameRoot != nil, key == "CFBundleShortVersionString", let v = gameInfo["version"] { return v }
    return Bundle.main.object(forInfoDictionaryKey: key)
}

// Traditional Chinese when the device's first language is (zh-Hant, zh-TW, zh-HK, zh-MO); anything else stays English. launcher.json carries settings.tsv's
// English labels and notes and nacp.py's language names, so they are looked up by their English text; an unknown one is shown as it is
private let zhHant: Bool = {
    let l = (Locale.preferredLanguages.first ?? "").lowercased()
    return l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo")
}()
private let zhText: [String: String] = [
    // sections and launcher.json's labels, notes and choices (settings.tsv)
    "Game": "遊戲", "Controls": "操作", "Performance": "效能",
    "Frame rate": "幀率", "Render scale": "渲染解析度", "Console mode": "主機模式", "Docked": "電視模式", "Handheld": "掌機模式",
    "Upscaling": "畫面放大", "Standard": "標準", "Uses more GPU time and can increase heat.": "會增加 GPU 負擔，機身可能較熱。",
    "Game language": "遊戲語言", "Frame-rate counter": "顯示 FPS",
    "Xbox button layout": "Xbox 按鍵配置", "A, B, X and Y as printed on an Xbox controller (Switch games expect A on the right).": "A、B、X、Y 依 Xbox 手把上的標示（Switch 遊戲預設 A 在右側）。",
    "Touch feedback": "觸控震動回饋", "Game rumble": "震動", "Rumble strength": "震動強度",
    "Frame buffering": "畫面緩衝", "Up to one frame more display latency.": "顯示延遲最多增加一幀。",
    "Metal 4 pipelines": "Metal 4 管線", "Keeps a pipeline archive; uses more memory.": "保留管線快取，會使用較多記憶體。",
    "Pipeline prebuild": "預先建置管線", "The first start waits a few minutes for it, once.": "首次啟動需要多等幾分鐘（僅此一次）。",
    "Encode thread": "獨立編碼執行緒", "Hold frames when late": "延遲時保留畫格", "Performance HUD": "效能資訊（HUD）",
    "American English": "英文（美國）", "British English": "英文（英國）", "Japanese": "日文", "French": "法文", "German": "德文",
    "Latin American Spanish": "西班牙文（拉丁美洲）", "Spanish": "西班牙文", "Italian": "義大利文", "Dutch": "荷蘭文", "Canadian French": "法文（加拿大）",
    "Portuguese": "葡萄牙文", "Russian": "俄文", "Korean": "韓文", "Traditional Chinese": "繁體中文", "Simplified Chinese": "簡體中文", "Brazilian Portuguese": "葡萄牙文（巴西）",
    "Game memory pool": "遊戲記憶體", "Game default": "遊戲預設", "Auto": "自動",
    "Change it only if the picture or sound is missing; a wrong size can stop a game from starting.": "僅在畫面或聲音異常時調整；設定錯誤可能導致遊戲無法啟動。",
    // the launcher's own
    "Play": "開始遊戲", "Add players": "加入玩家", "Connect to Wi-Fi first": "請先連上 Wi-Fi",
    "Connect a controller, or scan the QR code with a phone.": "連接手把，或用手機掃描 QR code 加入。", "Version": "版本", "Set by an env file": "已固定", "Memory available": "可用記憶體",
    "Reset to tested defaults": "還原為建議設定", "Brings back all settings this game was tested with.": "將所有設定恢復為這款遊戲測試時使用的值。",
    "Open game folder": "打開遊戲資料夾", "Game list": "遊戲清單",
    "The app closes; tap its icon again to choose another game.": "App 會關閉，再點一次圖示就能選其他遊戲。", "Saves, env.txt and log.txt are here (Files app).": "存檔都在這裡（「檔案」App）。",
    "Motion controls": "體感操作（陀螺儀）",
    "The iPad's motion is player 1's while it plays on the iPad; a DualSense, DualShock 4 or Switch Pro controller's is its own player's.":
        "觸控遊玩時轉動 iPad；手把用自己的陀螺儀。",
    "Frame rate cap": "幀率上限", "30 fps runs cooler and saves battery; 60 fps is the most a game runs at.": "30 fps 較省電、機身較涼。",
    "Touch controls opacity": "觸控按鍵不透明度", "Touch controls size": "觸控按鍵大小",
    "Identify": "辨識", "Buzzes this player's controller or flashes its phone.": "讓這位玩家的手把震動或手機閃一下。",
    "Phone controllers": "手機手把", "Scan with a phone camera, or open in its browser:": "用手機相機掃描 QR Code，或在瀏覽器輸入：",
    "Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.": "請將 iPad 連上 Wi-Fi（或開啟個人熱點），手機才能加入。",
    "Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player.":
        "連接同一個 Wi-Fi 的手機都能成為獨立玩家，依連線順序取得下一個空的編號，最多 8 位。重新整理頁面會保留原本的玩家編號。",
    "Players": "玩家", "Controller": "手把", "Phone on Wi-Fi": "手機（Wi-Fi）", "phone": "手機", "Not playing": "未使用", "Add": "加入", "Remove": "移除",
    "Move to": "換到", "On": "開", "Off": "關", "Switch mode": "切換模式", "Button layout": "按鍵配置",
    "No controller or phone yet. Connect a controller, or scan the QR code on the left with a phone.": "尚未連接手把或手機。可連接藍牙手把，或用手機掃描左側的 QR Code。",
    "The iPad's touch controls also play as player 1. Each player keeps its own button layout. A removed phone can join again from its page; a removed controller from here.":
        "沒有連接任何裝置時，iPad 觸控按鍵為 1P。每位玩家的按鍵配置會分別記住。已移除的手機可在手機頁面重新加入，手把則在這裡點「加入」。",
    "Player 1's controller: A on a player, then left and right pick what to change. Players 2 to 8: left and right on your own row pick the layout or Identify, A to use it.":
        "1P 手把：在玩家那一列按 A，再用左右選要調整的項目。2P 以後：用左右在自己那一列選按鍵配置或震動，按 A 執行。",
    // save slots (SaveSlots.swift)
    "Saves": "存檔", "Save in use": "使用中的存檔", "Switch saves": "切換存檔", "Choose a save": "選擇存檔",
    "New empty save": "新增空白存檔", "Copy this save": "複製目前的存檔",
    "Rename this save": "重新命名這份存檔",
    "Enter the new name on the iPad": "請在 iPad 上輸入新名稱", "Delete a save": "刪除存檔", "Delete": "刪除", "Cancel": "取消", "Rename": "重新命名", "Name": "名稱",
    "Save %d": "存檔 %d", "%@ (copy)": "%@（副本）", "Delete \"%@\"?": "要刪除「%@」嗎？",
    "Create an empty save?": "要新增空白存檔嗎？",
    "The new empty save will become the save in use. Your existing saves will be kept.": "新增的空白存檔會成為使用中的存檔。原有存檔會保留。",
    "Copy \"%@\"?": "要複製「%@」嗎？",
    "The copy will be saved separately. Your choice of save will stay the same.": "副本會另外保存，目前使用的存檔維持原選擇。",
    "Create": "新增", "Copy": "複製",
    "This save will be deleted from the iPad. If you backed it up with PadSwitch, you can restore it from your PC.": "這份存檔會從 iPad 刪除。若已透過 PadSwitch 備份，可從電腦還原。",
    "Each save is kept apart. The game loads the one in use; a new empty save starts the game from the beginning, and the others stay as they are. Switch Pad's save backups take every save along.":
        "每份存檔分開保存，遊戲讀的是「使用中的存檔」。新增空白存檔會從頭開始玩，其他存檔不會被動到。Switch Pad 備份存檔時每一份都會一起備份。",
    "Could not switch saves": "切換存檔失敗", "Could not add a save": "新增存檔失敗", "Could not copy the save": "複製存檔失敗",
    "Could not rename the save": "重新命名失敗", "Could not delete the save": "刪除存檔失敗",
]
// English as shown: settings.tsv's labels and notes (and the strings above, which are the keys) rewritten for the screen; a string not listed is shown as it is
private let enText: [String: String] = [
    "Frame-rate counter": "Show frame rate", "Game rumble": "Rumble", "Touch feedback": "Haptic feedback on touch", "Performance HUD": "Performance overlay (HUD)",
    "Uses more GPU time and can increase heat.": "Uses more GPU time; the device may run warmer.", "Up to one frame more display latency.": "Adds up to one frame of display latency.",
    "Keeps a pipeline archive; uses more memory.": "Keeps a pipeline cache, which uses more memory.", "The first start waits a few minutes for it, once.": "The first launch takes a few extra minutes, once.",
    "Game memory pool": "Game memory",
    "Change it only if the picture or sound is missing; a wrong size can stop a game from starting.": "Only change this if graphics or sound are missing. A wrong value can keep the game from starting.",
    "30 fps runs cooler and saves battery; 60 fps is the most a game runs at.": "30 fps runs cooler and saves battery.",
    "Memory available": "Available memory", "Reset to tested defaults": "Restore recommended settings", "Brings back all settings this game was tested with.": "Returns every setting to the values this game was tested with.",
    "Saves, env.txt and log.txt are here (Files app).": "Your saves are here (Files app).",
    "Motion controls": "Motion controls (gyro)",
    "The iPad's motion is player 1's while it plays on the iPad; a DualSense, DualShock 4 or Switch Pro controller's is its own player's.":
        "Tilt the iPad when playing by touch; controllers use their own gyro.",

    "Scan with a phone camera, or open in its browser:": "Scan with your phone's camera, or open this address in its browser:",
    "Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.": "Connect this iPad to Wi-Fi (or turn on Personal Hotspot) so phones can join.",
    "Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player.":
        "Any phone on the same Wi-Fi can join as its own player, taking the next free player number, up to 8 players. Reloading the page keeps its player number.",
    "No controller or phone yet. Connect a controller, or scan the QR code on the left with a phone.": "No controllers or phones connected. Pair a Bluetooth controller, or scan the QR code on the left with a phone.",
    "The iPad's touch controls also play as player 1. Each player keeps its own button layout. A removed phone can join again from its page; a removed controller from here.":
        "With no controller or phone connected, the iPad's touch controls play as Player 1. Each player's button layout is remembered. A removed phone can rejoin from its page; a removed controller from here.",
    "Phone on Wi-Fi": "Phone (Wi-Fi)", "Not playing": "Not playing",
]
private func tr(_ s: String) -> String { zhHant ? zhText[s] ?? s : enText[s] ?? s }

// Players (shell_players.m): who plays which player, from the physical controllers and the phones, at the top of the launcher. The list comes from the
// DMPlayersChanged notification and the changes go back as DMPlayersCommand (swap, kick, layout, add), so this file needs no C header
struct PlayerRow: Identifiable, Equatable { let player, kind: Int; let label, name: String; let xbox: Bool; var id: Int { player } }
struct RemovedPad: Identifiable, Equatable { let index: Int; let label: String; var id: Int { index } }
final class PlayersModel: ObservableObject {
    @Published var players: [PlayerRow] = []
    @Published var removed: [RemovedPad] = []
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: Notification.Name("DMPlayersChanged"), object: nil, queue: .main) { [weak self] n in self?.update(n.userInfo) }
        send(["op": "refresh"])
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    private func update(_ u: [AnyHashable: Any]?) {   // only what changed is assigned: an unchanged list must not redraw the screen
        let players: [PlayerRow] = ((u?["players"] as? [[Any]]) ?? []).compactMap { a in
            guard a.count >= 5, let p = a[0] as? Int, let k = a[1] as? Int, let l = a[2] as? String, let n = a[3] as? String, let x = a[4] as? Int else { return nil }
            return PlayerRow(player: p, kind: k, label: l, name: n, xbox: x != 0)
        }
        let removed: [RemovedPad] = ((u?["removed"] as? [[Any]]) ?? []).compactMap { a in
            guard a.count >= 2, let i = a[0] as? Int, let l = a[1] as? String else { return nil }
            return RemovedPad(index: i, label: l)
        }
        let sorted = players.sorted { $0.player < $1.player }   // P1 at the top, and after any move too
        if sorted != self.players { self.players = sorted }
        if removed != self.removed { self.removed = removed }
    }
    func send(_ u: [String: Any]) { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: u) }
}

// Which players just pressed something (shell_players.m posts DMPlayerActive): their badge lights up for a moment, so each one sees which row is theirs.
// Apart from PlayersModel, so a press redraws only the badges
final class ActivityModel: ObservableObject {
    @Published var lit: Set<Int> = []
    private var token: NSObjectProtocol?
    private var generation: [Int: Int] = [:]
    init() {
        token = NotificationCenter.default.addObserver(forName: Notification.Name("DMPlayerActive"), object: nil, queue: .main) { [weak self] n in
            guard let self, let p = n.userInfo?["p"] as? Int else { return }
            let g = (generation[p] ?? 0) + 1; generation[p] = g
            if !lit.contains(p) { lit.insert(p) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in if self?.generation[p] == g { self?.lit.remove(p) } }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
private struct PlayerBadge: View {
    let player: Int
    @EnvironmentObject var activity: ActivityModel
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)
    var body: some View {
        let on = activity.lit.contains(player), color = playerColors[(player - 1) % playerColors.count]
        Text("P\(player)").font(.ds(.headline, .heavy, k: k).monospacedDigit()).foregroundStyle(.black.opacity(0.85)).minimumScaleFactor(0.5).lineLimit(1)
            .frame(width: 44 * k, height: 36 * k).background(RoundedRectangle(cornerRadius: DS.tileRadius * k, style: .continuous).fill(color))
            .overlay(RoundedRectangle(cornerRadius: DS.tileRadius * k, style: .continuous).stroke(Color.white, lineWidth: on ? 3 * k : 0))
            .shadow(color: color, radius: on ? 12 * k : 0)
            .scaleEffect(on ? 1.15 : 1)
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

// Each player's colour, P1 to P8 (docs/DESIGN.zh-TW.md): the same in the picker, the launcher, the in-game menu (front_ios.m) and on the phone page
private func rgb(_ v: UInt32) -> Color { Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255) }
let playerColors: [Color] = ([0x0A84FF, 0xFF453A, 0x30D158, 0xFFD60A, 0xBF5AF2, 0xFF9F0A, 0x40C8E0, 0xFF375F] as [UInt32]).map(rgb)
func controllerIcon(_ label: String) -> String {
    let l = label.lowercased()
    return l.contains("xbox") ? "logo.xbox" : l.contains("dualsense") || l.contains("dualshock") ? "logo.playstation" : "gamecontroller.fill"
}

private func playerTitle(_ p: PlayerRow) -> String { p.kind == 2 ? (zhHant ? "\(p.label) " + tr("phone") : "\(p.label) phone") : p.label }

// Switch or Xbox button layout: two words in a rounded square, the picked one on white (a segmented control keeps its small type when the text grows)
private struct LayoutSwitch: View {
    let xbox: Bool
    let set: (Bool) -> Void
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)
    @Environment(\.tenFoot) private var tenFoot
    @Namespace private var plate
    var body: some View {
        // two halves of one width at the row's chip height (36), the white plate sliding between them: the two words' own widths made it lopsided and
        // shorter than the buttons beside it
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { x in
                Text(x ? "Xbox" : "Switch")
                    .font(tenFoot ? .system(size: 19 * k, weight: .semibold) : .ds(.subheadline, .semibold, k: k))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .foregroundStyle(x == xbox ? Color.black : Color.white.opacity(0.75))
                    .frame(width: (tenFoot ? 72 : 64) * k, height: (tenFoot ? 34 : 30) * k)
                    .background {
                        if x == xbox { RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(Color.white).matchedGeometryEffect(id: "plate", in: plate) }
                    }
                    .contentShape(Rectangle()).onTapGesture { if x != xbox { set(x) } }
            }
        }
        .padding(3 * k)
        .background(RoundedRectangle(cornerRadius: DS.tileRadius * k, style: .continuous).fill(DS.chip))
        .animation(DS.spring, value: xbox)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Button layout")).accessibilityValue(xbox ? "Xbox" : "Switch")
        .accessibilityAdjustableAction { _ in set(!xbox) }
    }
}
// A player row's small buttons: an icon (and Move to's words) on a rounded square plate, all the same height
private extension View {
    func chipButton(_ color: Color = .white, k: CGFloat) -> some View {
        self.font(.ds(.subheadline, .semibold, k: k)).foregroundStyle(color)
            .padding(.horizontal, 10 * k).frame(minWidth: 40 * k, minHeight: 36 * k)
            .background(RoundedRectangle(cornerRadius: DS.tileRadius * k, style: .continuous).fill(DS.chip))
    }
}

private struct PlayerRowView: View {
    let p: PlayerRow
    @ObservedObject var m: PlayersModel
    @EnvironmentObject var nav: NavModel
    @Environment(\.tenFoot) private var tenFoot   // on a TV: no second line, Move to as its icon
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)

    private var phone: Bool { p.kind == 2 }
    private var title: String { playerTitle(p) }
    private func moveText(_ n: Int) -> String {
        guard let other = m.players.first(where: { $0.player == n }) else { return "P\(n)" }
        return zhHant ? "P\(n)（和 \(playerTitle(other)) 交換）" : "P\(n) (swap with \(playerTitle(other)))"
    }

    var body: some View {
        HStack(spacing: 12 * k) {
            PlayerBadge(player: p.player)
            Image(systemName: phone ? "iphone" : controllerIcon(p.label)).font(.ds(.title2, k: k)).frame(width: 32 * k)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).minimumScaleFactor(0.7)
                if !tenFoot { Text(tr(phone ? "Phone on Wi-Fi" : "Controller")).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8 * k)
            LayoutSwitch(xbox: p.xbox) { m.send(["op": "layout", "p": p.player, "xbox": $0 ? 1 : 0]) }
            .modifier(NavPart(player: p.player, part: 0))
            .layoutPriority(1)
            Button { m.send(["op": "identify", "p": p.player]) } label: {
                Image(systemName: "wave.3.right").chipButton(k: k)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(tr("Identify"))
            .accessibilityHint(tr("Buzzes this player's controller or flashes its phone."))
            .modifier(NavPart(player: p.player, part: 1))
            Menu {
                ForEach(1...8, id: \.self) { n in
                    if n != p.player { Button(moveText(n)) { m.send(["op": "swap", "a": p.player, "b": n]) } }
                }
            } label: {   // while player 1 picks the number: "Move to 3P"
                let n = nav.focus == "p\(p.player)" ? nav.moveTo : nil
                HStack(spacing: 6 * k) {
                    Image(systemName: "arrow.left.arrow.right")
                    if !tenFoot || n != nil { Text((tenFoot ? "" : tr("Move to")) + (n.map { (tenFoot ? "" : " ") + "P\($0)" } ?? "")).lineLimit(1) }
                }
                .chipButton(k: k)
            }
            .accessibilityLabel(tr("Move to"))
            .modifier(NavPart(player: p.player, part: 2))
            Button(role: .destructive) { m.send(["op": "kick", "p": p.player]) } label: {
                Image(systemName: "xmark").chipButton(Color(red: 1, green: 0.271, blue: 0.227), k: k)   // #FF453A
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(tr("Remove"))
            .modifier(NavPart(player: p.player, part: 3))
        }
    }
}

private struct PlayersSection: View {
    @ObservedObject var m: PlayersModel   // the launcher's, which its controller navigation also uses
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)

    var body: some View {
        Section {
            if m.players.isEmpty && m.removed.isEmpty {
                Text(tr("Connect a controller, or scan the QR code with a phone.")).foregroundStyle(.secondary).listRowBackground(rowPlate)
            }
            ForEach(m.players) { PlayerRowView(p: $0, m: m).nav("p\($0.player)") }
            ForEach(m.removed) { r in
                HStack(spacing: 12 * k) {
                    Image(systemName: controllerIcon(r.label)).font(.ds(.title2, k: k)).frame(width: 44 * k).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.label)
                        Text(tr("Not playing")).font(.ds(.footnote, k: k)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Add")) { m.send(["op": "add", "index": r.index]) }.buttonStyle(.borderless)
                }
                .nav("r\(r.index)")
            }
        } header: {
            Text(tr("Players")).font(.ds(.footnote, .semibold, k: k))
        }
    }
}

// Phone controllers (phone_pads.c): the address phones open, and a QR code of it. DM_PHONE_PADS_LIVE is the port the server listens on (unset when it is off or could not start);
// the address is this device's IPv4 address on Wi-Fi (en0), or on another interface that is up (a personal hotspot's bridge) when there is no Wi-Fi
func phonePadsURL() -> String? {
    guard let port = ProcessInfo.processInfo.environment["DM_PHONE_PADS_LIVE"] else { return nil }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var found: [String: String] = [:]
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let name = String(cString: i.ifa_name), addr = String(cString: host)
        if !addr.hasPrefix("169.254.") { found[name] = found[name] ?? addr }
    }
    guard let addr = found["en0"] ?? found.first(where: { $0.key.hasPrefix("bridge") || $0.key.hasPrefix("en") })?.value else { return nil }
    return "http://\(addr):\(port)/"
}

func qrImage(_ text: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = "M"
    // black on clear rather than black on white: the white around it comes from the view, so the code and its margin are one colour
    let fc = CIFilter.falseColor(); fc.inputImage = f.outputImage; fc.color0 = CIColor(red: 0, green: 0, blue: 0); fc.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
    guard let out = fc.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

private struct PhonePadsCard: View {   // under Play, in the launcher's left column
    @Environment(\.tenFoot) private var tenFoot   // on a TV the code is larger: it is scanned from the sofa
    @State private var url = phonePadsURL()
    @State private var qr: UIImage?   // made once per address, not on every redraw
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)

    var body: some View {
        Group {
            if tenFoot {
                VStack(spacing: 8 * k) {
                    qrTile(side: 168 * k)
                    joinDetails.frame(maxWidth: .infinity)
                }
                .multilineTextAlignment(.center)
            } else {
                HStack(spacing: 14 * k) {
                    qrTile(side: 96 * k)
                    joinDetails
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12 * k)
        .frame(maxWidth: .infinity)
        .glassCard(20 * k)
        .task {
            while !Task.isCancelled {   // the Wi-Fi address can change while the launcher is shown
                let now = phonePadsURL()
                if now != url || (qr == nil && now != nil) { url = now; qr = now.flatMap(qrImage) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder private func qrTile(side: CGFloat) -> some View {
        if let url, let qr {
            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                .frame(width: side, height: side)
                .padding(side * 0.14).background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14 * k, style: .continuous))
                .accessibilityLabel("QR code of \(url)")
        }
    }

    private var joinDetails: some View {
        VStack(alignment: tenFoot ? .center : .leading, spacing: 6 * k) {
            Label(tr("Add players"), systemImage: "qrcode").font(.ds(.headline, k: k))
            if let url {
                Text(url).font(.ds(.footnote, design: .monospaced, k: k))
                    .foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                    .lineLimit(tenFoot ? 2 : 1).minimumScaleFactor(tenFoot ? 0.78 : 0.5)
                    .padding(.horizontal, 8 * k).padding(.vertical, 4 * k)
                    .background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(DS.chip))
            } else {
                Text(tr("Connect to Wi-Fi first")).font(.ds(.footnote, k: k)).foregroundStyle(.secondary)
            }
        }
    }
}

private extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

// On the TV a choice is its name and its value between arrows, on one line as on a console's settings (left and right change it; the TV is not touched).
// A menu picker there stacks its value under the name once the text is this large, which made every row two lines tall
private struct TVChoice: View {
    let title: String, value: String
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)
    var body: some View {
        HStack(spacing: 12 * k) {
            Text(title).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 12 * k)
            HStack(spacing: 10 * k) {
                Image(systemName: "chevron.left").font(.ds(.footnote, .bold, k: k)).foregroundStyle(.secondary)
                Text(value).font(.ds(.body, .semibold, k: k)).lineLimit(1)
                Image(systemName: "chevron.right").font(.ds(.footnote, .bold, k: k)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12 * k).padding(.vertical, 6 * k)
            .background(RoundedRectangle(cornerRadius: DS.tileRadius * k, style: .continuous).fill(DS.chip))
        }
    }
}

private struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fromFile.contains(s.env) }
    private var note: String {
        locked ? (s.note.isEmpty ? "" : tr(s.note) + " · ") + tr("Set by an env file") : tr(s.note)
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { "\(Int((rangeValue.wrappedValue * 100).rounded())) %" }
    // memory (DM_APP_POOL): a slider in GB writing whole MiB as hex bytes; "-" is the package's own value, which the bundle's dm/env.txt put in the environment
    private func gb(_ v: String) -> Double? {
        let t = v.lowercased(); guard let n = t.hasPrefix("0x") ? UInt64(t.dropFirst(2), radix: 16) : UInt64(t) else { return nil }
        return Double(n) / 1073741824
    }
    private var memoryGB: Binding<Double> {
        Binding(get: {
                    let v = m.values[s.env] ?? s.def
                    if v == "-", let a = m.memory { return Double(a.pick) / 1073741824 }   // automatic: the size the launcher picked
                    return gb(v == "-" ? (ProcessInfo.processInfo.environment[s.env] ?? "") : v) ?? s.max ?? 3.2
                },
                set: { m.values[s.env] = String(format: "0x%llX", UInt64(($0 * 1024).rounded()) << 20) })
    }
    private var memoryIsDefault: Bool { (m.values[s.env] ?? s.def) == "-" }
    private var memoryDefaultLabel: String { tr(m.memory != nil ? "Auto" : "Game default") }   // "-" is automatic when the launcher can pick (MemoryAuto)
    private var memoryText: String { String(format: "%.1f GB", memoryGB.wrappedValue) + (memoryIsDefault ? " · " + memoryDefaultLabel : "") }   // VoiceOver's value
    // What automatic memory knows, under the slider: what the last run told and why the size is what it is
    private var memoryAutoNote: (text: String, warn: Bool)? {
        guard memoryIsDefault, !locked, let a = m.memory else { return nil }
        func g(_ v: UInt64) -> String { String(format: "%.1f GB", Double(v) / 1073741824) }
        let now = g(a.pick)
        if a.exhausted {
            return (zhHant ? "各種記憶體大小都試過了還是打不開，應該不是記憶體的問題；先用回遊戲預設 \(now)。"
                           : "Every memory size failed, so memory is likely not the problem; back to the game's default \(now).", true)
        }
        if let l = a.last {
            let was = g(l.pool)
            switch l.outcome {
            case .worked: return (zhHant ? "\(now) 已確認可以正常執行。" : "\(now) is confirmed to work.", false)
            case .tooBig: return (zhHant ? "上次 \(was) 被 iOS 以記憶體不足關掉，這次自動改用 \(now)。" : "Last time iOS closed the game at \(was) for lack of memory; trying \(now) now.", true)
            case .tooSmall: return (zhHant ? "上次 \(was) 遊戲要不到記憶體而中止，這次自動改用 \(now)。" : "Last time the game ran out of memory at \(was); trying \(now) now.", true)
            case .maybeSmall: return (zhHant ? "上次 \(was) 遊戲自己中止，可能是記憶體不夠，這次先試 \(now)。" : "Last time the game stopped itself at \(was), maybe for memory; trying \(now) now.", true)
            case .notMemory: return (zhHant ? "上次 \(was) 閃退，但看起來不是記憶體造成的，所以記憶體不變。" : "Last time the game crashed at \(was), but not for memory, so the size stays.", true)
            }
        }
        if a.confirmed { return (zhHant ? "\(now) 已確認可以正常執行。" : "\(now) is confirmed to work.", false) }
        return (zhHant ? "打不開而且是記憶體造成的話，下次會自動換一個大小。" : "If the game fails to start for memory, the next start tries another size.", false)
    }

    @Environment(\.tenFoot) private var tenFoot   // on a TV only the names: the notes are too small to read from the sofa
    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(s.label))
            if !note.isEmpty && !tenFoot { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice" where tenFoot:
                let v = m.values[s.env] ?? s.def
                TVChoice(title: tr(s.label), value: (s.options ?? []).first { $0[0] == v }.map { tr($0[1]) } ?? v)
            // on the TV a slider or a switch is a value between arrows too: the controls themselves keep their small iPad size there
            case "range" where tenFoot:
                TVChoice(title: tr(s.label), value: percentage)
            case "memory" where tenFoot:
                TVChoice(title: tr(s.label), value: String(format: "%.1f GB", memoryGB.wrappedValue) + (memoryIsDefault ? " · " + memoryDefaultLabel : ""))
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { Text(tr($0[1])).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(tr(s.label))
                        .accessibilityValue(percentage)
                }
            case "memory":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        // the size, then "Game default" in the same place: a label at the default, a button that goes back to it otherwise
                        Text(String(format: "%.1f GB", memoryGB.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                        if memoryIsDefault || locked { Text(memoryDefaultLabel).foregroundStyle(.secondary).opacity(memoryIsDefault ? 1 : 0) }
                        else { Button(memoryDefaultLabel) { m.values[s.env] = "-" }.buttonStyle(.borderless) }
                    }
                    Slider(value: memoryGB, in: (s.min ?? 0.5)...(s.max ?? 3.2), step: s.step ?? 0.1)
                        .accessibilityLabel(tr(s.label))
                        .accessibilityValue(memoryText)
                    if let n = memoryAutoNote { Text(n.text).font(.footnote).foregroundStyle(n.warn ? Color.orange : Color.secondary) }
                }
            default:
                if tenFoot {
                    TVChoice(title: tr(s.label), value: (m.values[s.env] ?? s.def) == s.onValue ? tr("On") : tr("Off"))
                } else {
                    Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                        settingLabel
                    }
                }
            }
        }
        .disabled(locked)
    }
}

// Player 1's controller or phone on the launcher (shell_players.m posts DMLauncherInput): up and down move a highlight over the rows, left goes to Play (right comes
// back), A uses the highlighted row in place: a switch flips; a choice or a slider takes left and right until A or B; a player's row lets left and right pick its
// layout, Identify, Move to (A, then left and right pick the number) or Remove. B goes back one step (or to Play) and + starts the game. Each other player has a
// highlight of its own on its own row at the same time: left and right pick its layout or Identify, A uses it, B hides it. Touch works as before
private final class NavModel: ObservableObject {
    @Published var focus = "play"
    @Published var editing = false   // the highlighted choice or slider takes left and right
    @Published var part: Int?        // on a player's row: 0 layout, 1 Identify, 2 Move to, 3 Remove
    @Published var moveTo: Int?      // Move to: the player number picked so far
    @Published var own: [Int: Int] = [:]   // players 2 to 8: the control each one picked on its own row (0 layout, 1 Identify)
    @Published var saveConfirmation: SaveConfirmation?
    @Published var saveSelection: SaveSelection?
    @Published var selectedSaveID: Int?
    @Published var confirmFocused = false
    @Published var nameEntryOnIPad = false
    @Published var newSaveName = ""
    var list = ""                    // the row left for Play, where right goes back to
    func reset() { editing = false; part = nil; moveTo = nil }
}
private struct NavHighlight: ViewModifier {
    let id: String
    @EnvironmentObject var nav: NavModel
    func body(content: Content) -> some View {
        let on = nav.focus == id
        content.id(id).listRowBackground(on ? DS.accent.opacity(nav.editing ? 0.6 : 0.35) : rowPlate)
    }
}
private extension View { func nav(_ id: String) -> some View { modifier(NavHighlight(id: id)) } }
// A row's plate over the launcher's blurred backdrop (a row without a highlight of its own takes it with .listRowBackground)
private let rowPlate = Color.white.opacity(0.07)
// A button that gives a little while pressed (Play)
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
private struct NavPart: ViewModifier {   // a ring around the player row's control player 1 picked
    let player, part: Int
    @EnvironmentObject var nav: NavModel
    @Environment(\.uiK) private var k   // GamePicker.swift: on a TV every size is its ten-foot size times k (laid out at the TV's own size)
    func body(content: Content) -> some View {
        content.overlay {
            if nav.focus == "p\(player)" && nav.part == part { RoundedRectangle(cornerRadius: 10 * k).stroke(Color.white, lineWidth: 2.5 * k).padding(-5 * k) }
            else if player > 1 && nav.own[player] == part {   // the player's own, in its colour
                RoundedRectangle(cornerRadius: 10 * k).stroke(playerColors[(player - 1) % playerColors.count], lineWidth: 2.5 * k).padding(-5 * k)
            }
        }
    }
}
private struct NavItem { let id: String; var slider = false; var activate: () -> Void = {}; var adjust: (Int) -> Void = { _ in } }

private extension LauncherModel {
    // One step of a setting from a controller (d -1 or +1): a toggle flips, a choice moves through its options (wrapping around), a slider moves by its step
    func step(_ s: Setting, _ d: Int) {
        let v = values[s.env] ?? s.def
        switch s.kind {
        case "choice":
            guard let o = s.options, !o.isEmpty else { return }
            let i = o.firstIndex { $0[0] == v } ?? 0
            values[s.env] = o[((i + d) % o.count + o.count) % o.count][0]
        case "range":
            let lo = s.min ?? 0, hi = s.max ?? 1, st = s.step ?? 0.05
            values[s.env] = String(format: "%.2f", Swift.min(hi, Swift.max(lo, (Double(v) ?? hi) + Double(d) * st)))
        case "memory":   // "-" moves from the automatic size, else the package's own value
            let t = (v == "-" ? memory.map { MemoryAuto.hex($0.pick) } ?? ProcessInfo.processInfo.environment[s.env] ?? "" : v).lowercased()
            let lo = s.min ?? 0.5, hi = s.max ?? 3.2, st = s.step ?? 0.1
            let g = (t.hasPrefix("0x") ? UInt64(t.dropFirst(2), radix: 16) : UInt64(t)).map { Double($0) / 1073741824 } ?? hi
            let n = Swift.min(hi, Swift.max(lo, (g / st).rounded() * st + Double(d) * st))
            values[s.env] = String(format: "0x%llX", UInt64((n * 1024).rounded()) << 20)
        default: values[s.env] = v == s.onValue ? s.offValue : s.onValue
        }
    }
}

// Shell settings every game has (not from launcher.json): motion controls (shell_motion.c, read while the game runs), the touch controls' opacity and size (DmGamepad.m,
// at once) and a frame-rate cap (DM_FPS, read when the game starts). Kept in UserDefaults; an env file's DM_GYRO or DM_FPS is shown and kept
@_silgen_name("shell_motion_enable") private func shellMotionEnable(_ on: Int32)
@_silgen_name("dm_touch_style") private func dmTouchStyle(_ opacity: Float, _ scale: Float)
private final class ShellSettings: ObservableObject {
    private let fromFile = Set((ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
    @Published var gyro: Bool { didSet { save() } }   // each kept as soon as changed, as LauncherModel's
    @Published var fps: Int { didSet { save() } }   // 30 or 60: 60 leaves the game its own rate, which is 60 at most
    @Published var touchOpacity: Double { didSet { style(); save() } }
    @Published var touchScale: Double { didSet { style(); save() } }
    var gyroLocked: Bool { fromFile.contains("DM_GYRO") }
    var fpsLocked: Bool { fromFile.contains("DM_FPS") }
    init() {
        let env = ProcessInfo.processInfo.environment, d = gameDefaults
        gyro = fromFile.contains("DM_GYRO") ? env["DM_GYRO"] != "0" : d.object(forKey: "launcher.DM_GYRO") as? Bool ?? true
        fps = fromFile.contains("DM_FPS") ? (env["DM_FPS"] == "30" ? 30 : 60) : (d.bool(forKey: "launcher.DM_FPS30") ? 30 : 60)
        touchOpacity = d.object(forKey: "launcher.touchOpacity") as? Double ?? 1
        touchScale = d.object(forKey: "launcher.touchScale") as? Double ?? 1
        style()
    }
    private func style() { dmTouchStyle(Float(touchOpacity), Float(touchScale)) }
    private func save() {
        let d = gameDefaults
        d.set(touchOpacity, forKey: "launcher.touchOpacity"); d.set(touchScale, forKey: "launcher.touchScale")
        if !gyroLocked { d.set(gyro, forKey: "launcher.DM_GYRO") }
        if !fpsLocked { d.set(fps == 30, forKey: "launcher.DM_FPS30") }
    }
    func apply() {
        save()
        if !gyroLocked { shellMotionEnable(gyro ? 1 : 0) }
        if !fpsLocked { if fps == 30 { setenv("DM_FPS", "30", 1) } else { unsetenv("DM_FPS") } }
        fputs("launcher: motion controls \(gyro ? "on" : "off"), frame rate cap \(fps) fps, touch controls \(Int(touchOpacity * 100)) % opaque at \(Int(touchScale * 100)) % size\n", stderr)
    }
}
private func noteLabel(_ title: String, _ note: String) -> some View { NoteLabel(title: title, note: note) }
private struct NoteLabel: View {   // a setting's name and its note (left out on a TV, as SettingRow's)
    let title: String, note: String
    @Environment(\.tenFoot) private var tenFoot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(title))
            if !tenFoot { Text(tr(note)).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
// The rows: frame rate in the Game section, the rest in Controls
private struct GyroRow: View {
    @ObservedObject var shell: ShellSettings
    @Environment(\.tenFoot) private var tenFoot
    var body: some View {
        if tenFoot { TVChoice(title: tr("Motion controls"), value: shell.gyro ? tr("On") : tr("Off")) } else { toggle }
    }
    private var toggle: some View {
        Toggle(isOn: $shell.gyro) {
            noteLabel("Motion controls", "The iPad's motion is player 1's while it plays on the iPad; a DualSense, DualShock 4 or Switch Pro controller's is its own player's.")
        }
        .disabled(shell.gyroLocked)
    }
}
private struct FpsRow: View {
    @ObservedObject var shell: ShellSettings
    @Environment(\.tenFoot) private var tenFoot
    var body: some View {
        if tenFoot { TVChoice(title: tr("Frame rate cap"), value: "\(shell.fps) fps") } else { menu }
    }
    private var menu: some View {
        Picker(selection: $shell.fps) {
            Text("30 fps").tag(30)
            Text("60 fps").tag(60)
        } label: {
            noteLabel("Frame rate cap", "30 fps runs cooler and saves battery; 60 fps is the most a game runs at.")
        }
        .pickerStyle(.menu)
        .disabled(shell.fpsLocked)
    }
}
private struct TouchStyleRow: View {   // opacity or size of the touch controls, a slider in percent
    @ObservedObject var shell: ShellSettings
    let size: Bool
    var body: some View {
        let value = size ? $shell.touchScale : $shell.touchOpacity
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr(size ? "Touch controls size" : "Touch controls opacity"))
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: size ? 0.7...1.3 : 0.2...1, step: 0.05)
                .accessibilityLabel(tr(size ? "Touch controls size" : "Touch controls opacity"))
        }
    }
}

private enum SaveConfirmation: Equatable {
    case create
    case copy(SaveSlot)
    case rename(SaveSlot)
    case delete(SaveSlot)

    var title: String {
        switch self {
        case .create: tr("Create an empty save?")
        case .copy(let slot): tr("Copy \"%@\"?").replacingOccurrences(of: "%@", with: slot.name)
        case .rename: tr("Rename this save")
        case .delete(let slot): tr("Delete \"%@\"?").replacingOccurrences(of: "%@", with: slot.name)
        }
    }

    var message: String {
        switch self {
        case .create: tr("The new empty save will become the save in use. Your existing saves will be kept.")
        case .copy: tr("The copy will be saved separately. Your choice of save will stay the same.")
        case .rename: ""
        case .delete: tr("This save will be deleted from the iPad. If you backed it up with PadSwitch, you can restore it from your PC.")
        }
    }

    var action: String {
        switch self {
        case .create: tr("Create")
        case .copy: tr("Copy")
        case .rename: tr("Rename")
        case .delete: tr("Delete")
        }
    }

    var role: ButtonRole? {
        if case .delete = self { return .destructive }
        return nil
    }
}

private enum SaveSelection: Equatable {
    case use, delete

    var title: String { tr(self == .use ? "Choose a save" : "Delete a save") }
}

// The launcher handles controller buttons itself. A native List button or menu can receive the
// same press through UIKit focus even when the launcher has highlighted a different row.
private extension View {
    func saveTap(_ label: String, perform: @escaping () -> Void) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: perform)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(label)) { perform() }
    }
}

private struct SaveSlotsSection: View {
    @ObservedObject var s: SaveSlotsModel
    let request: (SaveConfirmation) -> Void
    let choose: (SaveSelection) -> Void
    @Environment(\.tenFoot) private var tenFoot
    @Environment(\.uiK) private var k

    var body: some View {
        Section {
            HStack {
                saveLabel("Switch saves", icon: "externaldrive.fill")
                    .layoutPriority(1)
                Spacer()
                Text(s.activeName).foregroundStyle(.secondary).lineLimit(1)
            }
            .saveTap(tr("Switch saves")) { choose(.use) }
            .nav("slot")
            saveAction("New empty save", icon: "plus.circle") { request(.create) }
                .nav("slotNew")
            saveAction("Copy this save", icon: "doc.on.doc") {
                request(.copy(SaveSlot(id: s.active, name: s.activeName)))
            }
            .nav("slotCopy")
            saveAction("Rename this save", icon: "pencil") {
                request(.rename(SaveSlot(id: s.active, name: s.activeName)))
            }
            .nav("slotRename")
            if s.slots.count > 1 {
                saveLabel("Delete a save", icon: "trash")
                    .foregroundStyle(.red)
                    .saveTap(tr("Delete a save")) { choose(.delete) }
                    .nav("slotDelete")
            }
        } header: {
            Text(tr("Saves")).font(.ds(.footnote, .semibold, k: k))
        } footer: {
            if let p = s.problem { Text(tr(p.what) + ": " + p.detail).foregroundStyle(.red) }
        }
    }

    private func saveAction(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        saveLabel(title, icon: icon)
            .foregroundStyle(tenFoot ? Color.white : Color.accentColor)
            .saveTap(tr(title), perform: perform)
    }

    @ViewBuilder private func saveLabel(_ title: String, icon: String) -> some View {
        if tenFoot {
            HStack(spacing: 10 * k) {
                Image(systemName: icon).font(.system(size: 22 * k, weight: .medium))
                    .frame(width: 36 * k, height: 36 * k)
                    .accessibilityHidden(true)
                Text(tr(title))
            }
            .padding(.leading, 6 * k)
            .padding(.vertical, 4 * k)
        } else {
            Label(tr(title), systemImage: icon)
        }
    }
}

private func openGameFolder() {   // this app's Documents in the Files app (shareddocuments: scheme)
    if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
       let url = URL(string: "shareddocuments://" + doc.path) { UIApplication.shared.open(url) }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    @ObservedObject var shell: ShellSettings
    @ObservedObject var nav: NavModel   // made by dm_show_launcher: the TV's copy in handheld mode follows the same highlight
    let play: () -> Void
    let back: (() -> Void)?   // a package of several games: back to the game picker (main.m), before the game starts
    @StateObject private var players = PlayersModel()
    @Environment(\.pregameMirror) private var mirror   // GamePicker.swift: the TV's copy shows, takes no input and posts nothing
    @StateObject private var activity = ActivityModel()
    @ObservedObject var saves: SaveSlotsModel
    @State private var nameAlert: UIAlertController?
    @State private var held: (key: String, task: Task<Void, Never>)?   // the direction player 1 holds, repeating
    @StateObject private var tv: TenFoot

    init(m: LauncherModel, shell: ShellSettings, nav: NavModel, saves: SaveSlotsModel,
         play: @escaping () -> Void, back: (() -> Void)?, onTV: Bool, screenScale: CGFloat = 1) {
        self.m = m
        self.shell = shell
        self.nav = nav
        self.saves = saves
        self.play = play
        self.back = back
        _tv = StateObject(wrappedValue: TenFoot(native: true, onTV: onTV, screenScale: screenScale))
    }

    var body: some View {
        GeometryReader { geometry in
            let k = tv.on ? TenFootStage.scale(geometry.size) : 1   // GamePicker.swift: the TV's size over 1920 x 1080 (the views inside get it as uiK)
            HStack(spacing: 0) {
                VStack(spacing: 16 * k) {
                    Spacer(minLength: 0)
                    if let icon = appIcon() {
                        let side: CGFloat = (tv.on ? 180 : 128) * k
                        Image(uiImage: tv.on ? tvIcon(icon, key: "launcher:" + (gameRoot?.path ?? "")) : icon).resizable().interpolation(.high).frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))   // the home screen's icon corner, as the picker's tiles
                            .overlay(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 18 * k, y: 10 * k)
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? tr("Game"))
                        .font(.ds(.title, .bold, k: k)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                    if let v = info("CFBundleShortVersionString") as? String, !v.isEmpty {
                        Text("v" + v).font(.ds(.footnote, .semibold, k: k)).foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 9 * k).padding(.vertical, 4 * k)
                            .background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(DS.chip))
                    }
                    playButton(k).padding(.top, 6 * k)
                    // on the TV the code joins the game's card in the middle (an empty middle under Play otherwise); on the iPad it sits at the bottom
                    if tv.on { Color.clear.frame(height: 24 * k) } else { Spacer(minLength: 8) }
                    if ProcessInfo.processInfo.environment["DM_PHONE_PADS_LIVE"] != nil { PhonePadsCard() }
                    if tv.on {
                        Spacer(minLength: 0)
                        KeyHint(key: "Home", text: tr("Switch mode"))   // GamePicker.swift; on the TV, the same in console and handheld mode
                            .font(.ds(.callout, k: k)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(20 * k)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                    if let back {
                        Button(action: back) {
                            Label(tr("Game list"), systemImage: "chevron.left").font(.ds(.headline, k: k)).foregroundStyle(.white)
                                .padding(.horizontal, 14 * k).padding(.vertical, 10 * k)
                                .background(RoundedRectangle(cornerRadius: 12 * k, style: .continuous).fill(DS.chip))
                        }
                        .buttonStyle(.plain).padding(16 * k)
                        .overlay { if nav.focus == "back" { RoundedRectangle(cornerRadius: 16 * k, style: .continuous).stroke(Color.white, lineWidth: 3 * k).padding(12 * k) } }
                    }
                    BackToTVButton().padding(.vertical, 16 * k).padding(.leading, back == nil ? 16 * k : 0)   // GamePicker.swift: when the picture was moved to the iPad
                    }
                }
                ScrollViewReader { proxy in
                List {
                    PlayersSection(m: players)
                    if saves.available {
                        SaveSlotsSection(s: saves, request: requestSaveConfirmation, choose: openSaveSelection)
                    }
                    ForEach(m.sections, id: \.self) { section in
                        Section {
                            // the Xbox button layout is each player's own now (the player list above); DM_PAD_BY_LABEL stays the default for a new controller
                            ForEach(m.settings.filter { $0.sectionTitle == section && $0.env != "DM_PAD_BY_LABEL" }) { SettingRow(s: $0, m: m).nav("s:" + $0.env) }
                            if section == "Game" { FpsRow(shell: shell).nav("fps") }
                            if section == "Controls" {
                                GyroRow(shell: shell).nav("gyro")
                                if !tv.on {   // the touch controls are the iPad's, in handheld mode
                                    TouchStyleRow(shell: shell, size: false).nav("touchOpacity")
                                    TouchStyleRow(shell: shell, size: true).nav("touchScale")
                                }
                            }
                        } header: {
                            Text(tr(section)).font(.ds(.footnote, .semibold, k: k))
                        }
                    }
                    Section {
                        Button { m.reset() } label: { Label(tr("Reset to tested defaults"), systemImage: "arrow.counterclockwise") }
                            .foregroundStyle(tv.on ? Color.white : Color.accentColor)
                            .disabled(!m.changed)
                            .nav("reset")
                        if !tv.on {   // the Files app opens on the iPad, not on the TV
                            Button(action: openGameFolder) { Label(tr("Open game folder"), systemImage: "folder") }
                                .nav("folder")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .font(.ds(.body, k: k))   // the rows' text: Dynamic Type's on the iPad, the TV's size there
                .environment(\.defaultMinListRowHeight, 44 * k)
                .scrollContentBackground(.hidden)   // the game's blurred icon shows through, as in the picker
                .contentMargins(.horizontal, 12 * k, for: .scrollContent)
                .onChange(of: nav.focus) { _, id in withAnimation { proxy.scrollTo(id == "play" ? "p1" : id, anchor: .center) } }
                }
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .background { backdrop }
        .dynamicTypeSize(tv.on ? .accessibility1 ... .accessibility1 : .xSmall ... .accessibility5)   // ten-foot: every text style grows together on a TV
        .environment(\.tenFoot, tv.on)
        .environmentObject(nav)
        .environmentObject(activity)
        .preferredColorScheme(.dark)
        .accessibilityHidden(nav.saveSelection != nil || nav.saveConfirmation != nil)
        .overlay {
            GeometryReader { geometry in
                let k = tv.on ? TenFootStage.scale(geometry.size) : 1
                if let confirmation = nav.saveConfirmation {
                    saveConfirmationPanel(confirmation, k: k)
                } else if let selection = nav.saveSelection {
                    saveSelectionPanel(selection, k: k)
                }
            }
            .allowsHitTesting(!mirror && (nav.saveConfirmation != nil || nav.saveSelection != nil))
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { if !mirror { navInput($0.userInfo) } }
        .onAppear { if !mirror { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) } }
        .onDisappear {
            held?.task.cancel()
            if !mirror { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 0]) }
        }
        .tenFoot(tv)
        .settleOnArrival()   // GamePicker.swift: one plain fade in
    }

    private func requestSaveConfirmation(_ confirmation: SaveConfirmation) {
        guard !mirror, nav.saveConfirmation == nil, nav.saveSelection == nil else { return }
        held?.task.cancel()
        held = nil
        nav.confirmFocused = false
        nav.saveConfirmation = confirmation
        if case .rename(let slot) = confirmation {
            nav.newSaveName = slot.name
            if tv.on { enterNameOnIPad(confirmation) }
        }
    }

    private func enterNameOnIPad(_ confirmation: SaveConfirmation) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication && $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController,
              root.presentedViewController == nil else { return }
        let alert = UIAlertController(title: confirmation.title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = tr("Name")
            field.text = nav.newSaveName
        }
        alert.addAction(UIAlertAction(title: tr("Cancel"), style: .cancel) { [weak nav] _ in
            nav?.nameEntryOnIPad = false
            nav?.saveConfirmation = nil
        })
        alert.addAction(UIAlertAction(title: confirmation.action, style: .default) { [weak alert, weak nav, weak saves] _ in
            guard let nav, nav.saveConfirmation == confirmation,
                  case .rename(let slot) = confirmation else { return }
            saves?.rename(slot.id, alert?.textFields?.first?.text ?? nav.newSaveName)
            nav.nameEntryOnIPad = false
            nav.saveConfirmation = nil
        })
        nav.nameEntryOnIPad = true
        nameAlert = alert
        root.present(alert, animated: true)
    }

    private func cancelSaveConfirmation() {
        nameAlert?.dismiss(animated: true)
        nameAlert = nil
        nav.nameEntryOnIPad = false
        nav.saveConfirmation = nil
    }

    private func confirmSaveAction(_ confirmation: SaveConfirmation) {
        guard nav.saveConfirmation == confirmation else { return }
        nameAlert = nil
        nav.nameEntryOnIPad = false
        nav.saveConfirmation = nil
        switch confirmation {
        case .create:
            saves.addEmpty()
        case .copy(let slot):
            guard saves.active == slot.id else { return }
            saves.duplicate(name: tr("%@ (copy)").replacingOccurrences(of: "%@", with: slot.name))
        case .rename(let slot):
            saves.rename(slot.id, nav.newSaveName)
        case .delete(let slot):
            saves.delete(slot.id)
        }
    }

    private func saveOptions(_ selection: SaveSelection) -> [SaveSlot] {
        selection == .use ? saves.slots : saves.slots.filter { $0.id != saves.active }
    }

    private func openSaveSelection(_ selection: SaveSelection) {
        guard !mirror, nav.saveSelection == nil, nav.saveConfirmation == nil,
              let first = saveOptions(selection).first else { return }
        held?.task.cancel()
        held = nil
        nav.selectedSaveID = selection == .use ? saves.active : first.id
        nav.saveSelection = selection
    }

    private func chooseSave(_ slot: SaveSlot, for selection: SaveSelection) {
        guard nav.saveSelection == selection else { return }
        nav.saveSelection = nil
        if selection == .use { saves.switchTo(slot.id) }
        else { requestSaveConfirmation(.delete(slot)) }
    }

    private func saveConfirmationPanel(_ confirmation: SaveConfirmation, k: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14 * k) {
                Text(confirmation.title).font(.ds(.headline, .bold, k: k)).accessibilityAddTraits(.isHeader)
                if !confirmation.message.isEmpty {
                    Text(confirmation.message).font(.ds(.subheadline, k: k)).foregroundStyle(.secondary)
                }
                if case .rename = confirmation {
                    if nav.nameEntryOnIPad || mirror {
                        Text(tr("Enter the new name on the iPad")).font(.ds(.subheadline, k: k)).foregroundStyle(.secondary)
                    } else {
                        TextField(tr("Name"), text: $nav.newSaveName).textFieldStyle(.roundedBorder)
                    }
                }
                if !nav.nameEntryOnIPad {
                    HStack(spacing: 8 * k) {
                        saveDecision(tr("Cancel"), selected: !nav.confirmFocused, k: k, action: cancelSaveConfirmation)
                        saveDecision(confirmation.action, selected: nav.confirmFocused, destructive: confirmation.role == .destructive, k: k) {
                            confirmSaveAction(confirmation)
                        }
                    }
                }
            }
            .padding(22 * k)
            .frame(maxWidth: (tv.on ? 575 : 420) * k)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20 * k))
            .padding(20 * k)
        }
    }

    private func saveDecision(_ label: String, selected: Bool, destructive: Bool = false, k: CGFloat, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.ds(.body, .semibold, k: k))
            .foregroundStyle(destructive && !selected ? Color.red : Color.white)
            .padding(10 * k)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? (destructive ? Color.red : DS.accent) : rowPlate,
                        in: RoundedRectangle(cornerRadius: 8 * k))
            .saveTap(label, perform: action)
    }

    private func saveSelectionPanel(_ selection: SaveSelection, k: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { nav.saveSelection = nil }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14 * k) {
                Text(selection.title).font(.ds(.headline, .bold, k: k)).accessibilityAddTraits(.isHeader)
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 4 * k) {
                            ForEach(saveOptions(selection)) { slot in
                                HStack {
                                    Text(slot.name)
                                    Spacer()
                                    if slot.id == saves.active { Image(systemName: "checkmark").accessibilityLabel(tr("Save in use")) }
                                }
                                .padding(10 * k)
                                .background(slot.id == nav.selectedSaveID ? DS.accent.opacity(0.45) : rowPlate,
                                            in: RoundedRectangle(cornerRadius: 8 * k))
                                .saveTap(slot.name) { chooseSave(slot, for: selection) }
                                .id(slot.id)
                            }
                        }
                    }
                    .frame(maxHeight: 240 * k)
                    .onChange(of: nav.selectedSaveID, initial: true) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
                Text(tr("Cancel")).foregroundStyle(Color.accentColor)
                    .padding(10 * k)
                    .saveTap(tr("Cancel")) { nav.saveSelection = nil }
            }
            .padding(20 * k)
            .frame(maxWidth: (tv.on ? 575 : 420) * k)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20 * k))
            .padding(20 * k)
        }
    }

    private func saveSelectionInput(_ selection: SaveSelection, _ key: String) {
        let options = saveOptions(selection)
        switch key {
        case "b": nav.saveSelection = nil
        case "a":
            if let slot = options.first(where: { $0.id == nav.selectedSaveID }) { chooseSave(slot, for: selection) }
        case "up", "down":
            guard let index = options.firstIndex(where: { $0.id == nav.selectedSaveID }) else { return }
            let next = Swift.max(0, Swift.min(options.count - 1, index + (key == "up" ? -1 : 1)))
            nav.selectedSaveID = options[next].id
        default: break
        }
    }

    // The game's icon blurred over black, as behind the picker's row
    private var backdrop: some View {
        ZStack {
            Color.black
            if let icon = appIcon(), let soft = blurredIcon(icon, key: "launcher:" + (gameRoot?.path ?? "")) {   // GamePicker.swift: blurred once, not on every frame
                Image(uiImage: soft).resizable().interpolation(.medium).scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .scaleEffect(1.4).opacity(0.45)
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // Play: a rounded rectangle in the accent colour (not a capsule), a white ring while player 1's highlight is on it; it gives a little when pressed
    func playButton(_ k: CGFloat) -> some View {
        let focused = nav.focus == "play"
        return Button(action: play) {
            Label(tr("Play"), systemImage: "play.fill").font(.ds(.title3, .semibold, k: k)).foregroundStyle(.white)
                .frame(maxWidth: 260 * k).frame(minHeight: 54 * k).padding(.vertical, 2 * k)
                .background(RoundedRectangle(cornerRadius: DS.rowRadius * k, style: .continuous).fill(DS.accent))
                .shadow(color: DS.accent.opacity(focused ? 0.6 : 0.35), radius: (focused ? 16 : 10) * k)
        }
        .buttonStyle(PressScale())
        .overlay { if focused { RoundedRectangle(cornerRadius: (DS.rowRadius + 6) * k, style: .continuous).stroke(Color.white, lineWidth: 3 * k).padding(-6 * k) } }
        .scaleEffect(focused ? 1.03 : 1)
        .animation(DS.spring, value: focused)
    }

    // ---- Player 1's controller ----
    private func playerPart(_ r: PlayerRow, _ part: Int) {   // A on a control of a player's row
        switch part {
        case 0: players.send(["op": "layout", "p": r.player, "xbox": r.xbox ? 0 : 1])
        case 1: players.send(["op": "identify", "p": r.player])
        case 2: nav.moveTo = r.player % 8 + 1
        default: nav.reset(); players.send(["op": "kick", "p": r.player])
        }
    }
    private func navItems() -> [NavItem] {   // the rows in screen order (Play is apart); a setting an env file set is skipped
        var items: [NavItem] = []
        for r in players.players { items.append(NavItem(id: "p\(r.player)", activate: { nav.part = 0 })) }
        for r in players.removed { items.append(NavItem(id: "r\(r.index)", activate: { players.send(["op": "add", "index": r.index]) })) }
        if saves.available {
            items.append(NavItem(id: "slot", activate: { openSaveSelection(.use) }))
            items.append(NavItem(id: "slotNew", activate: { requestSaveConfirmation(.create) }))
            items.append(NavItem(id: "slotCopy", activate: {
                requestSaveConfirmation(.copy(SaveSlot(id: saves.active, name: saves.activeName)))
            }))
            items.append(NavItem(id: "slotRename", activate: {
                requestSaveConfirmation(.rename(SaveSlot(id: saves.active, name: saves.activeName)))
            }))
            if saves.slots.count > 1 { items.append(NavItem(id: "slotDelete", activate: { openSaveSelection(.delete) })) }
        }
        for section in m.sections {
            for s in m.settings where s.sectionTitle == section && s.env != "DM_PAD_BY_LABEL" && !m.fromFile.contains(s.env) {
                switch s.kind {
                case "choice", "range", "memory": items.append(NavItem(id: "s:" + s.env, slider: true, adjust: { m.step(s, $0) }))
                default: items.append(NavItem(id: "s:" + s.env, activate: { m.step(s, 1) }))
                }
            }
            if section == "Game" && !shell.fpsLocked {
                items.append(NavItem(id: "fps", slider: true, adjust: { _ in shell.fps = shell.fps == 30 ? 60 : 30 }))
            }
            if section == "Controls" {
                if !shell.gyroLocked { items.append(NavItem(id: "gyro", activate: { shell.gyro.toggle() })) }
                if !tv.on { items.append(NavItem(id: "touchOpacity", slider: true, adjust: { shell.touchOpacity = Swift.min(1, Swift.max(0.2, shell.touchOpacity + Double($0) * 0.05)) }))
                items.append(NavItem(id: "touchScale", slider: true, adjust: { shell.touchScale = Swift.min(1.3, Swift.max(0.7, shell.touchScale + Double($0) * 0.05)) })) }
            }
        }
        items.append(NavItem(id: "reset", activate: { if m.changed { m.reset() } }))
        if !tv.on { items.append(NavItem(id: "folder", activate: openGameFolder)) }
        return items
    }
    private func navDirection(_ key: String) {
        let items = navItems()
        if nav.focus == "play" {   // right (or down) goes back to the row left for Play
            if key == "right" || key == "down" { nav.focus = items.contains { $0.id == nav.list } ? nav.list : items.first?.id ?? "play" }
            else if key == "up", back != nil { nav.focus = "back" }   // the Game list button above
            return
        }
        if nav.focus == "back" {   // down to Play, right to the rows
            if key == "down" { nav.focus = "play" }
            else if key == "right" { nav.focus = items.contains { $0.id == nav.list } ? nav.list : items.first?.id ?? "play" }
            return
        }
        guard let i = items.firstIndex(where: { $0.id == nav.focus }) else { nav.reset(); nav.focus = items.first?.id ?? "play"; return }   // its row went away
        let d = key == "left" ? -1 : 1
        if key == "left" || key == "right" {
            if let n = nav.moveTo, let r = players.players.first(where: { "p\($0.player)" == nav.focus }) {   // the next number but its own
                var t = n; repeat { t = (t - 1 + d + 8) % 8 + 1 } while t == r.player
                nav.moveTo = t
            } else if let part = nav.part { nav.part = Swift.max(0, Swift.min(3, part + d)) }
            else if nav.editing { items[i].adjust(d) }
            else if key == "left" { nav.list = nav.focus; nav.focus = "play" }
            return
        }
        nav.reset()
        nav.focus = items[Swift.max(0, Swift.min(items.count - 1, i + (key == "up" ? -1 : 1)))].id
    }
    private func ownInput(_ p: Int, _ key: String, _ on: Bool) {   // players 2 to 8, on their own row only
        guard on, let r = players.players.first(where: { $0.player == p }) else { return }
        switch key {
        case "left", "right": nav.own[p] = key == "left" ? 0 : 1
        case "a":
            guard let part = nav.own[p] else { nav.own[p] = 0; return }   // the first press shows where it is
            if part == 0 { players.send(["op": "layout", "p": p, "xbox": r.xbox ? 0 : 1]) } else { players.send(["op": "identify", "p": p]) }
        case "b": nav.own[p] = nil
        default: break
        }
    }
    private func navInput(_ u: [AnyHashable: Any]?) {
        guard let key = u?["key"] as? String, ["a", "b", "plus", "up", "down", "left", "right"].contains(key) else { return }   // X, Y and − are the game picker's
        if let confirmation = nav.saveConfirmation {
            guard (u?["p"] as? Int ?? 1) == 1, (u?["on"] as? Int ?? 1) != 0 else { return }
            if key == "b" { cancelSaveConfirmation(); return }
            guard !nav.nameEntryOnIPad else { return }
            if ["left", "up"].contains(key) { nav.confirmFocused = false }
            if ["right", "down"].contains(key) { nav.confirmFocused = true }
            if key == "a" {
                if nav.confirmFocused { confirmSaveAction(confirmation) }
                else { cancelSaveConfirmation() }
            }
            return
        }
        if let selection = nav.saveSelection {
            if (u?["p"] as? Int ?? 1) == 1, (u?["on"] as? Int ?? 1) != 0 { saveSelectionInput(selection, key) }
            return
        }
        if let p = u?["p"] as? Int, p > 1 { ownInput(p, key, (u?["on"] as? Int ?? 1) != 0); return }
        if (u?["on"] as? Int ?? 1) == 0 { if held?.key == key { held?.task.cancel(); held = nil }; return }   // a direction let go
        held?.task.cancel(); held = nil
        let row = players.players.first { "p\($0.player)" == nav.focus }
        switch key {
        case "plus": nav.reset(); play()
        case "a":
            if let n = nav.moveTo, let r = row { nav.reset(); players.send(["op": "swap", "a": r.player, "b": n]); nav.focus = "p\(n)"; return }   // the highlight goes with it
            if let part = nav.part, let r = row { playerPart(r, part); return }
            if nav.editing { nav.editing = false; return }
            if nav.focus == "play" { play(); return }
            if nav.focus == "back" { back?(); return }
            guard let item = navItems().first(where: { $0.id == nav.focus }) else { return }
            if item.slider { nav.editing = true } else { item.activate() }
        case "b":   // back one step, else to Play
            if nav.moveTo != nil { nav.moveTo = nil }
            else if nav.part != nil { nav.part = nil }
            else if nav.editing { nav.editing = false }
            else if nav.focus != "play" && nav.focus != "back" { nav.list = nav.focus; nav.focus = "play" }
            else if let back { back() }   // B on Play: back to the game list
        default:   // a direction: once, then repeated while held (moving up and down, or a value)
            let repeats = key == "up" || key == "down" || nav.editing || nav.moveTo != nil
            navDirection(key)
            guard repeats, nav.saveSelection == nil, nav.saveConfirmation == nil else { return }
            held = (key, Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled { navDirection(key); try? await Task.sleep(for: .milliseconds(120)) }
            })
        }
    }

    private func appIcon() -> UIImage? {
        let root = gameRoot ?? Bundle.main.resourceURL
        if let r = root, let i = UIImage(contentsOfFile: r.appendingPathComponent("dm/icon.jpg").path) { return i }   // the game's own, larger than the app icon (nxn_pack.py)
        if let r = gameRoot, let i = UIImage(contentsOfFile: r.appendingPathComponent("icon.png").path) { return i }
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); return false }
    guard let url = (gameRoot ?? Bundle.main.resourceURL)?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings, defaults: gameDefaults), shell = ShellSettings(), nav = NavModel()
    let saves = SaveSlotsModel(defaultName: { tr("Save %d").replacingOccurrences(of: "%d", with: String($0)) })
    var host: UIViewController?
    let scene = parent.view.window?.windowScene
    let onTV = scene?.session.role == .windowExternalDisplayNonInteractive
    let view = LauncherView(m: model, shell: shell, nav: nav, saves: saves, play: {
        guard let h = host else { return }
        host = nil
        PregameStage.shared.clear()
        model.apply()
        shell.apply()
        if let path = model.runMarker() { path.withCString { dmRunMarkOpen($0) } }
        let covered = frontIosPickerCoverBegin()
        h.dismiss(animated: !covered) { done() }
    }, back: severalGames ? {
        guard let h = host else { return }
        host = nil
        fputs("launcher: back to the game list\n", stderr)
        let covered = frontIosPickerCoverBegin()
        h.dismiss(animated: !covered) { frontIosBackToPicker() }
    } : nil, onTV: onTV, screenScale: scene?.screen.scale ?? 1)
    PregameStage.shared.showLauncher { AnyView(LauncherView(m: model, shell: shell, nav: nav, saves: saves, play: {}, back: severalGames ? {} : nil, onTV: true)) }   // the TV's copy in handheld mode
    let h = NoFocusHostingController(rootView: view)
    controllerNotForUIKit(h.view)
    h.modalPresentationStyle = .fullScreen
    h.modalTransitionStyle = .crossDissolve   // a fade from and to the game picker of a package of several games, and into the loading screen
    host = h
    parent.present(h, animated: !frontIosPickerCoverActive()) {
        h.view.layoutIfNeeded()
        frontIosPickerCoverEnd()
    }
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
