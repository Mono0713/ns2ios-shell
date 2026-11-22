// Game picker: the first screen of a package of several games (scripts/nxn_merge.py puts each in <App>/games/<title ID>/ with its game.json and icon).
// A row of game tiles, the chosen one in the middle, over its icon blurred as the backdrop; the time, Wi-Fi and battery at the top right, as on a console.
// Styled like Switch Pad on the PC: the package's icon and name at the top left, app-icon corners, a white focus ring, small rounded chips.
// Touch: swipe the row to move through it, tap a tile to start that game. Player 1's controller or phone (shell_players.m, the launcher's DMLauncherInput):
// left and right move, A or + starts, X shows every game at once (a grid: the arrows move, A opens the game's settings, B goes back). The games keep the
// order set on the iPad, then the PC's synced order, then by name. The highlight starts on the phones' QR code, and the row wraps back to it.
// The first tile is the phones' QR code (phone_pads.c, started at launch for the picker), with a dot for each player that has joined; choosing it (or Y)
// opens the players card: eight places, each lighting up as its player presses something, with Identify (tap or A), the button layout (− ) and Remove (X).
// Choosing calls main.m's shell_game_choose, which reads that game's files; then the launcher follows as for a package of one game, and its
// Game list button comes back here until the game starts (one process runs one game, main.m).
import SwiftUI
import Combine
import UIKit
import Network
import CoreImage.CIFilterBuiltins

@_silgen_name("shell_game_choose") private func shellGameChoose(_ gid: UnsafePointer<CChar>)
@_silgen_name("front_ios_picker_cover_begin") func frontIosPickerCoverBegin() -> Bool
@_silgen_name("front_ios_picker_cover_active") func frontIosPickerCoverActive() -> Bool
@_silgen_name("front_ios_picker_cover_end") func frontIosPickerCoverEnd()
@_silgen_name("front_ios_picker_volume") private func pickerVolume() -> Float
@_silgen_name("front_ios_picker_set_volume") private func setPickerVolume(_ value: Float)
@_silgen_name("front_ios_picker_adjust_volume") private func adjustPickerVolume(_ direction: Int32) -> Bool
@_silgen_name("front_ios_picker_outputs") private func pickerOutputs() -> Int32
@_silgen_name("front_ios_picker_action") private func pickerAction(_ action: Int32)

private let zhHant: Bool = {
    let l = (Locale.preferredLanguages.first ?? "").lowercased()
    return l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo")
}()
private func tr(_ zh: String, _ en: String) -> String { zhHant ? zh : en }

// SwitchPad's look, shared by the picker and the launcher (docs/DESIGN.zh-TW.md); front_ios.m's in-game menu and Switch Pad on the PC use the same values:
// graphite, the system blue, rounded rectangles with a continuous curve (never capsules), frosted cards with a hairline edge, small chips, springs
enum DS {
    static let accent = Color(red: 0.039, green: 0.518, blue: 1)   // #0A84FF
    static let card = Color(red: 0.08, green: 0.09, blue: 0.11)      // the tint over a card's frosted glass
    static let plate = Color.white.opacity(0.06)                     // a row's faint plate
    static let hairline = Color.white.opacity(0.12)
    static let chip = Color.white.opacity(0.12)
    static let cardRadius: CGFloat = 26, rowRadius: CGFloat = 16, tileRadius: CGFloat = 10, chipRadius: CGFloat = 7
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.82)   // moving a selection
    static let pop = Animation.spring(response: 0.45, dampingFraction: 0.74)      // a card coming in
    static let cardIn = AnyTransition.asymmetric(insertion: .scale(scale: 0.9).combined(with: .offset(y: 24)).combined(with: .opacity),
                                                 removal: .scale(scale: 0.94).combined(with: .opacity))
}
// Ten-foot mode: on the TV's window (front_ios.m presents the picker and the launcher there before the game) everyone sits far from the screen, so text is
// larger (Dynamic Type at .accessibility1), tiles and the QR code are larger and notes are left out, as on a console's home screen. Decided by the window the
// view is in, not by a TV being plugged in: with the picture output set to the iPad the same screens stay at the iPad's sizes
final class TenFoot: ObservableObject {
    @Published private(set) var on = false
    @Published fileprivate(set) var screenScale: CGFloat = 1
    let native: Bool   // laid out at the window's own size with sizes times k (the picker), not on the 1920 x 1080 canvas scaled (the launcher)
    init(native: Bool = false, onTV: Bool = false, screenScale: CGFloat = 1) {
        self.native = native
        self.onTV = onTV
        self.screenScale = screenScale
        token = NotificationCenter.default.addObserver(forName: Notification.Name("DMShellChanged"), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    // On the TV's window, or console mode with the picture moved to the iPad before the game (front_ios_tv_waiting): the same layout then, fitted to the
    // iPad's screen, as the user asked (one look per mode, not per screen)
    fileprivate var onTV = false { didSet { refresh() } }
    private var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    private func refresh() {
        let now = onTV   // the TV's window only: in handheld mode the TV shows its own copy at the TV's size, the iPad keeps the iPad's layout
        if now != on { on = now }   // at once: animated, every text and box of the screen moved to its new size on its own when the launcher opened
    }
}
// Reads the role of the scene the view's window belongs to and its screen's scale; the picker moving between the iPad and the TV (the same controller,
// presented again) moves it too. On the TV it then raises the hosting controller's display scale by the canvas's scale-up (TenFootStage), so its layers
// (text, the list's cells, images) are drawn at the size they end up on the TV, not at 1920 x 1080 stretched. The traits are only written, a turn later:
// reading traitOverrides.displayScale while it is not set asserts, which closed art45 at launch
private struct TenFootProbe: UIViewRepresentable {
    let tv: TenFoot
    final class Probe: UIView {
        weak var tv: TenFoot?
        private var applied: CGFloat = 0   // the display scale this probe set (0: none)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let w = window else { return }
            let now = w.windowScene?.session.role == .windowExternalDisplayNonInteractive
            let scale = w.windowScene?.screen.scale ?? 1
            let u = now ? TenFootStage.scale(w.bounds.size) : 1
            let t = tv
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.window === w else { return }
                if let t {
                    if t.screenScale != scale { t.screenScale = scale }
                    if t.onTV != now { t.onTV = now }
                }
                guard let vc = sequence(first: self as UIResponder, next: { $0.next }).first(where: { $0 is UIViewController }) as? UIViewController else { return }
                let sharp = now && u > 1.01 && t?.native != true ? scale * u : 0
                if sharp == self.applied { return }
                if sharp > 0 { vc.traitOverrides.displayScale = sharp } else { vc.traitOverrides.remove(UITraitDisplayScale.self) }
                self.applied = sharp
            }
        }
    }
    func makeUIView(context: Context) -> Probe { let v = Probe(); v.isUserInteractionEnabled = false; v.tv = tv; return v }
    func updateUIView(_ v: Probe, context: Context) { v.tv = tv }
}
// On the TV the screen is laid out on a 1920 x 1080 canvas and scaled to the TV's window, so it fills the same share of any TV or projector: a TV's window
// can be 1920, 2560 or 3840 points across, where sizes in points came out a fraction of the screen
struct TenFootStage: ViewModifier {
    let on: Bool
    var screenScale: CGFloat = 1
    var native = false
    static func scale(_ size: CGSize) -> CGFloat { max(0.5, min(size.width / 1920, size.height / 1080)) }
    func body(content: Content) -> some View {
        // Always the same structure (scale 1 on the iPad), so the screen's own state and its onAppear do not start over when it moves to the TV
        GeometryReader { g in
            let u = on ? TenFootStage.scale(g.size) : 1
            let s = native ? 1 : u   // native: no stretching, the sizes are k times instead
            content.environment(\.uiK, native ? u : 1)
                .frame(width: g.size.width / s, height: g.size.height / s)
                // drawn at the size it ends up on the TV, not at the canvas's size stretched (soft on a 1440p or 4K TV); the iPad keeps its own
                .transformEnvironment(\.displayScale) { if on && s > 1.01 { $0 = screenScale * s } }
                .scaleEffect(s, anchor: .topLeading)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: on ? Edge.Set.all : [])
    }
}
extension View {
    // The probe and, on the TV, the canvas: the outermost modifiers of the picker's and the launcher's screens
    func tenFoot(_ tv: TenFoot) -> some View { modifier(TenFootStage(on: tv.on, screenScale: tv.screenScale, native: tv.native)).background(TenFootProbe(tv: tv)) }
}
// Console mode: shown in handheld mode while a TV is connected and the game has not started (front_ios.m answers, again on each DMShellChanged), on the
// iPad and on the TV's copy alike (the copy's is not tapped: a controller switches there); a tap moves the picture to the TV. In the picker's title bar
// and next to the launcher's Game list
@_silgen_name("front_ios_tv_waiting") fileprivate func frontIosTvWaiting() -> Int32
@_silgen_name("front_ios_back_to_tv") private func frontIosBackToTv()
struct BackToTVButton: View {
    @State private var waiting = frontIosTvWaiting() != 0
    @Environment(\.uiK) private var k
    @Environment(\.tenFoot) private var tenFoot   // on the iPad only: the TV looks the same in both modes, its footer's Home hint switches
    var body: some View {
        Group {
            if waiting && !tenFoot {
                Button { frontIosBackToTv() } label: {
                    HStack(spacing: 10) {
                        Label(tr("主機模式", "Console mode"), systemImage: "tv").font(.ds(.headline, k: k))
                        // a controller's Home (Xbox, − and + together, the phone page's ⌂) switches too, before the game (front_ios.m)
                        Text("Home").font(.ds(.caption, .bold, k: k)).padding(.horizontal, 6 * k).frame(minHeight: 22 * k)
                            .background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(Color.white.opacity(0.22)))
                    }
                    .foregroundStyle(.white)
                        .padding(.horizontal, 14 * k).padding(.vertical, 10 * k)
                        .background(RoundedRectangle(cornerRadius: 12 * k, style: .continuous).fill(DS.accent))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: waiting)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMShellChanged")).receive(on: DispatchQueue.main)) { _ in
            waiting = frontIosTvWaiting() != 0
        }
        .onAppear { waiting = frontIosTvWaiting() != 0 }
    }
}

