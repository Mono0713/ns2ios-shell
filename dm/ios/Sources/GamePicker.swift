// Game picker: the first screen of a package of several games (scripts/nxn_merge.py puts each in <App>/games/<title ID>/ with its game.json and icon).
// A row of game tiles, the chosen one in the middle, over its icon blurred as the backdrop; the time, Wi-Fi and battery at the top right, as on a console.
// Styled like Switch Pad on the PC: the package's icon and name at the top left, app-icon corners, a white focus ring, small rounded chips.
// Touch: swipe the row to move through it, tap a tile to start that game. Player 1's controller or phone (shell_players.m, the launcher's DMLauncherInput):
// left and right move, A or + starts. The games stay in order by name; the highlight starts on the phones' QR code, and the row goes round (after the last game, the QR code again).
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
    @Published fileprivate(set) var on = false
    @Published fileprivate(set) var screenScale: CGFloat = 1
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
            DispatchQueue.main.async { [weak self] in
                if let t {
                    if t.screenScale != scale { t.screenScale = scale }
                    if t.on != now { t.on = now }
                }
                guard let self, let vc = sequence(first: self as UIResponder, next: { $0.next }).first(where: { $0 is UIViewController }) as? UIViewController else { return }
                let sharp = now && u > 1.01 ? scale * u : 0
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
private struct TenFootStage: ViewModifier {
    let on: Bool
    var screenScale: CGFloat = 1
    static func scale(_ size: CGSize) -> CGFloat { max(0.5, min(size.width / 1920, size.height / 1080)) }
    func body(content: Content) -> some View {
        // Always the same structure (scale 1 on the iPad), so the screen's own state and its onAppear do not start over when it moves to the TV
        GeometryReader { g in
            let u = on ? TenFootStage.scale(g.size) : 1
            content.frame(width: g.size.width / u, height: g.size.height / u)
                // drawn at the size it ends up on the TV, not at the canvas's size stretched (soft on a 1440p or 4K TV); the iPad keeps its own
                .transformEnvironment(\.displayScale) { if on && u > 1.01 { $0 = screenScale * u } }
                .scaleEffect(u, anchor: .topLeading)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: on ? Edge.Set.all : [])
    }
}
extension View {
    // The probe and, on the TV, the canvas: the outermost modifiers of the picker's and the launcher's screens
    func tenFoot(_ tv: TenFoot) -> some View { modifier(TenFootStage(on: tv.on, screenScale: tv.screenScale)).background(TenFootProbe(tv: tv)) }
}
// Back to the TV: shown while a TV is connected but the picture was switched to the iPad and the game has not started (front_ios.m answers, again on
// each DMShellChanged); the picture goes back to the TV. In the picker's title bar and next to the launcher's Game list
@_silgen_name("front_ios_tv_waiting") private func frontIosTvWaiting() -> Int32
@_silgen_name("front_ios_back_to_tv") private func frontIosBackToTv()
struct BackToTVButton: View {
    @State private var waiting = frontIosTvWaiting() != 0
    var body: some View {
        Group {
            if waiting {
                Button { frontIosBackToTv() } label: {
                    Label(tr("回到電視", "Back to the TV"), systemImage: "tv").font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.accent))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(DS.pop, value: waiting)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMShellChanged")).receive(on: DispatchQueue.main)) { _ in
            waiting = frontIosTvWaiting() != 0
        }
        .onAppear { waiting = frontIosTvWaiting() != 0 }
    }
}

private struct TenFootKey: EnvironmentKey { static let defaultValue = false }
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
    var body: some View {
        HStack(spacing: 6) {
            Text(key).font(.caption.weight(.bold)).frame(minWidth: 22, minHeight: 22).padding(.horizontal, key.count > 1 ? 4 : 0)
                .background(RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous).fill(Color.white.opacity(0.16)))
            Text(text)
        }
    }
}
private let systemBlue = DS.accent
private func tileRadius(_ side: CGFloat) -> CGFloat { side * 0.2237 }   // the home screen's icon corner
private struct FocusRing: ViewModifier {
    let focused: Bool
    let side: CGFloat
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: tileRadius(side) + 7, style: .continuous)
                    .stroke(focused ? Color.white.opacity(0.95) : .clear, lineWidth: 4).padding(-8)
            }
            .shadow(color: .black.opacity(focused ? 0.55 : 0.4), radius: focused ? 22 : 8, y: focused ? 14 : 4)
            .scaleEffect(focused ? 1 : 0.84)
            .opacity(focused ? 1 : 0.6)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: focused)
    }
}
private struct Chip: View {   // a small rounded box: version, last played, a key's name
    let text: String
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous).fill(DS.chip))
    }
}

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
    return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }   // a fixed order, by name (the highlight starts on the phones' tile)
}

