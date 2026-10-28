// Game picker: the first screen of a package of several games (scripts/nxn_merge.py puts each in <App>/games/<title ID>/ with its game.json and icon).
// A row of game tiles, the chosen one in the middle, over its icon blurred as the backdrop; the time, Wi-Fi and battery at the top right, as on a console.
// Touch: swipe the row to move through it, tap a tile to start that game. Player 1's controller or phone (shell_players.m, the launcher's DMLauncherInput):
// left and right move, A or + starts. The games stay in order by name; the highlight starts on the one last played.
// The first tile is the phones' QR code (phone_pads.c, started at launch for the picker), with a dot for each player that has joined; choosing it (or Y)
// opens the players card: eight places, each lighting up as its player presses something, with Identify (tap or A), the button layout (− ) and Remove (X).
// Choosing calls main.m's shell_game_choose, which reads that game's files; then the launcher follows as for a package of one game, and its
// Game list button comes back here until the game starts (one process runs one game, main.m).
import SwiftUI
import UIKit
import Network

@_silgen_name("shell_game_choose") private func shellGameChoose(_ gid: UnsafePointer<CChar>)

private let zhHant: Bool = {
    let l = (Locale.preferredLanguages.first ?? "").lowercased()
    return l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo")
}()
private func tr(_ zh: String, _ en: String) -> String { zhHant ? zh : en }

private struct PickerGame: Identifiable {
    let id: String          // title ID: the folder's name
    let name: String
    let version: String
    let icon: UIImage?
    let played: Date?
}

// The game's icon: dm/icon.jpg is the game's own (256 px, nxn_pack.py), icon.png the app icon made from it (180 px) for packages made before
private func gameIcon(_ dir: URL) -> UIImage? {
    UIImage(contentsOfFile: dir.appendingPathComponent("dm/icon.jpg").path) ?? UIImage(contentsOfFile: dir.appendingPathComponent("icon.png").path)
}

private func loadGames() -> [PickerGame] {
    guard let games = Bundle.main.resourceURL?.appendingPathComponent("games") else { return [] }
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []
    let list = ids.compactMap { id -> PickerGame? in
        let dir = games.appendingPathComponent(id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("game.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PickerGame(id: id, name: j["name"] as? String ?? id, version: j["version"] as? String ?? "", icon: gameIcon(dir),
                          played: UserDefaults.standard.object(forKey: "picker.played." + id) as? Date)
    }
    return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }   // a fixed order, by name: the highlight starts on the game last played
}

// The row: the phones' tile at 0, then the games (game i at i + 1)
private final class PickerModel: ObservableObject {
    let games: [PickerGame]
    @Published var focus: Int
    init() {
        let g = loadGames()
        games = g
        focus = (g.indices.filter { g[$0].played != nil }.max { g[$0].played! < g[$1].played! } ?? 0) + 1
    }
    @Published var starting = false
    @Published var padsOpen = false
    @Published var sel = 0   // the highlighted place on the players card (player sel + 1)
    var count: Int { games.count + 1 }
    func game(_ i: Int) -> PickerGame? { games.indices.contains(i - 1) ? games[i - 1] : nil }
    var start: (PickerGame) -> Void = { _ in }
    func move(_ d: Int) { if !starting { focus = Swift.max(0, Swift.min(count - 1, focus + d)) } }
    func go(_ i: Int) { if !starting, (0..<count).contains(i) { focus = i } }
    func choose(_ i: Int? = nil) {
        let i = i ?? focus
        guard !starting, (0..<count).contains(i) else { return }
        focus = i
        if let g = game(i) { starting = true; start(g) } else { padsOpen = true }
    }
}

// The phones' address and its QR code; the address can change while the picker is shown
private final class PadsModel: ObservableObject {
    @Published var url: String?
    @Published var qr: UIImage?
    func refresh() { let now = phonePadsURL(); if now != url || (qr == nil && now != nil) { url = now; qr = now.flatMap(qrImage) } }   // Launcher.swift
}

