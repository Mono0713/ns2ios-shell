// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once, as an app without launcher.json does
import SwiftUI
import Combine
import UIKit
import CoreImage.CIFilterBuiltins
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

// Traditional Chinese when the device's first language is (zh-Hant, zh-TW, zh-HK, zh-MO); anything else stays English. launcher.json carries settings.tsv's
// English labels and notes and nacp.py's language names, so they are looked up by their English text; an unknown one is shown as it is
private let zhHant: Bool = {
    let l = (Locale.preferredLanguages.first ?? "").lowercased()
    return l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo")
}()
private let zhText: [String: String] = [
    "Game": "遊戲", "Controls": "操作", "Performance": "效能",
    "Frame rate": "幀率", "Render scale": "渲染解析度", "Console mode": "主機模式", "Docked": "電視模式", "Handheld": "掌機模式",
    "Upscaling": "畫面放大", "Standard": "標準", "Uses more GPU time and can increase heat.": "會多用 GPU 時間，可能讓機身變熱。",
    "Game language": "遊戲語言", "Frame-rate counter": "顯示幀率",
    "Xbox button layout": "Xbox 按鍵配置", "A, B, X and Y as printed on an Xbox controller (Switch games expect A on the right).": "A、B、X、Y 照 Xbox 手把上印的位置（Switch 遊戲預設 A 在右邊）。",
    "Touch feedback": "觸控回饋", "Game rumble": "遊戲震動", "Rumble strength": "震動強度",
    "Frame buffering": "畫面緩衝", "Up to one frame more display latency.": "顯示延遲最多增加一幀。",
    "Metal 4 pipelines": "Metal 4 管線", "Keeps a pipeline archive; uses more memory.": "保留管線封存檔，會多用記憶體。",
    "Pipeline prebuild": "預先建置管線", "The first start waits a few minutes for it, once.": "第一次啟動會等幾分鐘，只有一次。",
    "Encode thread": "獨立編碼執行緒", "Hold frames when late": "延遲時保留畫格", "Performance HUD": "效能監看 HUD",
    "American English": "英文（美國）", "British English": "英文（英國）", "Japanese": "日文", "French": "法文", "German": "德文",
    "Latin American Spanish": "西班牙文（拉丁美洲）", "Spanish": "西班牙文", "Italian": "義大利文", "Dutch": "荷蘭文", "Canadian French": "法文（加拿大）",
    "Portuguese": "葡萄牙文", "Russian": "俄文", "Korean": "韓文", "Traditional Chinese": "繁體中文", "Simplified Chinese": "簡體中文", "Brazilian Portuguese": "葡萄牙文（巴西）",
    "Game memory pool": "遊戲記憶體池", "Game default": "遊戲預設", 
    "Change it only if the picture or sound is missing; a wrong size can stop a game from starting.": "畫面或聲音不正常時才需要改；設錯可能讓遊戲無法啟動。",
    "Open game folder": "打開遊戲資料夾", "Saves, env.txt and log.txt are here (Files app).": "存檔、env.txt 和 log.txt 都在這裡（檔案 App）。",
    "Play": "開始遊戲", "Version": "版本", "Set by an env file": "由 env 檔設定", "Memory available": "可用記憶體",
    "Reset to tested defaults": "還原為測試過的預設值", "Brings back all settings this game was tested with.": "恢復這款遊戲測試時使用的所有設定。",
    "Phone controllers": "手機手把", "Player 1's controller or phone: D-pad to move, A to choose, + to start (Xbox: ≡).": "1P 的手把或手機：方向鍵移動、A 確定、+ 開始遊戲（Xbox 手把是 ≡ 鍵）。", "Scan with a phone camera, or open in its browser:": "用手機相機掃描，或在手機瀏覽器打開：",
    "Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.": "請先連上 Wi-Fi（或開啟個人熱點），手機才能加入。",
    "Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player.":
        "同一個 Wi-Fi 的每支手機都是一個獨立玩家，排在已連線的手把後面，最多到 8P。手機重新整理頁面會保留原本的玩家。",
    "Players": "玩家", "Controller": "手把", "Phone on Wi-Fi": "手機（Wi-Fi）", "phone": "手機", "Not playing": "未使用", "Add": "加入", "Remove": "移除",
    "Move to": "換到", "Button layout": "按鍵配置",
    "No controller or phone yet. Connect a controller, or scan the QR code below with a phone.": "還沒有手把或手機。連上藍牙手把，或用手機掃下面的 QR Code。",
    "The iPad's touch controls also play as player 1. Each player keeps its own button layout. A removed phone can join again from its page; a removed controller from here.":
        "iPad 的觸控按鍵也一直是 1P。每個玩家各自記住自己的按鍵配置。被移除的手機可以在手機頁面上重新加入，手把則在這裡按「加入」。",
    "With player 1's controller: left and right change a player's button layout, A moves it to the next player number.": "用 1P 的手把：左右切換這個玩家的按鍵配置，A 換到下一個玩家編號。",
]
private func tr(_ s: String) -> String { zhHant ? zhText[s] ?? s : s }

