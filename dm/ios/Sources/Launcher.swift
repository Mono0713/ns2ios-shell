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

// The launcher and the game picker move with player 1's controller themselves (DMLauncherInput). Without this, iPadOS also moves its own focus over their
// buttons with it, and A then pressed whichever button that focus was left on (Open game folder, once tapped) as well as the highlighted row
func controllerNotForUIKit(_ view: UIView) {
    if #available(iOS 17.0, *) {
        let i = GCEventInteraction(); i.handledEventTypes = .gamepad
        view.addInteraction(i)
    }
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
    "Game memory pool": "遊戲記憶體", "Game default": "遊戲預設",
    "Change it only if the picture or sound is missing; a wrong size can stop a game from starting.": "僅在畫面或聲音異常時調整；設定錯誤可能導致遊戲無法啟動。",
    // the launcher's own
    "Play": "開始遊戲", "Version": "版本", "Set by an env file": "由 env 檔設定", "Memory available": "可用記憶體",
    "Reset to tested defaults": "還原為建議設定", "Brings back all settings this game was tested with.": "將所有設定恢復為這款遊戲測試時使用的值。",
    "Open game folder": "打開遊戲資料夾", "Game list": "遊戲清單",
    "The app closes; tap its icon again to choose another game.": "App 會關閉，再點一次圖示就能選其他遊戲。", "Saves, env.txt and log.txt are here (Files app).": "存檔、env.txt 與 log.txt 都在這裡（「檔案」App）。",
    "Motion controls": "體感操作（陀螺儀）",
    "The iPad's motion is player 1's while it plays on the iPad; a DualSense, DualShock 4 or Switch Pro controller's is its own player's.":
        "以觸控遊玩時，轉動 iPad 即為 1P 的體感；DualSense、DualShock 4、Switch Pro 手把使用各自的陀螺儀。",
    "Frame rate cap": "幀率上限", "30 fps runs cooler and saves battery; 60 fps is the most a game runs at.": "30 fps 較省電、機身較不燙；60 fps 為遊戲可達到的最高幀率。",
    "Touch controls opacity": "觸控按鍵不透明度", "Touch controls size": "觸控按鍵大小",
    "Identify": "辨識", "Buzzes this player's controller or flashes its phone.": "讓這位玩家的手把震動或手機閃一下。",
    "Phone controllers": "手機手把", "Scan with a phone camera, or open in its browser:": "用手機相機掃描 QR Code，或在瀏覽器輸入：",
    "Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.": "請將 iPad 連上 Wi-Fi（或開啟個人熱點），手機才能加入。",
    "Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player.":
        "連接同一個 Wi-Fi 的手機都能成為獨立玩家，依連線順序取得下一個空的編號，最多 8 位。重新整理頁面會保留原本的玩家編號。",
    "Players": "玩家", "Controller": "手把", "Phone on Wi-Fi": "手機（Wi-Fi）", "phone": "手機", "Not playing": "未使用", "Add": "加入", "Remove": "移除",
    "Move to": "換到", "Button layout": "按鍵配置",
    "No controller or phone yet. Connect a controller, or scan the QR code on the left with a phone.": "尚未連接手把或手機。可連接藍牙手把，或用手機掃描左側的 QR Code。",
    "The iPad's touch controls also play as player 1. Each player keeps its own button layout. A removed phone can join again from its page; a removed controller from here.":
        "沒有連接任何裝置時，iPad 觸控按鍵為 1P。每位玩家的按鍵配置會分別記住。已移除的手機可在手機頁面重新加入，手把則在這裡點「加入」。",
    "Player 1's controller: A on a player, then left and right pick what to change. Players 2 to 8: left and right on your own row pick the layout or Identify, A to use it.":
        "1P 手把：在玩家那一列按 A，再用左右選要調整的項目。2P 以後：用左右在自己那一列選按鍵配置或震動，按 A 執行。",
]
// English as shown: settings.tsv's labels and notes (and the strings above, which are the keys) rewritten for the screen; a string not listed is shown as it is
private let enText: [String: String] = [
    "Frame-rate counter": "Show frame rate", "Game rumble": "Rumble", "Touch feedback": "Haptic feedback on touch", "Performance HUD": "Performance overlay (HUD)",
    "Uses more GPU time and can increase heat.": "Uses more GPU time; the device may run warmer.", "Up to one frame more display latency.": "Adds up to one frame of display latency.",
    "Keeps a pipeline archive; uses more memory.": "Keeps a pipeline cache, which uses more memory.", "The first start waits a few minutes for it, once.": "The first launch takes a few extra minutes, once.",
    "Game memory pool": "Game memory",
    "Change it only if the picture or sound is missing; a wrong size can stop a game from starting.": "Only change this if graphics or sound are missing. A wrong value can keep the game from starting.",
    "Memory available": "Available memory", "Reset to tested defaults": "Restore recommended settings", "Brings back all settings this game was tested with.": "Returns every setting to the values this game was tested with.",
    "Saves, env.txt and log.txt are here (Files app).": "Saves, env.txt and log.txt are kept here (Files app).",
    "Motion controls": "Motion controls (gyro)",
    "The iPad's motion is player 1's while it plays on the iPad; a DualSense, DualShock 4 or Switch Pro controller's is its own player's.":
        "When playing by touch, tilting the iPad drives Player 1's motion. DualSense, DualShock 4 and Switch Pro controllers use their own gyroscope.",

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
    var body: some View {
        let on = activity.lit.contains(player), color = playerColors[(player - 1) % playerColors.count]
        Text("\(player)P").font(.headline.monospacedDigit()).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(Circle().fill(color))
            .overlay(Circle().stroke(Color.white, lineWidth: on ? 3 : 0))
            .shadow(color: color, radius: on ? 12 : 0)
            .scaleEffect(on ? 1.15 : 1)
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

let playerColors: [Color] = [.red, .blue, .yellow, .green, .orange, .purple, .pink, .teal]
func controllerIcon(_ label: String) -> String {
    let l = label.lowercased()
    return l.contains("xbox") ? "logo.xbox" : l.contains("dualsense") || l.contains("dualshock") ? "logo.playstation" : "gamecontroller.fill"
}

private func playerTitle(_ p: PlayerRow) -> String { p.kind == 2 ? (zhHant ? "\(p.label) " + tr("phone") : "\(p.label) phone") : p.label }

private struct PlayerRowView: View {
    let p: PlayerRow
    @ObservedObject var m: PlayersModel
    @EnvironmentObject var nav: NavModel

    private var phone: Bool { p.kind == 2 }
    private var title: String { playerTitle(p) }
    private func moveText(_ n: Int) -> String {
        guard let other = m.players.first(where: { $0.player == n }) else { return "\(n)P" }
        return zhHant ? "\(n)P（和 \(playerTitle(other)) 交換）" : "\(n)P (swap with \(playerTitle(other)))"
    }

    var body: some View {
        HStack(spacing: 12) {
            PlayerBadge(player: p.player)
            Image(systemName: phone ? "iphone" : controllerIcon(p.label)).font(.title2).frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(tr(phone ? "Phone on Wi-Fi" : "Controller")).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(tr("Button layout"), selection: Binding(get: { p.xbox }, set: { m.send(["op": "layout", "p": p.player, "xbox": $0 ? 1 : 0]) })) {
                Text("Switch").tag(false)
                Text("Xbox").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 150)
            .modifier(NavPart(player: p.player, part: 0))
            Button { m.send(["op": "identify", "p": p.player]) } label: {
                Image(systemName: "wave.3.right").font(.title3)
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
                Label(tr("Move to") + (n.map { " \($0)P" } ?? ""), systemImage: "arrow.left.arrow.right")
            }
            .modifier(NavPart(player: p.player, part: 2))
            Button(role: .destructive) { m.send(["op": "kick", "p": p.player]) } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(tr("Remove"))
            .modifier(NavPart(player: p.player, part: 3))
        }
    }
}

private struct PlayersSection: View {
    @ObservedObject var m: PlayersModel   // the launcher's, which its controller navigation also uses

    var body: some View {
        Section {
            if m.players.isEmpty && m.removed.isEmpty {
                Text(tr("No controller or phone yet. Connect a controller, or scan the QR code on the left with a phone.")).foregroundStyle(.secondary)
            }
            ForEach(m.players) { PlayerRowView(p: $0, m: m).nav("p\($0.player)") }
            ForEach(m.removed) { r in
                HStack(spacing: 12) {
                    Image(systemName: controllerIcon(r.label)).font(.title2).frame(width: 44).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.label)
                        Text(tr("Not playing")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Add")) { m.send(["op": "add", "index": r.index]) }.buttonStyle(.borderless)
                }
                .nav("r\(r.index)")
            }
        } header: {
            Text(tr("Players"))
        } footer: {
            Text(tr("The iPad's touch controls also play as player 1. Each player keeps its own button layout. A removed phone can join again from its page; a removed controller from here.")
                 + " " + tr("Player 1's controller: A on a player, then left and right pick what to change. Players 2 to 8: left and right on your own row pick the layout or Identify, A to use it."))
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
    guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

private struct PhonePadsCard: View {   // under Play, in the launcher's left column
    @State private var url = phonePadsURL()
    @State private var qr: UIImage?   // made once per address, not on every redraw

    var body: some View {
        VStack(spacing: 8) {
            Label(tr("Phone controllers"), systemImage: "iphone.gen3").font(.headline)
            if let url {
                if let qr {
                    Image(uiImage: qr).interpolation(.none).resizable().frame(width: 120, height: 120)
                        .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code of \(url)")
                }
                Text(tr("Scan with a phone camera, or open in its browser:")).font(.footnote).foregroundStyle(.secondary)
                Text(url).font(.callout.monospaced()).textSelection(.enabled)
            } else {
                Text(tr("Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.")).font(.footnote).foregroundStyle(.secondary)
            }
            Text(tr("Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .task {
            while !Task.isCancelled {   // the Wi-Fi address can change while the launcher is shown
                let now = phonePadsURL()
                if now != url || (qr == nil && now != nil) { url = now; qr = now.flatMap(qrImage) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
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
                    return gb(v == "-" ? (ProcessInfo.processInfo.environment[s.env] ?? "") : v) ?? s.max ?? 3.2
                },
                set: { m.values[s.env] = String(format: "0x%llX", UInt64(($0 * 1024).rounded()) << 20) })
    }
    private var memoryIsDefault: Bool { (m.values[s.env] ?? s.def) == "-" }
    private var memoryText: String { String(format: "%.1f GB", memoryGB.wrappedValue) + (memoryIsDefault ? " · " + tr("Game default") : "") }   // VoiceOver's value

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(s.label))
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
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
                        if memoryIsDefault || locked { Text(tr("Game default")).foregroundStyle(.secondary).opacity(memoryIsDefault ? 1 : 0) }
                        else { Button(tr("Game default")) { m.values[s.env] = "-" }.buttonStyle(.borderless) }
                    }
                    Slider(value: memoryGB, in: (s.min ?? 0.5)...(s.max ?? 3.2), step: s.step ?? 0.1)
                        .accessibilityLabel(tr(s.label))
                        .accessibilityValue(memoryText)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
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
    var list = ""                    // the row left for Play, where right goes back to
    func reset() { editing = false; part = nil; moveTo = nil }
}
private struct NavHighlight: ViewModifier {
    let id: String
    @EnvironmentObject var nav: NavModel
    func body(content: Content) -> some View {
        let on = nav.focus == id
        content.id(id).listRowBackground(on ? Color.accentColor.opacity(nav.editing ? 0.6 : 0.35) : Color(uiColor: .secondarySystemGroupedBackground))
    }
}
private extension View { func nav(_ id: String) -> some View { modifier(NavHighlight(id: id)) } }
private struct NavPart: ViewModifier {   // a ring around the player row's control player 1 picked
    let player, part: Int
    @EnvironmentObject var nav: NavModel
    func body(content: Content) -> some View {
        content.overlay {
            if nav.focus == "p\(player)" && nav.part == part { RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: 2.5).padding(-5) }
            else if player > 1 && nav.own[player] == part {   // the player's own, in its colour
                RoundedRectangle(cornerRadius: 10).stroke(playerColors[(player - 1) % playerColors.count], lineWidth: 2.5).padding(-5)
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
        case "memory":   // "-" moves from the package's own value
            let t = (v == "-" ? ProcessInfo.processInfo.environment[s.env] ?? "" : v).lowercased()
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
private func noteLabel(_ title: String, _ note: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(tr(title))
        Text(tr(note)).font(.footnote).foregroundStyle(.secondary)
    }
}
// The rows: frame rate in the Game section, the rest in Controls
private struct GyroRow: View {
    @ObservedObject var shell: ShellSettings
    var body: some View {
        Toggle(isOn: $shell.gyro) {
            noteLabel("Motion controls", "The iPad's motion is player 1's while it plays on the iPad; a DualSense, DualShock 4 or Switch Pro controller's is its own player's.")
        }
        .disabled(shell.gyroLocked)
    }
}
private struct FpsRow: View {
    @ObservedObject var shell: ShellSettings
    var body: some View {
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

private func openGameFolder() {   // this app's Documents in the Files app (shareddocuments: scheme)
    if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
       let url = URL(string: "shareddocuments://" + doc.path) { UIApplication.shared.open(url) }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    @ObservedObject var shell: ShellSettings
    let play: () -> Void
    let back: (() -> Void)?   // a package of several games: back to the game picker (main.m), before the game starts
    @State private var memory = os_proc_available_memory()
    @StateObject private var players = PlayersModel()
    @StateObject private var nav = NavModel()
    @StateObject private var activity = ActivityModel()
    @State private var held: (key: String, task: Task<Void, Never>)?   // the direction player 1 holds, repeating

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? tr("Game"))
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text(tr("Version") + " " + ((info("CFBundleShortVersionString") as? String) ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                    Spacer(minLength: 8)
                    if ProcessInfo.processInfo.environment["DM_PHONE_PADS_LIVE"] != nil { PhonePadsCard() }
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                .overlay(alignment: .topLeading) {
                    if let back {
                        Button(action: back) { Label(tr("Game list"), systemImage: "chevron.left").font(.headline) }
                            .buttonStyle(.bordered).controlSize(.large).padding(16)
                            .overlay { if nav.focus == "back" { Capsule().stroke(Color.white, lineWidth: 3).padding(10) } }
                    }
                }
                ScrollViewReader { proxy in
                List {
                    PlayersSection(m: players)
                    ForEach(m.sections, id: \.self) { section in
                        Section(tr(section)) {
                            // the Xbox button layout is each player's own now (the player list above); DM_PAD_BY_LABEL stays the default for a new controller
                            ForEach(m.settings.filter { $0.sectionTitle == section && $0.env != "DM_PAD_BY_LABEL" }) { SettingRow(s: $0, m: m).nav("s:" + $0.env) }
                            if section == "Game" { FpsRow(shell: shell).nav("fps") }
                            if section == "Controls" {
                                GyroRow(shell: shell).nav("gyro")
                                TouchStyleRow(shell: shell, size: false).nav("touchOpacity")
                                TouchStyleRow(shell: shell, size: true).nav("touchScale")
                            }
                        }
                    }
                    Section {
                        Button(tr("Reset to tested defaults")) { m.reset() }
                            .disabled(!m.changed)
                            .nav("reset")
                    } footer: {
                        Text(tr("Brings back all settings this game was tested with."))
                    }
                    Section {
                        Button(tr("Open game folder"), action: openGameFolder)
                            .nav("folder")
                    } footer: {
                        Text(tr("Saves, env.txt and log.txt are here (Files app)."))
                    }
                    Section {
                        HStack {
                            Text(tr("Memory available"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .onChange(of: nav.focus) { _, id in withAnimation { proxy.scrollTo(id == "play" ? "p1" : id, anchor: .center) } }
                }
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .environmentObject(nav)
        .environmentObject(activity)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { navInput($0.userInfo) }
        .onAppear { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) }
        .onDisappear {
            held?.task.cancel()
            NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 0])
        }
        .task {
            while !Task.isCancelled {
                let now = os_proc_available_memory()
                if now / 10_485_760 != memory / 10_485_760 { memory = now }   // in 10 MB steps: a redraw every two seconds for a changing last digit is wasted
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text(tr("Play")).font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        Group {
            if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
        }
        .overlay { if nav.focus == "play" { Capsule().stroke(Color.white, lineWidth: 3).padding(-6) } }
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
                items.append(NavItem(id: "touchOpacity", slider: true, adjust: { shell.touchOpacity = Swift.min(1, Swift.max(0.2, shell.touchOpacity + Double($0) * 0.05)) }))
                items.append(NavItem(id: "touchScale", slider: true, adjust: { shell.touchScale = Swift.min(1.3, Swift.max(0.7, shell.touchScale + Double($0) * 0.05)) }))
            }
        }
        items.append(NavItem(id: "reset", activate: { if m.changed { m.reset() } }))
        items.append(NavItem(id: "folder", activate: openGameFolder))
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
            guard repeats else { return }
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
    let model = LauncherModel(file.settings, defaults: gameDefaults), shell = ShellSettings()
    var host: UIViewController?
    let view = LauncherView(m: model, shell: shell, play: {
        guard let h = host else { return }
        host = nil
        model.apply()
        shell.apply()
        h.dismiss(animated: true) { done() }
    }, back: severalGames ? {
        guard let h = host else { return }
        host = nil
        fputs("launcher: back to the game list\n", stderr)
        h.dismiss(animated: true) { frontIosBackToPicker() }
    } : nil)
    let h = UIHostingController(rootView: view)
    controllerNotForUIKit(h.view)
    h.modalPresentationStyle = .fullScreen
    h.modalTransitionStyle = .crossDissolve   // a fade from and to the game picker of a package of several games, and into the loading screen
    host = h
    parent.present(h, animated: true)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
