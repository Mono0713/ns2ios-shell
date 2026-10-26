// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section. Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once, as an app without launcher.json does
import SwiftUI
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
    "Phone controllers": "手機手把", "Scan with a phone camera, or open in its browser:": "用手機相機掃描，或在手機瀏覽器打開：",
    "Connect this device to Wi-Fi (or turn on its Personal Hotspot) to let phones join.": "請先連上 Wi-Fi（或開啟個人熱點），手機才能加入。",
    "Each phone on the same Wi-Fi becomes a controller of its own, after any connected controllers, up to player 8. A phone that reloads the page keeps its player.":
        "同一個 Wi-Fi 的每支手機都是一個獨立玩家，排在已連線的手把後面，最多到 8P。手機重新整理頁面會保留原本的玩家。",
]
private func tr(_ s: String) -> String { zhHant ? zhText[s] ?? s : s }

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

    var body: some View {
        Section {
            if let url {
                HStack(spacing: 16) {
                    if let qr = qrImage(url) {
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
                url = phonePadsURL()
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

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()

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
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    ForEach(m.sections, id: \.self) { section in
                        Section(tr(section)) {
                            ForEach(m.settings.filter { $0.sectionTitle == section }) { SettingRow(s: $0, m: m) }
                        }
                    }
                    if ProcessInfo.processInfo.environment["DM_PHONE_PADS_LIVE"] != nil { PhonePadsSection() }
                    Section {
                        Button(tr("Reset to tested defaults")) { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text(tr("Brings back all settings this game was tested with."))
                    }
                    Section {
                        Button(tr("Open game folder")) {   // this app's Documents in the Files app (shareddocuments: scheme)
                            if let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                               let url = URL(string: "shareddocuments://" + doc.path) { UIApplication.shared.open(url) }
                        }
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
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text(tr("Play")).font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
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