// Handheld mode with a TV connected: the TV shows the same screen as the iPad, laid out for its own size, following every move (front_ios.m puts
// dm_pregame_mirror_make's controller in the TV's window). The picker and the launcher set what it shows; the copy there takes no input and posts nothing
// The picker's copy stays built while a game's launcher is over it (as on the iPad, where the picker's model is kept), so coming back shows it at once:
// building it again at the TV's size made the TV come back well after the iPad
final class PregameStage: ObservableObject {
    static let shared = PregameStage()
    @Published private(set) var pickerGen = 0
    @Published private(set) var launcherGen = 0
    private(set) var picker: (() -> AnyView)?
    private(set) var launcher: (() -> AnyView)?
    func showPicker(_ make: @escaping () -> AnyView, fresh: Bool) {
        if fresh || picker == nil { picker = make; pickerGen += 1 }
        if launcher != nil { launcher = nil; launcherGen += 1 }
    }
    func showLauncher(_ make: @escaping () -> AnyView) { launcher = make; launcherGen += 1 }
    func clear() { picker = nil; launcher = nil; pickerGen += 1; launcherGen += 1 }   // the game starts
}
private struct PregameMirrorKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var pregameMirror: Bool { get { self[PregameMirrorKey.self] } set { self[PregameMirrorKey.self] = newValue } } }
private struct PregameMirrorView: View {
    @ObservedObject private var stage = PregameStage.shared
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let picker = stage.picker { picker().id(stage.pickerGen).accessibilityHidden(stage.launcher != nil) }
            if let launcher = stage.launcher { launcher().id(stage.launcherGen).transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.25), value: stage.launcherGen)
        .environment(\.pregameMirror, true)
        .preferredColorScheme(.dark)
    }
}
@_cdecl("dm_pregame_mirror_make")
public func dmPregameMirrorMake() -> UnsafeMutableRawPointer {   // a retained UIViewController (CFBridgingRelease it on the Objective-C side)
    let h = UIHostingController(rootView: PregameMirrorView())
    controllerNotForUIKit(h.view)   // Launcher.swift
    h.view.backgroundColor = .black
    h.view.isUserInteractionEnabled = false
    return Unmanaged.passRetained(h as UIViewController).toOpaque()
}

// On the settings screen, let the initial list layout settle during the presentation fade.
private struct Settle: ViewModifier {
    @State private var settled = false
    func body(content: Content) -> some View {
        content
            .transaction { if !settled { $0.animation = nil; $0.disablesAnimations = true } }
            .task { try? await Task.sleep(for: .seconds(0.6)); settled = true }
    }
}
extension View { func settleOnArrival() -> some View { modifier(Settle()) } }

private struct TenFootKey: EnvironmentKey { static let defaultValue = false }
// The picker on a TV is laid out at the TV's own size (not a 1920 x 1080 canvas stretched, whose text stayed soft on a 4K TV): every size in it is the
// ten-foot size times k, the TV's size over 1920 x 1080 (1 on the iPad's own layout)
private struct UiKKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues { var uiK: CGFloat { get { self[UiKKey.self] } set { self[UiKKey.self] = newValue } } }
extension Font {
    // A text style: Dynamic Type's at k 1; else its ten-foot size (Dynamic Type's accessibility-1 size, the TV layout's) times k
    static func ds(_ style: Font.TextStyle, _ weight: Font.Weight? = nil, design: Font.Design? = nil, k: CGFloat) -> Font {
        if abs(k - 1) < 0.001 { return .system(style, design: design, weight: weight) }
        let size: CGFloat
        switch style {
        case .largeTitle: size = 44
        case .title: size = 38
        case .title2: size = 34
        case .title3: size = 31
        case .callout: size = 26
        case .subheadline: size = 25
        case .footnote: size = 23
        case .caption: size = 22
        case .caption2: size = 20
        default: size = 28   // body, headline
        }
        return .system(size: size * k, weight: weight ?? (style == .headline ? .semibold : .regular), design: design ?? .default)
    }
}
extension EnvironmentValues { var tenFoot: Bool { get { self[TenFootKey.self] } set { self[TenFootKey.self] = newValue } } }

// A frosted card: thick dark material, the card tint, a hairline edge and a soft shadow (front_ios.m's menu card)
struct GlassCard: ViewModifier {
    var radius: CGFloat = DS.cardRadius
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.thickMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.card.opacity(0.55)))
                    .environment(\.colorScheme, .dark)
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
}
extension View { func glassCard(_ radius: CGFloat = DS.cardRadius) -> some View { modifier(GlassCard(radius: radius)) } }
// A key's name in a small box, then what it does: the footer hints of the picker and the launcher
struct KeyHint: View {
    let key: String, text: String
    @Environment(\.uiK) private var k
    var body: some View {
        HStack(spacing: 6 * k) {
            Text(key).font(.ds(.caption, .bold, k: k)).frame(minWidth: 22 * k, minHeight: 22 * k).padding(.horizontal, key.count > 1 ? 4 * k : 0)
                .background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(Color.white.opacity(0.16)))
            Text(text)
        }
    }
}
private let systemBlue = DS.accent
private func tileRadius(_ side: CGFloat) -> CGFloat { side * 0.2237 }   // the home screen's icon corner
private struct FocusRing: ViewModifier {
    let focused: Bool
    let side: CGFloat
    var grid = false   // in the all-games grid the others stay near full size and bright: they are what the eye looks through
    @Environment(\.uiK) private var k
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: tileRadius(side) + 7 * k, style: .continuous)
                    .strokeBorder(focused ? Color.white.opacity(0.95) : .clear, lineWidth: 4 * k)
                    .padding((grid ? -6 : -10) * k)
            }
            .shadow(color: .black.opacity(focused ? 0.55 : 0.4), radius: (focused ? 22 : 8) * k, y: (focused ? 14 : 4) * k)
            .scaleEffect(focused || grid ? 1 : 0.84)
            .opacity(focused || grid ? 1 : 0.6)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: focused)
    }
}
private struct Chip: View {   // a small rounded box: version, last played, a key's name
    let text: String
    @Environment(\.uiK) private var k
    var body: some View {
        Text(text).font(.ds(.footnote, .semibold, k: k)).foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 9 * k).padding(.vertical, 4 * k)
            .background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(DS.chip))
    }
}

