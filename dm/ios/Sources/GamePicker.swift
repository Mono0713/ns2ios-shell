// Game picker: the first screen of a package of several games (scripts/nxn_merge.py puts each in <App>/games/<title ID>/ with its game.json and icon).
// A row of game tiles, the chosen one in the middle, over its icon blurred as the backdrop; the time, Wi-Fi and battery at the top right, as on a console.
// Touch: swipe the row to move through it, tap a tile to start that game. Player 1's controller or phone (shell_players.m, the launcher's DMLauncherInput):
// left and right move, A or + starts. The games stay in order by name; the highlight starts on the one last played.
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

private final class PickerModel: ObservableObject {
    let games: [PickerGame]
    @Published var focus: Int
    init() {
        let g = loadGames()
        games = g
        focus = g.indices.filter { g[$0].played != nil }.max { g[$0].played! < g[$1].played! } ?? 0
    }
    @Published var starting = false
    var start: (PickerGame) -> Void = { _ in }
    func move(_ d: Int) { if !games.isEmpty, !starting { focus = (focus + d + games.count) % games.count } }
    func go(_ i: Int) { if !starting, games.indices.contains(i) { focus = i } }
    func choose(_ i: Int? = nil) {
        let i = i ?? focus
        if !starting, games.indices.contains(i) { focus = i; starting = true; start(games[i]) }
    }
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

private struct PickerView: View {
    @ObservedObject var m: PickerModel
    @State private var held: (key: String, task: Task<Void, Never>)?
    @State private var drag: CGFloat = 0   // how far a finger has moved the row

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.height * 0.36, g.size.width / 4.4, 300)
            let gap = side * 0.14
            let current = m.games.indices.contains(m.focus) ? m.games[m.focus] : nil
            ZStack {
                VStack(spacing: 0) {
                    header.padding(.horizontal, 32).padding(.top, 22)
                    Spacer(minLength: 0)
                    row(width: g.size.width, side: side, gap: gap)
                    details(current).padding(.top, 22)
                    Spacer(minLength: 0)
                    footer.padding(.horizontal, 32).padding(.bottom, 22)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .background { backdrop(current) }   // behind, not in the stack: the icon filling the screen would make the stack taller than it and push the row down
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { input($0.userInfo) }
        .onAppear { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) }
        .onDisappear { held?.task.cancel() }
    }

    // The tiles, the chosen one in the middle of the screen; a swipe moves by as many tiles as it throws
    private func row(width: CGFloat, side: CGFloat, gap: CGFloat) -> some View {
        let pitch = side + gap
        return HStack(spacing: gap) {
            ForEach(Array(m.games.enumerated()), id: \.element.id) { i, game in
                GameTile(game: game, focused: i == m.focus, side: side)
                    .contentShape(Rectangle())
                    .onTapGesture { m.choose(i) }
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
                        m.go(Swift.max(0, Swift.min(m.games.count - 1, m.focus + steps)))
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
        if let game {
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
            hint("A", tr("開始", "Play"))
            hint("◀ ▶", tr("選擇", "Choose"))
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

    private func input(_ u: [AnyHashable: Any]?) {
        guard let key = u?["key"] as? String, (u?["p"] as? Int ?? 1) == 1 else { return }   // player 1 drives it, as in the launcher
        if (u?["on"] as? Int ?? 1) == 0 { if held?.key == key { held?.task.cancel(); held = nil }; return }   // a direction let go
        held?.task.cancel(); held = nil
        switch key {
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