// Players (shell_players.m): who plays which player, from the physical controllers and the phones, at the top of the launcher. The list comes from the
// DMPlayersChanged notification and the changes go back as DMPlayersCommand (swap, kick, layout, add), so this file needs no C header
private struct PlayerRow: Identifiable, Equatable { let player, kind: Int; let label, name: String; let xbox: Bool; var id: Int { player } }
private struct RemovedPad: Identifiable, Equatable { let index: Int; let label: String; var id: Int { index } }
private final class PlayersModel: ObservableObject {
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
private final class ActivityModel: ObservableObject {
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

private let playerColors: [Color] = [.red, .blue, .yellow, .green, .orange, .purple, .pink, .teal]
private func controllerIcon(_ label: String) -> String {
    let l = label.lowercased()
    return l.contains("xbox") ? "logo.xbox" : l.contains("dualsense") || l.contains("dualshock") ? "logo.playstation" : "gamecontroller.fill"
}

private struct PlayerRowView: View {
    let p: PlayerRow
    @ObservedObject var m: PlayersModel

    private var phone: Bool { p.kind == 2 }
    private var title: String { phone ? (zhHant ? "\(p.label) " + tr("phone") : "\(p.label) phone") : p.label }
    private func moveText(_ n: Int) -> String {
        guard let other = m.players.first(where: { $0.player == n }) else { return "\(n)P" }
        let who = other.kind == 2 ? (zhHant ? "\(other.label) " + tr("phone") : "\(other.label) phone") : other.label
        return zhHant ? "\(n)P（和 \(who) 交換）" : "\(n)P (swap with \(who))"
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
            Menu {
                ForEach(1...8, id: \.self) { n in
                    if n != p.player { Button(moveText(n)) { m.send(["op": "swap", "a": p.player, "b": n]) } }
                }
            } label: {
                Label(tr("Move to"), systemImage: "arrow.left.arrow.right")
            }
            Button(role: .destructive) { m.send(["op": "kick", "p": p.player]) } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(tr("Remove"))
        }
    }
}

private struct PlayersSection: View {
    @ObservedObject var m: PlayersModel   // the launcher's, which its controller navigation also uses