private struct PickerGame: Identifiable {
    let id: String          // title ID: the folder's name
    let name: String
    let version: String
    let icon: UIImage?
    let played: Date?
}
private let pickerOrderKey = "picker.gameOrder"

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
    let desktop = gameOrder()
    let local = localGameOrder(desktop: desktop)
    let rank = Dictionary((local + desktop).enumerated().map { ($1.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
    return list.sorted {
        switch (rank[$0.id.uppercased()], rank[$1.id.uppercased()]) {
        case let (a?, b?): return a < b
        case (.some, nil): return true
        case (nil, .some): return false
        default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
private func gameOrder() -> [String] {
    // the system folder of the reorganised Documents (main.m moves the file there), Documents/ before
    guard let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
          let data = (try? Data(contentsOf: doc.appendingPathComponent("\u{7CFB}\u{7D71}/game-order.json"))) ?? (try? Data(contentsOf: doc.appendingPathComponent("game-order.json"))),
          let ids = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
    var seen = Set<String>()
    return ids.compactMap { id in
        guard let title = (id as? String)?.uppercased(), seen.insert(title).inserted else { return nil }
        return title
    }
}
private func localGameOrder(desktop: [String]) -> [String] {
    // A routine sync can add or remove games, but should keep the iPad's order.
    // A different order of the same titles indicates a desktop edit.
    let defaults = UserDefaults.standard
    guard let saved = defaults.dictionary(forKey: pickerOrderKey), let local = saved["local"] as? [String],
          let previous = saved["desktop"] as? [String] else { return [] }
    if desktop != previous && !desktop.isEmpty {
        let common = Set(desktop).intersection(previous)
        if desktop.filter(common.contains) != previous.filter(common.contains) {
            defaults.removeObject(forKey: pickerOrderKey)
            return []
        }
        defaults.set(["local": local, "desktop": desktop], forKey: pickerOrderKey)
    }
    return local
}

// The row: the phones' tile at 0, then the games (game i at i + 1). It goes round: after the last game comes the phones' tile again, so the
// row is a ring and pos counts places along it without end (focus is the item there). It opens on the phones' tile, whose QR code is what a
// player needs first
private final class PickerModel: ObservableObject {
    @Published private(set) var games: [PickerGame]
    @Published var pos = 0
    static var lastPicked: String?   // the game chosen last: coming back from its launcher, the row stands on it again (not on Add players)
    static var kept: PickerModel?    // one model for the process: the picker shown again (back from a launcher) keeps its place, and the TV's copy its view
    init() {
        games = loadGames()
        if let id = PickerModel.lastPicked, let i = games.firstIndex(where: { $0.id == id }) { pos = i + 1 }
    }
    var focus: Int { ((pos % count) + count) % count }
    func item(_ v: Int) -> Int { ((v % count) + count) % count }
    @Published var starting = false
    @Published var padsOpen = false
    @Published var settingsOpen = false
    @Published var setting = 0
    @Published var confirmingExit = false
    @Published var gridOpen = false   // every game at once (X, or the button at the top); kept while a game's launcher is over the picker
    var reorderingGames = false
    var gridCols = 6                  // the grid's columns, as laid out (the arrows move by them)
    @Published var sel = 0   // the highlighted place on the players card (player sel + 1)
    @Published var picked: Int?   // a player picked up to move to another number (A or a tap, then A or a tap on the place; or dragged there)
    var count: Int { games.count + 1 }
    func game(_ i: Int) -> PickerGame? { games.indices.contains(i - 1) ? games[i - 1] : nil }
    var start: (PickerGame) -> Void = { _ in }
    func move(_ d: Int) { if !starting { pos += d } }
    func showGrid(_ on: Bool) {
        guard !starting, !reorderingGames, !games.isEmpty, on != gridOpen else { return }
        if on && focus == 0 { pos += 1 }   // on the phones' tile: the first game
        gridOpen = on
    }
    // In the grid: left and right go one game (on to the next row), up and down a row; the last row's gap takes down to the last game
    func gridMove(_ key: String) {
        guard !starting, !reorderingGames, !games.isEmpty else { return }
        let n = games.count, c = max(1, gridCols), i = max(0, focus - 1)
        var j = i
        switch key {
        case "left": j = i - 1
        case "right": j = i + 1
        case "up": j = i - c
        case "down": j = i + c < n ? i + c : (i / c < (n - 1) / c ? n - 1 : i)
        default: break
        }
        guard j >= 0, j < n, j != i || focus == 0 else { return }
        pos += j + 1 - focus
    }
    func reorderGame(from source: Int, to destination: Int) {
        guard games.indices.contains(source), games.indices.contains(destination), source != destination else { return }
        let oldFocus = focus
        let focusedID = game(oldFocus)?.id
        var ordered = games
        let game = ordered.remove(at: source)
        ordered.insert(game, at: destination)
        UserDefaults.standard.set(["local": ordered.map(\.id), "desktop": gameOrder()], forKey: pickerOrderKey)
        games = ordered
        if let focusedID, let index = ordered.firstIndex(where: { $0.id == focusedID }) {
            pos += index + 1 - oldFocus
        }
    }
    func choose(at v: Int? = nil) {   // the item at place v of the ring (the focused one when nil)
        guard !starting, !reorderingGames else { return }
        if let v { pos = v }
        if let g = game(focus) { starting = true; start(g) } else { padsOpen = true }
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
    @Environment(\.uiK) private var k
    var body: some View {
        HStack(spacing: 14 * k) {
            TimelineView(.everyMinute) { t in Text(t.date, style: .time).monospacedDigit() }   // redrawn on each new minute
            Image(systemName: !s.online ? "wifi.slash" : s.wifi ? "wifi" : "network")
                .opacity(s.online ? 1 : 0.5)
                .accessibilityLabel(s.online ? tr("已連線", "Online") : tr("未連線", "Offline"))
            HStack(spacing: 5 * k) {
                if s.battery >= 0 { Text("\(Int((s.battery * 100).rounded()))%").monospacedDigit() }
                Image(systemName: s.batterySymbol)
                    .foregroundStyle(s.battery >= 0 && s.battery < 0.2 && !s.charging ? Color.red : Color.white)
            }
        }
        .font(.ds(.title3, .medium, k: k))
        .foregroundStyle(.white.opacity(0.85))
    }
}

// A game's icon is the package's 256 x 256 JPEG; on a TV a tile is 700 to 1000 pixels across. Enlarged once with Lanczos (sharper edges than the GPU's
// linear filter), up to 1024 pixels, and kept
private let sharpIcons = NSCache<NSString, UIImage>()
private let ciContext = CIContext(options: [.cacheIntermediates: false])   // one for every icon (a context per call cost more than the filter)
func tvIcon(_ img: UIImage, key: String? = nil) -> UIImage {   // key: for an icon read from its file again on every redraw (the launcher's)
    let k = (key ?? "\(ObjectIdentifier(img).hashValue)") as NSString
    if let done = sharpIcons.object(forKey: k) { return done }
    let px = max(img.size.width * img.scale, img.size.height * img.scale)
    guard px > 0, px < 1000, let src = CIImage(image: img) else { return img }
    let f = CIFilter.lanczosScaleTransform(); f.inputImage = src; f.scale = Float(1024 / px); f.aspectRatio = 1
    guard let out = f.outputImage, let cg = ciContext.createCGImage(out, from: out.extent.integral) else { return img }
    let big = UIImage(cgImage: cg, scale: img.scale * 1024 / px, orientation: img.imageOrientation)
    sharpIcons.setObject(big, forKey: k)
    return big
}

// The blurred icon behind the picker and the launcher, blurred once on a small copy and kept: a live 60-point blur of a screen-sized image (two of them
// while the backdrop cross-fades) was redrawn on every frame of a move, and on a 4K TV that made the moves stutter
private let blurredIcons = NSCache<NSString, UIImage>()
func blurredIcon(_ img: UIImage, key: String) -> UIImage? {
    if let done = blurredIcons.object(forKey: key as NSString) { return done }
    guard let src = CIImage(image: img), src.extent.width > 0 else { return nil }
    let small = src.transformed(by: CGAffineTransform(scaleX: 96 / src.extent.width, y: 96 / src.extent.width))
    let f = CIFilter.gaussianBlur(); f.inputImage = small.clampedToExtent(); f.radius = 5
    guard let out = f.outputImage?.cropped(to: small.extent), let cg = ciContext.createCGImage(out, from: small.extent) else { return nil }
    let done = UIImage(cgImage: cg)
    blurredIcons.setObject(done, forKey: key as NSString)
    return done
}

private struct GameTile: View {
    let game: PickerGame
    let focused: Bool
    let side: CGFloat
    var grid = false
    @Environment(\.tenFoot) private var tenFoot
    @Environment(\.uiK) private var k
    var body: some View {
        ZStack {
            if let icon = game.icon {
                Image(uiImage: tenFoot ? tvIcon(icon, key: game.id) : icon).resizable().interpolation(.high).antialiased(true).scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.29), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                Text(game.name).font(.ds(.title3, .bold, k: k)).foregroundStyle(.white).multilineTextAlignment(.center).padding(12 * k)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: tileRadius(side), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: tileRadius(side), style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .modifier(FocusRing(focused: focused, side: side, grid: grid))
    }
}

private struct PadsTile: View {
    let qr: UIImage?
    let joined: [Int]
    let focused: Bool
    let side: CGFloat
    @Environment(\.uiK) private var k
    var body: some View {
        let mark = side * 0.032
        ZStack {
            Color.white
            if let qr {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: side * 0.74, height: side * 0.74)
                    .offset(y: joined.isEmpty ? 0 : -side * 0.028)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash").font(.system(size: side * 0.18))
                    Text(tr("連上 Wi-Fi 後\n手機才能加入", "Join Wi-Fi\nto let phones in")).font(.ds(.headline, k: k)).multilineTextAlignment(.center)
                }
                .foregroundStyle(.black.opacity(0.55))
            }
            HStack(spacing: mark * 0.42) {
                ForEach(joined.sorted(), id: \.self) { player in
                    RoundedRectangle(cornerRadius: mark * 0.22, style: .continuous)
                        .fill(playerColors[(player - 1) % playerColors.count]).frame(width: mark, height: mark)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, side * 0.047)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: tileRadius(side), style: .continuous))
        .modifier(FocusRing(focused: focused, side: side))
        .accessibilityLabel(tr("加入玩家", "Add players"))
    }
}

// The controllers removed on the card (or in the launcher) take the free places in order, so each can be added back from where it shows
private func removedAt(_ i: Int, _ players: PlayersModel) -> RemovedPad? {
    let free = (0..<8).filter { k in !players.players.contains { $0.player == k + 1 } }
    guard let k = free.firstIndex(of: i), players.removed.indices.contains(k) else { return nil }
    return players.removed[k]
}

private struct PlaceFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}

// The players card: the QR code and address on the left, the eight places on the right (two columns of four, so it keeps its size)
private struct PadsCard: View {
    @ObservedObject var m: PickerModel
    @ObservedObject var pads: PadsModel
    @ObservedObject var players: PlayersModel
    let viewport: CGSize
    @EnvironmentObject var activity: ActivityModel
    @Environment(\.uiK) private var k
    @Environment(\.tenFoot) private var tenFoot
    private var t: CGFloat { tenFoot ? k * 0.85 : 1 }
    private var cardWidth: CGFloat { tenFoot ? min(1280 * k, 0.86 * viewport.width) : 980 * k }
    private var qrSide: CGFloat { tenFoot ? min(280 * k, cardWidth * 0.25, viewport.height * 0.34) : 230 * k }
    @ScaledMetric(relativeTo: .title2) private var addressSize: CGFloat = 24
    @State private var frames: [Int: CGRect] = [:]   // each place, in the grid's space: where a dragged player lands
    @State private var dragging: Int?
    @State private var dragOffset: CGSize = .zero
    @State private var dropOn: Int?
    private func place(at p: CGPoint, excluding i: Int) -> Int? {
        frames.first { $0.key != i && $0.value.contains(p) }?.key
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22 * k) {
            HStack {
                Text(tr("玩家", "Players")).font(.ds(.title, .bold, k: t))
                Spacer()
                Text(tr("\(players.players.count) / 8 位玩家", "\(players.players.count) / 8 players")).font(.ds(.headline, k: t)).foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .top, spacing: 28 * k) {
                VStack(spacing: 12 * k) {
                    ZStack {
                        Color.white
                        if let qr = pads.qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().padding(qrSide * 0.12) }
                        else { Image(systemName: "wifi.slash").font(.ds(.largeTitle, k: t)).foregroundStyle(.black.opacity(0.5)) }
                    }
                    .frame(width: qrSide, height: qrSide).clipShape(RoundedRectangle(cornerRadius: 18 * k, style: .continuous))
                    if let url = pads.url {
                        Text(url)
                            .font(tenFoot ? .system(size: max(1, min(24 * k, (qrSide - 20 * k) / (CGFloat(max(1, url.count)) * 0.62))),
                                                   weight: .semibold, design: .monospaced) :
                                    .system(size: addressSize * k, weight: .semibold).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .padding(.horizontal, 10 * k)
                            .frame(width: qrSide).padding(.vertical, 8 * k)
                            .background(RoundedRectangle(cornerRadius: 12 * k, style: .continuous).fill(DS.chip))
                            .accessibilityLabel(url)
                    } else {
                        Text(tr("請先連上 Wi-Fi", "Connect to Wi-Fi first")).font(.ds(.footnote, k: t)).foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: qrSide + 20 * k)
                Grid(horizontalSpacing: 10 * k, verticalSpacing: 10 * k) {
                    ForEach(0..<4, id: \.self) { r in
                        GridRow { place(r); place(r + 4) }
                    }
                }
                .coordinateSpace(name: "pads")
                .onPreferenceChange(PlaceFrames.self) { frames = $0 }
            }
            HStack(spacing: 22 * k) {
                Spacer()
                KeyHint(key: "A", text: m.picked == nil ? tr("換位置", "Move") : tr("放這裡", "Put here")); KeyHint(key: "−", text: tr("切換配置", "Layout")); KeyHint(key: "X", text: tr("移除", "Remove")); KeyHint(key: "B", text: tr("關閉", "Close"))
            }
            .font(.ds(.callout, k: t)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(30 * k)
        .frame(maxWidth: cardWidth)
        .glassCard(DS.cardRadius * k)
        .foregroundStyle(.white)
    }

    @ViewBuilder private func place(_ i: Int) -> some View {
        let n = i + 1, color = playerColors[i % playerColors.count]
        let row = players.players.first { $0.player == n }
        let back = removedAt(i, players)   // a controller removed here, offered in a free place so it can be added back
        let lit = activity.lit.contains(n), sel = m.sel == i
        let picked = m.picked == i || dragging == i, target = (m.picked != nil && sel && m.picked != i) || (dragging != nil && dropOn == i && dragging != i)
        HStack(spacing: 8 * k) {
            Text("P\(n)").font(.ds(.headline, .heavy, k: t)).frame(width: 40 * k, height: 32 * k)
                .foregroundStyle(row == nil ? Color.white.opacity(0.35) : Color.black.opacity(0.85))
                .background(RoundedRectangle(cornerRadius: DS.tileRadius * k, style: .continuous).fill(row == nil ? Color.white.opacity(0.08) : color))
            if let p = row {
                Image(systemName: p.kind == 2 ? "iphone" : controllerIcon(p.label)).font(.ds(.title3, k: t)).frame(width: 28 * k)
                Text(padName(p)).font(.ds(.headline, k: t)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4 * k)
                Button { players.send(["op": "layout", "p": n, "xbox": p.xbox ? 0 : 1]) } label: {
                    Text((p.xbox ? "Xbox" : "Switch") + " ⇄")
                        .font(.ds(.footnote, .semibold, k: t))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 9 * k).padding(.vertical, 4 * k)
                        .background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(DS.chip))
                }
                .buttonStyle(.plain).accessibilityLabel(tr("切換配置", "Button layout"))
                .layoutPriority(1)
                Button { players.send(["op": "kick", "p": n]) } label: {
                    Image(systemName: "xmark").font(.ds(.footnote, .bold, k: t)).frame(width: 30 * k, height: 30 * k).background(RoundedRectangle(cornerRadius: DS.chipRadius * k, style: .continuous).fill(DS.chip))
                }
                .buttonStyle(.plain).accessibilityLabel(tr("移除", "Remove"))
            } else if let r = back {
                Image(systemName: controllerIcon(r.label)).font(.ds(.title3, k: t)).frame(width: 28 * k).foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(padName(PlayerRow(player: 0, kind: 1, label: r.label, name: "", xbox: false))).font(.ds(.headline, k: t)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Text(tr("已移除 · 按 A 加回", "Removed · A to add back")).font(.ds(.caption, k: t)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            } else {
                Text(tr("空位", "Free")).font(.ds(.headline, .regular, k: t)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 36 * k)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12 * k)
        .frame(height: max(64 * k, qrSide / 4))
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: DS.rowRadius * k, style: .continuous)
                .fill(row == nil ? Color.clear : lit ? color.opacity(0.3) : DS.plate)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.rowRadius * k, style: .continuous)
                .strokeBorder(picked || sel ? systemBlue : row == nil ? Color.white.opacity(0.12) : lit ? color : .clear,
                              style: StrokeStyle(lineWidth: (picked ? 3 : sel ? 2 : row == nil ? 1.5 : 1) * k, dash: (row == nil && !sel) || target ? [5 * k, 4 * k] : []))
        }
        .background(GeometryReader { g in Color.clear.preference(key: PlaceFrames.self, value: [i: g.frame(in: .named("pads"))]) })
        .scaleEffect(picked ? 1.04 : lit ? 1.02 : 1)
        .shadow(color: .black.opacity(picked ? 0.5 : 0), radius: 16 * k, y: 8 * k)
        .offset(dragging == i ? dragOffset : .zero)
        .zIndex(dragging == i ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: lit)
        .animation(DS.spring, value: sel)
        .animation(DS.spring, value: picked)
        .contentShape(Rectangle())
        .onTapGesture {   // Tap a player to pick it up, then tap another place to move or swap.
            m.sel = i
            if let p = m.picked {
                if p != i { players.send(["op": "swap", "a": p + 1, "b": n]) }
                m.picked = nil
            } else if row != nil {
                m.picked = i
            }
            else if let r = back { players.send(["op": "add", "index": r.index]) }
        }
        .gesture(DragGesture(minimumDistance: 10, coordinateSpace: .named("pads"))   // or drag a player onto another place
            .onChanged { v in
                dragging = i; m.picked = nil
                dragOffset = v.translation
                dropOn = place(at: v.location, excluding: i)
            }
            .onEnded { v in
                if let to = place(at: v.location, excluding: i) {
                    players.send(["op": "swap", "a": n, "b": to + 1])
                    m.sel = to
                }
                withAnimation(DS.spring) { dragging = nil; dragOffset = .zero; dropOn = nil }
            }, including: row == nil ? .subviews : .all)   // only occupied slots can start a drag
    }
}

private struct GridGameTile: View {
    let game: PickerGame
    let focused: Bool
    let side: CGFloat
    let width: CGFloat
    var captionHeight: CGFloat? = nil
    @Environment(\.uiK) private var k

    var body: some View {
        VStack(spacing: 14 * k) {
            GameTile(game: game, focused: focused, side: side, grid: true)
            Text(game.name).font(.ds(.footnote, focused ? .bold : .semibold, k: k)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.white.opacity(focused ? 1 : 0.65)).frame(width: width, height: captionHeight)
        }
        .padding(.top, 12 * k)
    }
}

// The touch grid uses the collection view's lift, insertion, edge scrolling and drop animations.
// Its cells render the same tiles as the controller grid.
private struct TouchGameGrid: UIViewRepresentable {
    let m: PickerModel
    let width: CGFloat
    let cols: Int
    let side: CGFloat
    let gap: CGFloat
    @Environment(\.uiK) private var k
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var captionHeight: CGFloat = 18

    struct Appearance: Equatable {
        let width: CGFloat
        let cols: Int
        let side: CGFloat
        let gap: CGFloat
        let k: CGFloat
        let textSize: DynamicTypeSize
        let captionHeight: CGFloat
        let reduceMotion: Bool
        var itemWidth: CGFloat { side + 0.8 * gap }

        func apply(to layout: UICollectionViewFlowLayout) {
            let spacing = 0.2 * gap
            let rowWidth = CGFloat(cols) * itemWidth + CGFloat(cols - 1) * spacing
            let inset = max(0, (width - rowWidth) / 2 - 0.5)
            layout.itemSize = CGSize(width: itemWidth, height: side + 26 * k + captionHeight)
            layout.minimumInteritemSpacing = spacing
            layout.minimumLineSpacing = 26 * k
            layout.sectionInset = UIEdgeInsets(top: 20 * k, left: inset, bottom: 20 * k, right: inset)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(m) }
    func makeUIView(context: Context) -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.showsVerticalScrollIndicator = false
        view.dragInteractionEnabled = true
        view.reorderingCadence = .fast
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "game")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.dragDelegate = context.coordinator
        view.dropDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let appearance = Appearance(width: width, cols: cols, side: side, gap: gap, k: k, textSize: textSize,
                                    captionHeight: captionHeight * k, reduceMotion: reduceMotion)
        context.coordinator.update(in: view, appearance: appearance)
    }
    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
        coordinator.endDrag()
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
                             UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        let m: PickerModel
        private var appearance: Appearance?
        private var focusedID: String?
        private var draggedID: String?

        init(_ model: PickerModel) { m = model }

        func update(in view: UICollectionView, appearance: Appearance) {
            let previous = self.appearance
            let styleChanged = previous != appearance
            self.appearance = appearance
            if styleChanged, let layout = view.collectionViewLayout as? UICollectionViewFlowLayout {
                appearance.apply(to: layout)
            }
            let nextFocus = m.game(m.focus)?.id
            let focusChanged = focusedID != nextFocus
            focusedID = nextFocus
            if styleChanged || focusChanged {
                for cell in view.visibleCells {
                    if let path = view.indexPath(for: cell) { configure(cell, at: path) }
                }
            }
            guard (focusChanged || styleChanged), !m.reorderingGames, !m.starting, let nextFocus else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.focusedID == nextFocus,
                      !self.m.reorderingGames, !self.m.starting, view.window != nil, view.bounds.height > 0,
                      let index = self.m.games.firstIndex(where: { $0.id == nextFocus }) else { return }
                view.layoutIfNeeded()
                view.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically,
                                  animated: previous != nil && !appearance.reduceMotion)
            }
        }

        private func configure(_ cell: UICollectionViewCell, at indexPath: IndexPath) {
            guard let appearance, let game = m.game(indexPath.item + 1) else { return }
            let focused = game.id == focusedID
            cell.contentConfiguration = UIHostingConfiguration {
                GridGameTile(game: game, focused: focused, side: appearance.side, width: appearance.itemWidth,
                             captionHeight: appearance.captionHeight)
                    .environment(\.uiK, appearance.k).dynamicTypeSize(appearance.textSize)
            }.margins(.all, 0)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = game.name
            cell.accessibilityTraits = .button
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { m.games.count }
        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "game", for: path)
            configure(cell, at: path)
            return cell
        }
        func collectionView(_ view: UICollectionView, canFocusItemAt path: IndexPath) -> Bool { false }
        func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
            view.deselectItem(at: path, animated: false)
            m.choose(at: m.pos + path.item + 1 - m.focus)
        }

        func collectionView(_ view: UICollectionView, itemsForBeginning session: UIDragSession, at path: IndexPath) -> [UIDragItem] {
            guard m.gridOpen, !m.padsOpen, !m.starting, !m.reorderingGames, m.games.count > 1,
                  let game = m.game(path.item + 1) else { return [] }
            let item = UIDragItem(itemProvider: NSItemProvider(object: game.name as NSString))
            item.localObject = game.id
            session.localContext = view
            draggedID = game.id
            return [item]
        }
        func collectionView(_ view: UICollectionView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool { true }
        func collectionView(_ view: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func collectionView(_ view: UICollectionView, dragSessionWillBegin session: UIDragSession) { m.reorderingGames = true }
        func collectionView(_ view: UICollectionView, dragSessionDidEnd session: UIDragSession) { endDrag() }
        func collectionView(_ view: UICollectionView, dragPreviewParametersForItemAt path: IndexPath) -> UIDragPreviewParameters? { iconPreview() }
        func collectionView(_ view: UICollectionView, dropPreviewParametersForItemAt path: IndexPath) -> UIDragPreviewParameters? { iconPreview() }
        private func iconPreview() -> UIDragPreviewParameters? {
            guard let appearance else { return nil }
            let side = appearance.side
            let rect = CGRect(x: (appearance.itemWidth - side) / 2, y: 12 * appearance.k, width: side, height: side)
            let preview = UIDragPreviewParameters()
            preview.backgroundColor = .clear
            preview.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: tileRadius(side))
            return preview
        }
        func endDrag() {
            guard draggedID != nil else { return }
            draggedID = nil
            m.reorderingGames = false
        }

        func collectionView(_ view: UICollectionView, canHandle session: UIDropSession) -> Bool {
            guard let draggedID, m.gridOpen, !m.padsOpen, !m.starting,
                  (session.localDragSession?.localContext as? UICollectionView) === view else { return false }
            return session.items.count == 1 && (session.items.first?.localObject as? String) == draggedID
        }
        func collectionView(_ view: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destination: IndexPath?) -> UICollectionViewDropProposal {
            guard collectionView(view, canHandle: session) else { return UICollectionViewDropProposal(operation: .forbidden) }
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        func collectionView(_ view: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard collectionView(view, canHandle: coordinator.session), let item = coordinator.items.first,
                  let source = item.sourceIndexPath, m.game(source.item + 1)?.id == draggedID,
                  let destination = dropDestination(in: view, for: coordinator) else { return }
            if source != destination {
                view.performBatchUpdates {
                    withAnimation(self.appearance?.reduceMotion == true ? nil : DS.spring) {
                        self.m.reorderGame(from: source.item, to: destination.item)
                    }
                    view.moveItem(at: source, to: destination)
                }
            }
            coordinator.drop(item.dragItem, toItemAt: destination)
        }
        private func dropDestination(in view: UICollectionView, for drop: UICollectionViewDropCoordinator) -> IndexPath? {
            let last = IndexPath(item: m.games.count - 1, section: 0)
            if let proposed = drop.destinationIndexPath {
                return IndexPath(item: min(proposed.item, last.item), section: 0)
            }
            // A release below a short last row can place the game at the end.
            let point = drop.session.location(in: view)
            guard let attributes = view.layoutAttributesForItem(at: last), point.y > attributes.frame.midY else { return nil }
            return last
        }
    }
}