// The row: the phones' tile at 0, then the games (game i at i + 1). It goes round: after the last game comes the phones' tile again, so the
// row is a ring and pos counts places along it without end (focus is the item there). It opens on the phones' tile, whose QR code is what a
// player needs first
private final class PickerModel: ObservableObject {
    let games: [PickerGame]
    @Published var pos = 0
    init() { games = loadGames() }
    var focus: Int { ((pos % count) + count) % count }
    func item(_ v: Int) -> Int { ((v % count) + count) % count }
    @Published var starting = false
    @Published var padsOpen = false
    @Published var sel = 0   // the highlighted place on the players card (player sel + 1)
    var count: Int { games.count + 1 }
    func game(_ i: Int) -> PickerGame? { games.indices.contains(i - 1) ? games[i - 1] : nil }
    var start: (PickerGame) -> Void = { _ in }
    func move(_ d: Int) { if !starting { pos += d } }
    func choose(at v: Int? = nil) {   // the item at place v of the ring (the focused one when nil)
        guard !starting else { return }
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

// A game's icon is the package's 256 x 256 JPEG; on a TV a tile is 700 to 1000 pixels across. Enlarged once with Lanczos (sharper edges than the GPU's
// linear filter), up to 1024 pixels, and kept
private let sharpIcons = NSCache<NSString, UIImage>()
func tvIcon(_ img: UIImage, key: String? = nil) -> UIImage {   // key: for an icon read from its file again on every redraw (the launcher's)
    let k = (key ?? "\(ObjectIdentifier(img).hashValue)") as NSString
    if let done = sharpIcons.object(forKey: k) { return done }
    let px = max(img.size.width * img.scale, img.size.height * img.scale)
    guard px > 0, px < 1000, let src = CIImage(image: img) else { return img }
    let f = CIFilter.lanczosScaleTransform(); f.inputImage = src; f.scale = Float(1024 / px); f.aspectRatio = 1
    guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent.integral) else { return img }
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
    guard let out = f.outputImage?.cropped(to: small.extent), let cg = CIContext().createCGImage(out, from: small.extent) else { return nil }
    let done = UIImage(cgImage: cg)
    blurredIcons.setObject(done, forKey: key as NSString)
    return done
}

private struct GameTile: View {
    let game: PickerGame
    let focused: Bool
    let side: CGFloat
    @Environment(\.tenFoot) private var tenFoot
    var body: some View {
        ZStack {
            if let icon = game.icon {
                Image(uiImage: tenFoot ? tvIcon(icon, key: game.id) : icon).resizable().interpolation(.high).antialiased(true).scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.29), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                Text(game.name).font(.title3.weight(.bold)).foregroundStyle(.white).multilineTextAlignment(.center).padding(12)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: tileRadius(side), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: tileRadius(side), style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .modifier(FocusRing(focused: focused, side: side))
    }
}

private struct PadsTile: View {   // the QR code itself, a short bar in each joined player's colour
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
            HStack(spacing: 5) { ForEach(0..<joined, id: \.self) { i in RoundedRectangle(cornerRadius: 3, style: .continuous).fill(playerColors[i % playerColors.count]).frame(width: 14, height: 6) } }
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, side * 0.04)
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

// The players card: the QR code and address on the left, the eight places on the right (two columns of four, so it keeps its size)
private struct PadsCard: View {
    @ObservedObject var m: PickerModel
    @ObservedObject var pads: PadsModel
    @ObservedObject var players: PlayersModel
    @EnvironmentObject var activity: ActivityModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(tr("玩家", "Players")).font(.title.weight(.bold))
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
                    .frame(width: 230, height: 230).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if let url = pads.url {
                        Text(url).font(.callout.monospaced()).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous).fill(DS.chip))
                    } else {
                        Text(tr("請先連上 Wi-Fi", "Connect to Wi-Fi first")).font(.footnote).foregroundStyle(.white.opacity(0.65))
                    }
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
                KeyHint(key: "A", text: tr("震動", "Identify")); KeyHint(key: "−", text: tr("切換配置", "Layout")); KeyHint(key: "X", text: tr("移除", "Remove")); KeyHint(key: "B", text: tr("關閉", "Close"))
            }
            .font(.callout).foregroundStyle(.white.opacity(0.6))
        }
        .padding(30)
        .frame(maxWidth: 980)
        .glassCard()
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
                .background(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous).fill(row == nil ? Color.white.opacity(0.08) : color))
            if let p = row {
                Image(systemName: p.kind == 2 ? "iphone" : controllerIcon(p.label)).font(.title3).frame(width: 28)
                Text(padName(p)).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button { players.send(["op": "layout", "p": n, "xbox": p.xbox ? 0 : 1]) } label: {
                    Text((p.xbox ? "Xbox" : "Switch") + " ⇄").font(.footnote.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous).fill(DS.chip))
                }
                .buttonStyle(.plain).accessibilityLabel(tr("切換配置", "Button layout"))
                Button { players.send(["op": "kick", "p": n]) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: DS.chipRadius, style: .continuous).fill(DS.chip))
                }
                .buttonStyle(.plain).accessibilityLabel(tr("移除", "Remove"))
            } else if let r = back {
                Image(systemName: controllerIcon(r.label)).font(.title3).frame(width: 28).foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(padName(PlayerRow(player: 0, kind: 1, label: r.label, name: "", xbox: false))).font(.headline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Text(tr("已移除 · 按 A 加回", "Removed · A to add back")).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.8)
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
            RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                .fill(row == nil ? Color.clear : lit ? color.opacity(0.3) : DS.plate)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                .strokeBorder(sel ? systemBlue : row == nil ? Color.white.opacity(0.12) : lit ? color : .clear,
                              style: StrokeStyle(lineWidth: sel ? 2 : row == nil ? 1.5 : 1, dash: row == nil && !sel ? [5, 4] : []))
        }
        .scaleEffect(lit ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: lit)
        .animation(DS.spring, value: sel)
        .contentShape(Rectangle())
        .onTapGesture {   // tap: that controller or phone buzzes; a removed one is added back
            m.sel = i
            if row != nil { players.send(["op": "identify", "p": n]) } else if let r = back { players.send(["op": "add", "index": r.index]) }
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
    @StateObject private var tv = TenFoot()

    var body: some View {
        GeometryReader { g in
            let side = tv.on ? min(g.size.height * 0.42, g.size.width / 3.6) : min(g.size.height * 0.36, g.size.width / 4.4, 300)   // ten-foot (on the 1920 x 1080 canvas): fewer, larger tiles
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
                    Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.padsOpen = false }
                        .transition(.opacity)
                    PadsCard(m: m, pads: pads, players: players).padding(32)
                        .dynamicTypeSize(tv.on ? .xLarge ... .xLarge : .xSmall ... .accessibility5)   // its places have fixed sizes: a little larger on a TV, not the whole step
                        .transition(DS.cardIn)
                }
            }
            .animation(DS.pop, value: m.padsOpen)
            .environmentObject(activity)
            .frame(width: g.size.width, height: g.size.height)
            .background { backdrop(current) }   // behind, not in the stack: the icon filling the screen would make the stack taller than it and push the row down
        }
        .dynamicTypeSize(tv.on ? .accessibility1 ... .accessibility1 : .xSmall ... .accessibility5)   // every text style grows together on a TV
        .environment(\.tenFoot, tv.on)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMLauncherInput"))) { input($0.userInfo) }
        .onAppear { NotificationCenter.default.post(name: Notification.Name("DMPlayersCommand"), object: nil, userInfo: ["op": "launcher", "on": 1]) }
        .onDisappear { held?.task.cancel() }
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
                        PadsTile(qr: pads.qr, joined: players.players.count, focused: v == m.pos, side: side)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { m.choose(at: v) }
                .accessibilityAddTraits(.isButton)
                .scaleEffect(m.starting && v == m.pos ? 1.1 : 1)
                .opacity(m.starting && v != m.pos ? 0 : 1)
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
        .animation(.easeOut(duration: 0.3), value: m.starting)
    }

    private func backdrop(_ game: PickerGame?) -> some View {
        ZStack {
            Color.black
            if let game, let icon = game.icon, let soft = blurredIcon(icon, key: game.id) {
                Image(uiImage: soft).resizable().interpolation(.medium).scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .scaleEffect(1.4).opacity(0.55)
                    .id(game.id).transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: game?.id)
    }

    private var appIcon: UIImage? { UIImage(named: "AppIcon60x60") }   // the package's own icon (nxn_merge.py)
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SwitchPad" }
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon = appIcon {
                Image(uiImage: icon).resizable().interpolation(.high).frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(appName).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                Text(tr("選擇遊戲", "Choose a game")).font(.largeTitle.weight(.bold))
            }
            Spacer()
            BackToTVButton()
            StatusBar()
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func details(_ game: PickerGame?) -> some View {
        if m.focus == 0 {
            VStack(spacing: 6) {
                Text(tr("加入玩家", "Add players")).font(.title.weight(.bold)).foregroundStyle(.white)
                Chip(text: tr("用手機相機掃描", "Scan with a phone camera"))
            }
            .padding(.horizontal, 32)
        } else if let game {
            VStack(spacing: 6) {
                Text(game.name).font(.title.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.opacity)
                HStack(spacing: 8) {
                    if !game.version.isEmpty { Chip(text: "v" + game.version) }
                    if let p = game.played { Chip(text: tr("上次遊玩 ", "Last played ") + p.formatted(.relative(presentation: .named).locale(Locale(identifier: zhHant ? "zh-Hant" : "en")))) }
                }
            }
            .padding(.horizontal, 32)
            .animation(.easeInOut(duration: 0.25), value: game.id)   // the name and version cross-fade as the row slides
        }
    }

    private var footer: some View {
        HStack(spacing: 22) {
            Spacer()
            KeyHint(key: "◀ ▶", text: tr("選擇", "Choose"))
            KeyHint(key: "A", text: m.focus == 0 ? tr("玩家", "Players") : tr("開始", "Play"))
            KeyHint(key: "Y", text: tr("玩家", "Players"))
        }
        .font(.callout).foregroundStyle(.white.opacity(0.6))
        .opacity(m.starting ? 0 : 1)
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