    var body: some View {
        Section {
            if m.players.isEmpty && m.removed.isEmpty {
                Text(tr("No controller or phone yet. Connect a controller, or scan the QR code below with a phone.")).foregroundStyle(.secondary)
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
                 + " " + tr("With player 1's controller: left and right change a player's button layout, A moves it to the next player number."))
        }
    }
}

// Phone controllers (phone_pads.c): the address phones open, and a QR code of it. DM_PHONE_PADS_LIVE is the port the server listens on (unset when it is off or could not start);
// the address is this device's IPv4 address on Wi-Fi (en0), or on another interface that is up (a personal hotspot's bridge) when there is no Wi-Fi
private func phonePadsURL() -> String? {
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

private func qrImage(_ text: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

private struct PhonePadsSection: View {
    @State private var url = phonePadsURL()
    @State private var qr: UIImage?   // made once per address, not on every redraw

    var body: some View {
        Section {
            if let url {
                HStack(spacing: 16) {
                    if let qr {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 132, height: 132)
                            .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("QR code of \(url)")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Scan with a phone camera, or open in its browser:")).font(.callout).foregroundStyle(.secondary)
                        Text(url).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                Text(tr("Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.")).foregroundStyle(.secondary)
            }
        } header: {
            Text(tr("Phone controllers"))
        } footer: {
            Text(tr("Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player."))
        }
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
    private var memoryText: String { String(format: "%.1f GB", memoryGB.wrappedValue) + (memoryIsDefault ? " · " + tr("Game default") : "") }

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
                        if !memoryIsDefault && !locked { Button(tr("Game default")) { m.values[s.env] = "-" }.buttonStyle(.borderless) }
                        Text(memoryText).monospacedDigit().foregroundStyle(.secondary)
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

// Player 1's controller or phone on the launcher (shell_players.m posts DMLauncherInput): the D-pad or left stick moves a highlight over Play and the rows, left and right
// change the highlighted row, A uses it, B goes back to Play and + starts the game. Touch works as before
private final class NavModel: ObservableObject { @Published var focus = "play" }
private struct NavHighlight: ViewModifier {
    let id: String
    @EnvironmentObject var nav: NavModel
    func body(content: Content) -> some View {
        content.id(id).listRowBackground(nav.focus == id ? Color.accentColor.opacity(0.35) : Color(uiColor: .secondarySystemGroupedBackground))
    }
}
private extension View { func nav(_ id: String) -> some View { modifier(NavHighlight(id: id)) } }
private struct NavItem { let id: String; var activate: () -> Void = {}; var adjust: ((Int) -> Void)? = nil }

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

private func openGameFolder() {   // this app's Documents in the Files app (shareddocuments: scheme)
    if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
       let url = URL(string: "shareddocuments://" + doc.path) { UIApplication.shared.open(url) }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @StateObject private var players = PlayersModel()
    @StateObject private var nav = NavModel()
    @StateObject private var activity = ActivityModel()
    @State private var held: (key: String, task: Task<Void, Never>)?   // the direction player 1 holds, repeating

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
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
                    Text(tr("Player 1's controller or phone: D-pad to move, A to choose, + to start (Xbox: ≡)."))
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                ScrollViewReader { proxy in
                List {
                    PlayersSection(m: players)
                    ForEach(m.sections, id: \.self) { section in
                        Section(tr(section)) {
                            // the Xbox button layout is each player's own now (the player list above); DM_PAD_BY_LABEL stays the default for a new controller
                            ForEach(m.settings.filter { $0.sectionTitle == section && $0.env != "DM_PAD_BY_LABEL" }) { SettingRow(s: $0, m: m).nav("s:" + $0.env) }
                        }
                    }
                    if ProcessInfo.processInfo.environment["DM_PHONE_PADS_LIVE"] != nil { PhonePadsSection() }
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
    private func navItems() -> [NavItem] {   // in screen order; a setting an env file set is skipped
        var items = [NavItem(id: "play", activate: play)]
        let last = players.players.map(\.player).max() ?? 1
        for r in players.players {
            items.append(NavItem(id: "p\(r.player)", activate: { players.send(["op": "swap", "a": r.player, "b": r.player % last + 1]) },
                                 adjust: { _ in players.send(["op": "layout", "p": r.player, "xbox": r.xbox ? 0 : 1]) }))
        }
        for r in players.removed { items.append(NavItem(id: "r\(r.index)", activate: { players.send(["op": "add", "index": r.index]) })) }
        for section in m.sections {
            for s in m.settings where s.sectionTitle == section && s.env != "DM_PAD_BY_LABEL" && !m.fromFile.contains(s.env) {
                let slider = s.kind == "range" || s.kind == "memory"
                items.append(NavItem(id: "s:" + s.env, activate: { if !slider { m.step(s, 1) } }, adjust: { m.step(s, $0) }))
            }
        }
        items.append(NavItem(id: "reset", activate: { if m.changed { m.reset() } }))
        items.append(NavItem(id: "folder", activate: openGameFolder))
        return items
    }
    private func navMove(_ key: String) {
        let items = navItems()
        guard let i = items.firstIndex(where: { $0.id == nav.focus }) else { nav.focus = "play"; return }   // its row went away
        switch key {
        case "up": nav.focus = items[Swift.max(0, i - 1)].id
        case "down": nav.focus = items[Swift.min(items.count - 1, i + 1)].id
        case "left": items[i].adjust?(-1)
        default: items[i].adjust?(1)
        }
    }
    private func navInput(_ u: [AnyHashable: Any]?) {
        guard let key = u?["key"] as? String else { return }
        switch key {
        case "plus": play()
        case "a": navItems().first { $0.id == nav.focus }?.activate()
        case "b": nav.focus = "play"
        default:   // a direction: once, then repeated while held
            if (u?["on"] as? Int ?? 1) == 0 { if held?.key == key { held?.task.cancel(); held = nil }; return }
            held?.task.cancel()
            navMove(key)
            held = (key, Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled { navMove(key); try? await Task.sleep(for: .milliseconds(120)) }
            })
        }
    }

    private func appIcon() -> UIImage? {
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
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