// Both grids share PickerModel, including the selection and the order shown in the carousel.
private struct GameGrid: View {
    @ObservedObject var m: PickerModel
    let width: CGFloat
    let cols: Int
    @Environment(\.uiK) private var k
    @Environment(\.tenFoot) private var tenFoot
    @Environment(\.pregameMirror) private var mirror
    var body: some View {
        let pad = min(48 * k, width * 0.1), gap = 28 * k
        let columns = max(1, min(cols, Int((width - 2 * pad + gap) / (60 + gap))))
        let side = max(1, ((width - 2 * pad - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down))
        Group {
            if tenFoot || mirror {
                controllerGrid(pad: pad, gap: gap, side: side, columns: columns)
            } else {
                TouchGameGrid(m: m, width: width, cols: columns, side: side, gap: gap)
            }
        }
        .clipped()
        .onChange(of: columns, initial: true) { _, c in if !mirror { m.gridCols = c } }
    }

    private func controllerGrid(pad: CGFloat, gap: CGFloat, side: CGFloat, columns: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: gap), count: columns), spacing: 26 * k) {
                    ForEach(Array(m.games.enumerated()), id: \.element.id) { i, g in
                        let on = m.focus == i + 1
                        GridGameTile(game: g, focused: on, side: side, width: side + gap * 0.8)
                            .contentShape(Rectangle())
                            .onTapGesture { m.choose(at: m.pos + i + 1 - m.focus) }
                            .accessibilityLabel(g.name).accessibilityAddTraits(.isButton)
                            .id(g.id)
                    }
                }
                .padding(.horizontal, pad).padding(.vertical, 20 * k)
                .animation(DS.spring, value: m.pos)
            }
            .onChange(of: m.pos) { _, _ in if let id = m.game(m.focus)?.id { withAnimation(DS.spring) { proxy.scrollTo(id, anchor: .center) } } }
            .onAppear { if let id = m.game(m.focus)?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

private struct PickerSettingsCard: View {
    @ObservedObject var m: PickerModel
    let k: CGFloat
    @State private var volume = pickerVolume()
    @State private var outputs = pickerOutputs()

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * k) {
            Text(m.confirmingExit ? tr("關閉 SwitchPad？", "Close SwitchPad?") : tr("SwitchPad 設定", "SwitchPad settings"))
                .font(.ds(.title2, .bold, k: k)).padding(.bottom, 8 * k)
            if m.confirmingExit {
                option(0, "arrow.uturn.left", tr("取消", "Cancel")) { m.confirmingExit = false; m.setting = 3 }
                option(3, "power", tr("關閉 SwitchPad", "Close SwitchPad")) { pickerAction(3) }
            } else {
                VStack(alignment: .leading, spacing: 2 * k) {
                    Label(tr("音量 ", "Volume ") + String(Int((volume * 100).rounded())) + "%", systemImage: "speaker.wave.2.fill")
                        .font(.ds(.headline, .semibold, k: k))
                    Slider(value: Binding(get: { volume }, set: {
                        m.setting = 0
                        volume = $0
                        setPickerVolume($0)
                    }), in: 0...1, step: 0.01)
                    .accessibilityLabel(tr("音量", "Volume"))
                }
                .padding(.horizontal, 14 * k).padding(.vertical, 8 * k)
                .background(m.setting == 0 ? DS.accent : DS.plate, in: RoundedRectangle(cornerRadius: 12 * k))
                if outputs & 1 != 0 {
                    option(1, "display", tr("畫面模式", "Display mode"),
                           outputs & 2 == 0 ? tr("主機模式", "Console") : tr("掌機模式", "Handheld")) { pickerAction(1) }
                    option(2, "speaker.wave.2", tr("聲音輸出", "Audio output"),
                           outputs & 4 == 0 ? tr("外接螢幕", "External display") : "iPad") { pickerAction(2) }
                }
                option(3, "power", tr("關閉 SwitchPad", "Close SwitchPad")) {
                    m.confirmingExit = true
                    m.setting = 0
                }
                Button { m.settingsOpen = false } label: {
                    KeyHint(key: "B", text: tr("返回", "Back"))
                        .font(.ds(.callout, k: k))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 6 * k)
                }.buttonStyle(.plain)
            }
        }
        .padding(22 * k)
        .frame(maxWidth: 510 * k)
        .foregroundStyle(.white)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.cardRadius * k))
        .overlay { RoundedRectangle(cornerRadius: DS.cardRadius * k).strokeBorder(DS.hairline).allowsHitTesting(false) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMShellChanged"))) { _ in
            volume = pickerVolume()
            outputs = pickerOutputs()
            if outputs & 1 == 0 && (m.setting == 1 || m.setting == 2) { m.setting = 0 }
        }
    }

    private func option(_ id: Int, _ icon: String, _ title: String, _ detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            m.setting = id
            action()
        } label: {
            HStack(spacing: 10 * k) {
                Label(title, systemImage: icon)
                Spacer(minLength: 4 * k)
                if let detail { Text(detail).opacity(0.85).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .font(.ds(.headline, .semibold, k: k)).lineLimit(1)
            .padding(.horizontal, 14 * k).padding(.vertical, 12 * k)
            .background(m.setting == id ? DS.accent : DS.plate, in: RoundedRectangle(cornerRadius: 12 * k))
        }.buttonStyle(.plain)
    }
}