// A controller's name as the card shows it: short enough for its place ("Xbox Wireless Controller" → Xbox, "Pro Controller" → Switch Pro)
private func padName(_ p: PlayerRow) -> String {
    if p.kind == 2 { return p.label }   // a phone: iPhone, Android or Browser (its page says which)
    let l = p.label.lowercased()
    if l.contains("xbox") { return "Xbox" }
    if l.contains("pro controller") { return "Switch Pro" }
    if l.contains("joy-con") { return "Joy-Con" }
    if l.contains("dualsense") { return "DualSense" }
    if l.contains("dualshock") { return "DualShock" }
    return p.label
}

// The top right: Wi-Fi and battery, as the system's status bar (hidden here) would show them
private final class StatusModel: ObservableObject {
    @Published var battery: Float = UIDevice.current.batteryLevel
    @Published var charging = false
    @Published var online = true
    @Published var wifi = true
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        update()
        for n in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.update() })
        }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.online = path.status == .satisfied
                self?.wifi = path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: DispatchQueue(label: "picker.network"))
    }
    deinit { monitor.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    private func update() {
        battery = UIDevice.current.batteryLevel
        let s = UIDevice.current.batteryState
        charging = s == .charging || s == .full
    }
    var batterySymbol: String {
        if battery < 0 { return "battery.100percent" }   // unknown (the simulator)
        if charging { return "battery.100percent.bolt" }
        switch battery {
        case 0.88...: return "battery.100percent"
        case 0.63..<0.88: return "battery.75percent"
        case 0.38..<0.63: return "battery.50percent"
        case 0.13..<0.38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

private struct StatusBar: View {
    @StateObject private var s = StatusModel()
    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.everyMinute) { t in Text(t.date, style: .time).monospacedDigit() }   // redrawn on each new minute
            Image(systemName: !s.online ? "wifi.slash" : s.wifi ? "wifi" : "network")
                .opacity(s.online ? 1 : 0.5)
                .accessibilityLabel(s.online ? tr("已連線", "Online") : tr("未連線", "Offline"))
            HStack(spacing: 5) {
                if s.battery >= 0 { Text("\(Int((s.battery * 100).rounded()))%").monospacedDigit() }
                Image(systemName: s.batterySymbol)
                    .foregroundStyle(s.battery >= 0 && s.battery < 0.2 && !s.charging ? Color.red : Color.white)
            }
        }
        .font(.title3.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
    }
}

private struct GameTile: View {
    let game: PickerGame
    let focused: Bool
    let side: CGFloat
    var body: some View {
        ZStack {
            if let icon = game.icon {
                Image(uiImage: icon).resizable().interpolation(.high).antialiased(true).scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
                Text(game.name).font(.title3.weight(.bold)).foregroundStyle(.white).multilineTextAlignment(.center).padding(12)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.09, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.09 + 6, style: .continuous)
                .stroke(focused ? Color.cyan : .clear, lineWidth: 4).padding(-7)
                .shadow(color: focused ? .cyan.opacity(0.8) : .clear, radius: 10)
        }
        .shadow(color: .black.opacity(0.5), radius: focused ? 18 : 8, y: focused ? 10 : 4)
        .scaleEffect(focused ? 1 : 0.84)
        .opacity(focused ? 1 : 0.65)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: focused)
    }
}

private struct PadsTile: View {   // the QR code itself, a green dot for each player that has joined
    let qr: UIImage?
    let joined: Int
    let focused: Bool
    let side: CGFloat
    var body: some View {
        ZStack {
            Color.white
            if let qr {
                Image(uiImage: qr).interpolation(.none).resizable().frame(width: side * 0.8, height: side * 0.8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash").font(.system(size: side * 0.18))
                    Text(tr("連上 Wi-Fi 後\n手機才能加入", "Join Wi-Fi\nto let phones in")).font(.headline).multilineTextAlignment(.center)
                }
                .foregroundStyle(.black.opacity(0.55))
            }
            HStack(spacing: 6) { ForEach(0..<joined, id: \.self) { _ in Circle().fill(Color(red: 0.12, green: 0.68, blue: 0.36)).frame(width: 9, height: 9) } }
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, side * 0.04)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.09, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: side * 0.09 + 6, style: .continuous)
                .stroke(focused ? Color.cyan : .clear, lineWidth: 4).padding(-7)
                .shadow(color: focused ? .cyan.opacity(0.8) : .clear, radius: 10)
        }
        .shadow(color: .black.opacity(0.5), radius: focused ? 18 : 8, y: focused ? 10 : 4)
        .scaleEffect(focused ? 1 : 0.84)
        .opacity(focused ? 1 : 0.65)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: focused)
        .accessibilityLabel(tr("手機當手把", "Phone controllers"))
    }
}

