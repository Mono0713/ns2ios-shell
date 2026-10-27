// Game picker: the first screen of a package of several games (scripts/nxn_merge.py puts each in <App>/games/<title ID>/ with its game.json and icon.png).
// A row of game tiles over the chosen game's icon, blurred, as the backdrop. Touch: tap a tile to pick it, tap it again (or Play) to start it.
// Player 1's controller or phone (shell_players.m, the launcher's DMLauncherInput): left and right move, A or + starts. The game last played comes first.
// Choosing calls main.m's shell_game_choose, which reads that game's files and starts loading it; then the launcher follows as for a package of one game.
// One process runs one game (main.m), so the launcher's Change game closes the app to come back here.
import SwiftUI
import UIKit

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

private func loadGames() -> [PickerGame] {
    guard let games = Bundle.main.resourceURL?.appendingPathComponent("games") else { return [] }
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: games.path)) ?? []
    let list = ids.compactMap { id -> PickerGame? in
        let dir = games.appendingPathComponent(id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("game.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PickerGame(id: id, name: j["name"] as? String ?? id, version: j["version"] as? String ?? "",
                          icon: UIImage(contentsOfFile: dir.appendingPathComponent("icon.png").path),
                          played: UserDefaults.standard.object(forKey: "picker.played." + id) as? Date)
    }
    // the last played first, then the rest by name
    return list.sorted { a, b in
        switch (a.played, b.played) {
        case let (x?, y?): return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

private final class PickerModel: ObservableObject {
    let games = loadGames()
    @Published var focus = 0
    @Published var starting = false
    var start: (PickerGame) -> Void = { _ in }
    func move(_ d: Int) { if !games.isEmpty, !starting { focus = (focus + d + games.count) % games.count } }
    func choose() { if !starting, games.indices.contains(focus) { starting = true; start(games[focus]) } }
}

private struct GameTile: View {
    let game: PickerGame
    let focused: Bool
    let side: CGFloat
    var body: some View {
        ZStack {
            if let icon = game.icon {
                Image(uiImage: icon).resizable().scaledToFill()
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
        .scaleEffect(focused ? 1.08 : 0.92)
        .opacity(focused ? 1 : 0.7)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: focused)
    }
}

private struct PickerView: View {
    @ObservedObject var m: PickerModel
    @State private var held: (key: String, task: Task<Void, Never>)?
    @State private var now = Date()
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.height * 0.42, g.size.width / 4.2)
            let current = m.games.indices.contains(m.focus) ? m.games[m.focus] : nil
            ZStack {
                backdrop(current)
                VStack(spacing: 0) {
                    header.padding(.horizontal, 32).padding(.top, 20)
                    Spacer(minLength: 0)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: side * 0.16) {
                                ForEach(Array(m.games.enumerated()), id: \.element.id) { i, game in
                                    GameTile(game: game, focused: i == m.focus, side: side)
                                        .id(i)
                                        .onTapGesture { if i == m.focus { m.choose() } else { m.focus = i } }
                                        .accessibilityLabel(game.name)
                                        .accessibilityAddTraits(.isButton)
                                }
                            }
                            .padding(.horizontal, max(32, (g.size.width - side) / 2))
                            .padding(.vertical, side * 0.12)
                        }
                        .scrollDisabled(m.games.count < 2)
                        .onChange(of: m.focus) { _, i in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) } }
                        .onAppear { proxy.scrollTo(m.focus, anchor: .center) }
                    }
                    details(current).padding(.top, 8)
                    Spacer(minLength: 0)
                    footer.padding(.horizontal, 32).padding(.bottom, 18)
                }
                if m.starting {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(tr("正在載入…", "Loading…")).foregroundStyle(.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { input($0.userInfo) }
        .onAppear { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) }
        .onDisappear { held?.task.cancel() }
    }

    private func backdrop(_ game: PickerGame?) -> some View {
        ZStack {
            Color.black
            if let icon = game?.icon {
                Image(uiImage: icon).resizable().scaledToFill()
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
            Text("\(m.games.count)").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(now, style: .time).font(.title3.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func details(_ game: PickerGame?) -> some View {
        if let game {
            VStack(spacing: 6) {
                Text(game.name).font(.title.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: 12) {
                    if !game.version.isEmpty { Text(tr("版本 ", "Version ") + game.version) }
                    if let p = game.played { Text(tr("上次遊玩 ", "Last played ") + p.formatted(.relative(presentation: .named))) }
                }
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                playButton(game).padding(.top, 10)
            }
            .padding(.horizontal, 32)
            .animation(nil, value: game.id)
        }
    }

    @ViewBuilder private func playButton(_ game: PickerGame) -> some View {
        let button = Button { m.choose() } label: {
            Label(tr("開始遊戲", "Play"), systemImage: "play.fill").font(.title3.weight(.semibold)).frame(minWidth: 180)
        }.controlSize(.large).disabled(m.starting)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private var footer: some View {
        HStack(spacing: 22) {
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

// Shows the picker over the root view controller; once a game is chosen and main.m has it set up, the picker goes away and done runs
@_cdecl("dm_show_picker")
public func dmShowPicker(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) {
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = PickerModel()
    let h = UIHostingController(rootView: PickerView(m: model))
    h.modalPresentationStyle = .fullScreen
    model.start = { [weak h] game in
        UserDefaults.standard.set(Date(), forKey: "picker.played." + game.id)
        fputs("picker: \(game.id) (\(game.name))\n", stderr)
        NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 0])
        DispatchQueue.main.async {   // let the loading veil draw before main.m reads the game's files
            game.id.withCString { shellGameChoose($0) }
            h?.dismiss(animated: false) { done() }
        }
    }
    parent.present(h, animated: false)
    fputs("picker: \(model.games.count) games shown\n", stderr)
}