private struct PickerView: View {
    @ObservedObject var m: PickerModel
    @StateObject private var pads = PadsModel()
    @StateObject private var players = PlayersModel()   // Launcher.swift: the list from shell_players.m
    @StateObject private var activity = ActivityModel()
    @State private var held: (key: String, task: Task<Void, Never>)?
    @State private var drag: CGFloat = 0   // how far a finger has moved the row
    @State private var pendingShortcut: String?
    @StateObject private var tv: TenFoot
    @Environment(\.pregameMirror) private var mirror   // the TV's copy in handheld mode: shows, takes no input

    init(m: PickerModel, onTV: Bool, screenScale: CGFloat = 1) {
        self.m = m
        _tv = StateObject(wrappedValue: TenFoot(native: true, onTV: onTV, screenScale: screenScale))
    }

    var body: some View {
        GeometryReader { g in
            let k = tv.on ? TenFootStage.scale(g.size) : 1   // the TV's size over 1920 x 1080 (the stage gives the same k to the views inside)
            let side = tv.on ? min(g.size.height * 0.42, g.size.width / 3.6) : min(g.size.height * 0.36, g.size.width / 4.4, 300)   // ten-foot: fewer, larger tiles
            let gap = side * 0.14
            let current = m.game(m.focus)
            ZStack {
                VStack(spacing: 0) {
                    header(k).padding(.horizontal, 32 * k).padding(.top, 22 * k)
                        .padding(.bottom, m.gridOpen ? 12 * k : 0)
                    if m.gridOpen {
                        GameGrid(m: m, width: g.size.width, cols: tv.on ? 6 : g.size.width > g.size.height ? 7 : 5)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        Group {
                            Spacer(minLength: 0)
                            row(width: g.size.width, side: side, gap: gap)
                            details(current, k).padding(.top, 22 * k)
                            Spacer(minLength: 0)
                        }
                        .transition(.opacity)
                    }
                    footer(k).padding(.horizontal, 32 * k).padding(.bottom, 22 * k)
                        .padding(.top, m.gridOpen ? 12 * k : 0)
                }
                .animation(DS.pop, value: m.gridOpen)
                if m.padsOpen {
                    Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.picked = nil; m.padsOpen = false }
                        .transition(.opacity)
                    PadsCard(m: m, pads: pads, players: players, viewport: g.size).padding(32 * k)
                        .dynamicTypeSize(tv.on ? .xLarge ... .xLarge : .xSmall ... .accessibility5)   // its places have fixed sizes: a little larger on a TV, not the whole step
                        .transition(DS.cardIn)
                }
                if m.settingsOpen {
                    Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { closeSettings() }
                        .transition(.opacity)
                    ViewThatFits(in: .vertical) {
                        PickerSettingsCard(m: m, k: k)
                        ScrollView {
                            PickerSettingsCard(m: m, k: k).frame(maxWidth: .infinity)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(maxHeight: max(1, g.size.height - 48 * k))
                    .padding(24 * k)
                    .dynamicTypeSize(tv.on ? .xLarge ... .xLarge : .xSmall ... .accessibility5)
                    .transition(DS.cardIn)
                }
            }
            .animation(DS.pop, value: m.padsOpen)
            .animation(DS.pop, value: m.settingsOpen)
            .environmentObject(activity)
            .frame(width: g.size.width, height: g.size.height)
            .background { backdrop(current) }   // behind, not in the stack: the icon filling the screen would make the stack taller than it and push the row down
        }
        .dynamicTypeSize(tv.on ? .accessibility1 ... .accessibility1 : .xSmall ... .accessibility5)   // every text style grows together on a TV
        .environment(\.tenFoot, tv.on)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { if !mirror { input($0.userInfo) } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMHomePressed"))) { note in
            guard !mirror, note.userInfo?["p"] as? Int == 1, note.userInfo?["shortcut"] as? Bool == true,
                  !m.starting, !m.reorderingGames else { return }
            pendingShortcut = nil
            if m.settingsOpen { closeSettings() } else { openSettings() }
        }
        .onAppear { if !mirror { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) } }
        .onChange(of: m.settingsOpen) { _, open in
            if !open { held?.task.cancel(); held = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            held?.task.cancel()
            held = nil
            pendingShortcut = nil
        }
        .onDisappear { held?.task.cancel(); pendingShortcut = nil }
        .task { while !Task.isCancelled { pads.refresh(); try? await Task.sleep(for: .seconds(3)) } }
        .tenFoot(tv)
    }

    // The tiles, the chosen one in the middle of the screen; a swipe moves by as many tiles as it throws
    private func row(width: CGFloat, side: CGFloat, gap: CGFloat) -> some View {
        let pitch = side + gap
        let reach = Int(width / 2 / pitch) + 2   // places drawn on each side of the focused one: enough to fill the screen while a swipe moves it
        return ZStack {
            ForEach((m.pos - reach)...(m.pos + reach), id: \.self) { v in
                let i = m.item(v)
                Group {
                    if let game = m.game(i) {
                        GameTile(game: game, focused: v == m.pos, side: side).accessibilityLabel(game.name)
                    } else {
                        PadsTile(qr: pads.qr, joined: players.players.map(\.player), focused: v == m.pos, side: side)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { m.choose(at: v) }
                .accessibilityAddTraits(.isButton)
                .offset(x: CGFloat(v - m.pos) * pitch + drag)
            }
        }
        .frame(width: width, height: side * 1.15)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in if !m.starting { drag = v.translation.width } }
                .onEnded { v in
                    let steps = Int((-v.predictedEndTranslation.width / pitch).rounded())
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        m.move(steps)
                        drag = 0
                    }
                }
        )
        .animation(DS.spring, value: m.pos)
    }