// The controllers removed on the card (or in the launcher) take the free places in order, so each can be added back from where it shows
private func removedAt(_ i: Int, _ players: PlayersModel) -> RemovedPad? {
    let free = (0..<8).filter { k in !players.players.contains { $0.player == k + 1 } }
    guard let k = free.firstIndex(of: i), players.removed.indices.contains(k) else { return nil }
    return players.removed[k]
}

// The players card: the QR code and address on the left, the eight places on the right (two columns of four, so it keeps its size)
private struct PadsCard: View {
    @ObservedObject var m: PickerModel
    @ObservedObject var pads: PadsModel
    @ObservedObject var players: PlayersModel
    @EnvironmentObject var activity: ActivityModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(tr("手機和手把", "Phones and controllers")).font(.title.weight(.bold))
                Spacer()
                Text(tr("\(players.players.count) / 8 位玩家", "\(players.players.count) / 8 players")).font(.headline).foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 12) {
                    ZStack {
                        Color.white
                        if let qr = pads.qr { Image(uiImage: qr).interpolation(.none).resizable().padding(14) }
                        else { Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.black.opacity(0.5)) }
                    }
                    .frame(width: 230, height: 230).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if let url = pads.url {
                        Text(url).font(.callout.monospaced()).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    }
                    Text(pads.url == nil ? tr("iPad 連上 Wi-Fi（或開個人熱點）後，手機才能加入", "Connect this iPad to Wi-Fi (or turn on its Personal Hotspot) to let phones join")
                                         : tr("手機連同一個 Wi-Fi，用相機掃描\n就能當手把，不用裝 App", "Phones on the same Wi-Fi scan this\nand play, no app needed"))
                        .font(.footnote).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                }
                .frame(width: 250)
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(0..<4, id: \.self) { r in
                        GridRow { place(r); place(r + 4) }
                    }
                }
            }
            HStack(spacing: 22) {
                Spacer()
                hint("A", tr("震動", "Identify")); hint("−", tr("切換配置", "Layout")); hint("X", tr("移除", "Remove")); hint("B", tr("關閉", "Close"))
            }
            .font(.callout).foregroundStyle(.white.opacity(0.75))
        }
        .padding(30)
        .frame(maxWidth: 980)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(red: 0.106, green: 0.125, blue: 0.157)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
    }

    @ViewBuilder private func place(_ i: Int) -> some View {
        let n = i + 1, color = playerColors[i % playerColors.count]
        let row = players.players.first { $0.player == n }
        let back = removedAt(i, players)   // a controller removed here, offered in a free place so it can be added back
        let lit = activity.lit.contains(n), sel = m.sel == i
        HStack(spacing: 8) {
            Text("P\(n)").font(.headline.weight(.heavy)).frame(width: 40, height: 32)
                .foregroundStyle(row == nil ? Color.white.opacity(0.35) : Color.black.opacity(0.85))
                .background(RoundedRectangle(cornerRadius: 8).fill(row == nil ? Color.white.opacity(0.08) : color))
            if let p = row {
                Image(systemName: p.kind == 2 ? "iphone" : controllerIcon(p.label)).font(.title3).frame(width: 28)
                Text(padName(p)).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button { players.send(["op": "layout", "p": n, "xbox": p.xbox ? 0 : 1]) } label: {
                    Text((p.xbox ? "Xbox" : "Switch") + " ⇄").font(.footnote.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain).accessibilityLabel(tr("切換配置", "Button layout"))
                Button { players.send(["op": "kick", "p": n]) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 30, height: 30).background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain).accessibilityLabel(tr("移除", "Remove"))
            } else if let r = back {
                Image(systemName: controllerIcon(r.label)).font(.title3).frame(width: 28).foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(padName(PlayerRow(player: 0, kind: 1, label: r.label, name: "", xbox: false))).font(.headline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Text(tr("已移除，按 A 或點這裡加回", "Removed: A or tap to add back")).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            } else {
                Text(tr("空位", "Free")).font(.headline.weight(.regular)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 36)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(row == nil ? Color.clear : lit ? color.opacity(0.3) : Color.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(sel ? Color.cyan : row == nil ? Color.white.opacity(0.12) : lit ? color : .clear,
                              style: StrokeStyle(lineWidth: sel ? 2 : row == nil ? 1.5 : 1, dash: row == nil && !sel ? [5, 4] : []))
        }
        .animation(.easeOut(duration: 0.12), value: lit)
        .contentShape(Rectangle())
        .onTapGesture {   // tap: that controller or phone buzzes; a removed one is added back
            m.sel = i
            if row != nil { players.send(["op": "identify", "p": n]) } else if let r = back { players.send(["op": "add", "index": r.index]) }
        }
    }
    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.caption.weight(.bold)).frame(minWidth: 22, minHeight: 22).background(Circle().fill(Color.white.opacity(0.2)))
            Text(text)
        }
    }
}

private struct PickerView: View {
    @ObservedObject var m: PickerModel
    @StateObject private var pads = PadsModel()
    @StateObject private var players = PlayersModel()   // Launcher.swift: the list from shell_players.m
    @StateObject private var activity = ActivityModel()
    @State private var held: (key: String, task: Task<Void, Never>)?
    @State private var drag: CGFloat = 0   // how far a finger has moved the row

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.height * 0.36, g.size.width / 4.4, 300)
            let gap = side * 0.14
            let current = m.game(m.focus)
            ZStack {
                VStack(spacing: 0) {
                    header.padding(.horizontal, 32).padding(.top, 22)
                    Spacer(minLength: 0)
                    row(width: g.size.width, side: side, gap: gap)
                    details(current).padding(.top, 22)
                    Spacer(minLength: 0)
                    footer.padding(.horizontal, 32).padding(.bottom, 22)
                }
                if m.padsOpen {
                    Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { m.padsOpen = false }
                        .transition(.opacity)
                    PadsCard(m: m, pads: pads, players: players).padding(32)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.easeOut(duration: 0.22), value: m.padsOpen)
            .environmentObject(activity)
            .frame(width: g.size.width, height: g.size.height)
            .background { backdrop(current) }   // behind, not in the stack: the icon filling the screen would make the stack taller than it and push the row down
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { input($0.userInfo) }
        .onAppear { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) }
        .onDisappear { held?.task.cancel() }
        .task { while !Task.isCancelled { pads.refresh(); try? await Task.sleep(for: .seconds(3)) } }
    }

    // The tiles, the chosen one in the middle of the screen; a swipe moves by as many tiles as it throws
    private func row(width: CGFloat, side: CGFloat, gap: CGFloat) -> some View {
        let pitch = side + gap
        return HStack(spacing: gap) {
            PadsTile(qr: pads.qr, joined: players.players.count, focused: m.focus == 0, side: side)
                .contentShape(Rectangle())
                .onTapGesture { m.choose(0) }
                .accessibilityAddTraits(.isButton)
            ForEach(Array(m.games.enumerated()), id: \.element.id) { i, game in
                GameTile(game: game, focused: i + 1 == m.focus, side: side)
                    .contentShape(Rectangle())
                    .onTapGesture { m.choose(i + 1) }
                    .accessibilityLabel(game.name)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .fixedSize()
        .offset(x: (width - side) / 2 - CGFloat(m.focus) * pitch + drag)
        .frame(width: width, height: side * 1.15, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in if !m.starting { drag = v.translation.width } }
                .onEnded { v in
                    let steps = Int((-v.predictedEndTranslation.width / pitch).rounded())
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        m.go(Swift.max(0, Swift.min(m.count - 1, m.focus + steps)))
                        drag = 0
                    }
                }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: m.focus)
    }

    private func backdrop(_ game: PickerGame?) -> some View {
        ZStack {
            Color.black
            if let icon = game?.icon {
                Image(uiImage: icon).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .blur(radius: 60).scaleEffect(1.4).opacity(0.55)
                    .id(game?.id).transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: game?.id)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(tr("選擇遊戲", "Choose a game")).font(.largeTitle.weight(.bold))
            Spacer()
            StatusBar()
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func details(_ game: PickerGame?) -> some View {
        if m.focus == 0 {
            VStack(spacing: 6) {
                Text(tr("手機當手把", "Phone controllers")).font(.title.weight(.bold)).foregroundStyle(.white)
                Text(tr("用相機掃描 QR code，按 A 看已連接的設備", "Scan the QR code with a phone camera; A shows who has joined"))
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 32)
        } else if let game {
            VStack(spacing: 6) {
                Text(game.name).font(.title.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                HStack(spacing: 12) {
                    if !game.version.isEmpty { Text(tr("版本 ", "Version ") + game.version) }
                    if let p = game.played { Text(tr("上次遊玩 ", "Last played ") + p.formatted(.relative(presentation: .named).locale(Locale(identifier: zhHant ? "zh-Hant" : "en")))) }
                }
                .font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 32)
            .animation(.easeInOut(duration: 0.25), value: game.id)   // the name and version cross-fade as the row slides
        }
    }

    private var footer: some View {
        HStack(spacing: 22) {
            Text(tr("點遊戲圖示開始", "Tap a game to play")).foregroundStyle(.white.opacity(0.55))
            Spacer()
            hint("A", m.focus == 0 ? tr("設備清單", "Players") : tr("開始", "Play"))
            hint("◀ ▶", tr("選擇", "Choose"))
            hint("Y", tr("手機和手把", "Players"))
        }
        .font(.callout).foregroundStyle(.white.opacity(0.75))
    }
    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.caption.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.2)))
            Text(text)
        }
    }

    // On the players card: up and down within a column, left and right between the columns; A identifies, − switches the layout, X removes, B closes
    private func cardInput(_ key: String) {
        let row = players.players.first { $0.player == m.sel + 1 }
        switch key {
        case "up": if m.sel % 4 > 0 { m.sel -= 1 }
        case "down": if m.sel % 4 < 3 { m.sel += 1 }
        case "left": if m.sel >= 4 { m.sel -= 4 }
        case "right": if m.sel < 4 { m.sel += 4 }
        case "a":
            if let r = row { players.send(["op": "identify", "p": r.player]) }
            else if let r = removedAt(m.sel, players) { players.send(["op": "add", "index": r.index]) }
        case "minus": if let r = row { players.send(["op": "layout", "p": r.player, "xbox": r.xbox ? 0 : 1]) }
        case "x": if let r = row { players.send(["op": "kick", "p": r.player]) }
        case "b", "y": m.padsOpen = false
        default: break
        }
    }

    private func input(_ u: [AnyHashable: Any]?) {
        guard let key = u?["key"] as? String, (u?["p"] as? Int ?? 1) == 1 else { return }   // player 1 drives it, as in the launcher
        if (u?["on"] as? Int ?? 1) == 0 { if held?.key == key { held?.task.cancel(); held = nil }; return }   // a direction let go
        held?.task.cancel(); held = nil
        if m.padsOpen { cardInput(key); return }
        switch key {
        case "y": m.padsOpen = true
        case "a", "plus": m.choose()
        case "left", "right", "up", "down":
            let d = key == "left" || key == "up" ? -1 : 1
            m.move(d)
            held = (key, Task { @MainActor in   // repeats while held
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled { m.move(d); try? await Task.sleep(for: .milliseconds(160)) }
            })
        default: break
        }
    }
}

// Shows the picker over the root view controller; once a game is chosen and main.m has it set up, the picker goes away and done runs.
// Shown again when the launcher goes back to the game list (front_ios.m)
@_cdecl("dm_show_picker")
public func dmShowPicker(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = PickerModel()
    let h = UIHostingController(rootView: PickerView(m: model))
    controllerNotForUIKit(h.view)   // Launcher.swift
    h.modalPresentationStyle = .fullScreen
    h.modalTransitionStyle = .crossDissolve   // fades in and out, to and from the launcher
    model.start = { [weak h] game in
        UserDefaults.standard.set(Date(), forKey: "picker.played." + game.id)
        fputs("picker: \(game.id) (\(game.name))\n", stderr)
        NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 0])
        DispatchQueue.main.async {   // let the loading veil draw before main.m reads the game's files
            game.id.withCString { shellGameChoose($0) }
            h?.dismiss(animated: true) { done() }
        }
    }
    parent.present(h, animated: true)
    fputs("picker: \(model.games.count) games shown\n", stderr)
}