    private func backdrop(_ game: PickerGame?) -> some View {
        ZStack {
            if let game, let icon = game.icon, let soft = blurredIcon(icon, key: game.id) {
                Image(uiImage: soft).resizable().interpolation(.medium).scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .scaleEffect(1.4)
                    .id(game.id).transition(.opacity)
            }
        }
        // The outgoing image stays above the black fill until SwiftUI finishes fading it out.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(0.55)
        .background(.black)
        .overlay {
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: game?.id)
    }

    private var appIcon: UIImage? { UIImage(named: "AppIcon60x60") }   // the package's own icon (nxn_merge.py)
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SwitchPad" }
    private func header(_ k: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 14 * k) {
            if let icon = appIcon {
                Image(uiImage: icon).resizable().interpolation(.high).frame(width: 44 * k, height: 44 * k)
                    .clipShape(RoundedRectangle(cornerRadius: 10 * k, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(appName).font(.ds(.subheadline, .semibold, k: k)).foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 12 * k) {
                    Text(m.gridOpen ? tr("所有遊戲", "All games") : tr("選擇遊戲", "Choose a game")).font(.ds(.largeTitle, .bold, k: k)).contentTransition(.opacity)
                    if m.gridOpen { Chip(text: tr("\(m.games.count) 款", "\(m.games.count)")).transition(.opacity) }
                }
            }
            Spacer()
            if m.games.count > 1 {
                Button { withAnimation(DS.pop) { m.showGrid(!m.gridOpen) } } label: {   // the same as X, for touch
                    Image(systemName: m.gridOpen ? "rectangle.split.3x1.fill" : "square.grid.3x3.fill").font(.ds(.title3, .semibold, k: k))
                        .frame(width: 48 * k, height: 44 * k)
                        .background(RoundedRectangle(cornerRadius: 12 * k, style: .continuous).fill(m.gridOpen ? DS.accent : DS.chip))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.gridOpen ? tr("回到單排", "Back to the row") : tr("所有遊戲", "All games"))
            }
            Button { openSettings() } label: {
                Image(systemName: "gearshape").font(.ds(.title3, .semibold, k: k))
                    .frame(width: 48 * k, height: 44 * k)
                    .background(DS.chip, in: RoundedRectangle(cornerRadius: 12 * k))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("SwitchPad 設定", "SwitchPad settings"))
            BackToTVButton()
            StatusBar()
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func details(_ game: PickerGame?, _ k: CGFloat) -> some View {
        if m.focus == 0 {
            VStack(spacing: 6 * k) {
                Text(tr("加入玩家", "Add players")).font(.ds(.title, .bold, k: k)).foregroundStyle(.white)
                Chip(text: tr("用手機相機掃描", "Scan with a phone camera"))
            }
            .padding(.horizontal, 32 * k)
        } else if let game {
            VStack(spacing: 6 * k) {
                Text(game.name).font(.ds(.title, .bold, k: k)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                HStack(spacing: 8 * k) {
                    if !game.version.isEmpty { Chip(text: "v" + game.version) }
                    if let p = game.played { Chip(text: tr("上次遊玩 ", "Last played ") + p.formatted(.relative(presentation: .named).locale(Locale(identifier: zhHant ? "zh-Hant" : "en")))) }
                }
            }
            .padding(.horizontal, 32 * k)
            .animation(.easeInOut(duration: 0.25), value: game.id)   // the name and version cross-fade as the row slides
        }
    }

    private func footer(_ k: CGFloat) -> some View {
        HStack(spacing: 22 * k) {
            if m.gridOpen && !tv.on && !mirror && m.games.count > 1 {
                Text(tr("長按圖示可排序", "Touch and hold to reorder")).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer()
            if m.gridOpen {
                KeyHint(key: "✛", text: tr("選擇", "Choose"))
                KeyHint(key: "A", text: tr("設定", "Settings"))
                KeyHint(key: "B", text: tr("返回", "Back"))
            } else {
                KeyHint(key: "◀ ▶", text: tr("選擇", "Choose"))
                KeyHint(key: "A", text: m.focus == 0 ? tr("玩家", "Players") : tr("開始", "Play"))
                if m.games.count > 1 { KeyHint(key: "X", text: tr("所有遊戲", "All games")) }
            }
            KeyHint(key: "Y", text: tr("玩家", "Players"))
            KeyHint(key: "＋／−", text: tr("設定", "Settings"))
            if tv.on { KeyHint(key: "Home", text: tr("切換模式", "Switch mode")) }   // on the TV, the same in console and handheld mode
        }
        .font(.ds(.callout, k: k)).foregroundStyle(.white.opacity(0.6))
    }

    // On the players card: up and down within a column, left and right between the columns; A identifies, − switches the layout, X removes, B closes
    private func cardInput(_ key: String) {
        let row = players.players.first { $0.player == m.sel + 1 }
        switch key {
        case "up": if m.sel % 4 > 0 { m.sel -= 1 }
        case "down": if m.sel % 4 < 3 { m.sel += 1 }
        case "left": if m.sel >= 4 { m.sel -= 4 }
        case "right": if m.sel < 4 { m.sel += 4 }
        case "a":   // as the in-game menu's Players page: A picks a player up (its controller buzzes), the arrows choose the number, A puts it there
            if let p = m.picked {
                if p != m.sel { players.send(["op": "swap", "a": p + 1, "b": m.sel + 1]) }
                m.picked = nil
            } else if let r = row { m.picked = m.sel; players.send(["op": "identify", "p": r.player]) }
            else if let r = removedAt(m.sel, players) { players.send(["op": "add", "index": r.index]) }
        case "minus": if let r = row, m.picked == nil { players.send(["op": "layout", "p": r.player, "xbox": r.xbox ? 0 : 1]) }
        case "x": if let r = row, m.picked == nil { players.send(["op": "kick", "p": r.player]) }
        case "b" where m.picked != nil: m.picked = nil
        case "b", "y": m.picked = nil; m.padsOpen = false
        default: break
        }
    }

    private func openSettings() {
        guard !m.starting, !m.reorderingGames else { return }
        held?.task.cancel()
        m.picked = nil
        m.padsOpen = false
        m.setting = 0
        m.confirmingExit = false
        m.settingsOpen = true
    }

    private func closeSettings() {
        if m.confirmingExit {
            m.confirmingExit = false
            m.setting = 3
        } else {
            m.settingsOpen = false
        }
    }

    private func settingsInput(_ key: String) {
        if key == "b" { closeSettings(); return }
        if m.confirmingExit {
            if key == "up" { m.setting = 0 }
            if key == "down" { m.setting = 3 }
            if key == "a" {
                if m.setting == 3 { pickerAction(3) } else { closeSettings() }
            }
            return
        }
        let rows = pickerOutputs() & 1 == 0 ? [0, 3] : [0, 1, 2, 3]
        switch key {
        case "up", "down":
            let index = rows.firstIndex(of: m.setting) ?? 0
            m.setting = rows[min(rows.count - 1, max(0, index + (key == "up" ? -1 : 1)))]
        case "left" where m.setting == 0, "right" where m.setting == 0:
            let direction: Int32 = key == "left" ? -1 : 1
            guard adjustPickerVolume(direction) else { return }
            held = (key, Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                var repeats = 0
                while !Task.isCancelled {
                    if !adjustPickerVolume(direction) { break }
                    repeats += 1
                    try? await Task.sleep(for: .milliseconds(max(35, 130 - repeats * 7)))
                }
            })
        case "a":
            if m.setting == 3 {
                m.confirmingExit = true
                m.setting = 0
            } else if m.setting != 0 {
                pickerAction(Int32(m.setting))
            }
        default: break
        }
    }

    private func input(_ u: [AnyHashable: Any]?) {
        guard let key = u?["key"] as? String, (u?["p"] as? Int ?? 1) == 1 else { return }   // player 1 drives it, as in the launcher
        let pressed = (u?["on"] as? Int ?? 1) != 0
        if key == "plus" || key == "minus" {
            // A single key acts on release, so a staggered ＋/− chord cannot launch a game first.
            if pressed { pendingShortcut = key; return }
            guard pendingShortcut == key else { return }
            pendingShortcut = nil
        } else if !pressed {
            if held?.key == key { held?.task.cancel(); held = nil }
            return
        }
        held?.task.cancel(); held = nil
        guard !m.starting, !m.reorderingGames else { return }
        if m.settingsOpen { settingsInput(key); return }
        if m.padsOpen { cardInput(key); return }
        switch key {
        case "y": m.padsOpen = true
        case "x": m.showGrid(!m.gridOpen)
        case "b" where m.gridOpen: m.showGrid(false)   // back to the row, standing on the game chosen in the grid
        case "a", "plus": m.choose()
        case "left", "right", "up", "down":
            let step: @MainActor () -> Void = m.gridOpen ? { m.gridMove(key) } : { m.move(key == "left" || key == "up" ? -1 : 1) }
            step()
            held = (key, Task { @MainActor in   // repeats while held
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled { step(); try? await Task.sleep(for: .milliseconds(m.gridOpen ? 130 : 160)) }
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
    let fresh = PickerModel.kept == nil
    let model = PickerModel.kept ?? PickerModel()
    PickerModel.kept = model
    model.starting = false; model.padsOpen = false; model.settingsOpen = false
    let scene = parent.view.window?.windowScene
    let onTV = scene?.session.role == .windowExternalDisplayNonInteractive
    let h = NoFocusHostingController(rootView: PickerView(m: model, onTV: onTV, screenScale: scene?.screen.scale ?? 1))
    PregameStage.shared.showPicker({ AnyView(PickerView(m: model, onTV: true)) }, fresh: fresh)   // the TV's copy in handheld mode
    // The blurred backdrops and, with a TV, the enlarged icons made ahead, off the main thread: the TV's copy (built again on the way back from the
    // launcher) had to make them all as it appeared, and came in well after the iPad
    if fresh {
        let games = model.games
        let tvToo = UIApplication.shared.connectedScenes.contains { $0.session.role == .windowExternalDisplayNonInteractive }
        DispatchQueue.global(qos: .userInitiated).async {
            for g in games { if let i = g.icon { _ = blurredIcon(i, key: g.id); if tvToo { _ = tvIcon(i, key: g.id) } } }
        }
    }
    controllerNotForUIKit(h.view)   // Launcher.swift
    h.modalPresentationStyle = .fullScreen
    h.modalTransitionStyle = .crossDissolve   // fades in and out, to and from the launcher
    model.start = { [weak h, weak model] game in
        guard let h else { model?.starting = false; return }
        let covered = frontIosPickerCoverBegin()
        UserDefaults.standard.set(Date(), forKey: "picker.played." + game.id)
        PickerModel.lastPicked = game.id
        fputs("picker: \(game.id) (\(game.name))\n", stderr)
        NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 0])
        DispatchQueue.main.async {
            game.id.withCString { shellGameChoose($0) }
            h.dismiss(animated: !covered) { done() }
        }
    }
    parent.present(h, animated: !frontIosPickerCoverActive()) {
        h.view.layoutIfNeeded()
        frontIosPickerCoverEnd()
    }
    fputs("picker: \(model.games.count) games shown\n", stderr)
}
