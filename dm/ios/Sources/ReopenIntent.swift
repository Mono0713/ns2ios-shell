// The Shortcuts action "SwitchPad 要重開嗎？": true when the app was just closed by the Home menu's Change games (main.m saw its flag at launch).
// A personal automation on "SwitchPad is closed" asks it and opens SwitchPad when it is true, so changing games needs nobody at the iPad. Asking the app
// itself replaces reading Documents/relaunch.txt from the shortcut, which made iOS ask for the folder every time.
import AppIntents
import UIKit

@_silgen_name("shell_relaunch_requested") private func shellRelaunchRequested() -> Int32   // yes once (main.m): later closes answer no
@_silgen_name("shell_ever_active") private func shellEverActive() -> Int32

// Started in the background only to answer (never on screen): end the process, so Open App starts SwitchPad fresh and a plain close leaves nothing
// running. A process that has been on screen is the user's, gone to the Home Screen with its game: left alone
@MainActor private func endIfOnlyAnswering() {
    if shellEverActive() != 0 { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if UIApplication.shared.applicationState == .background && shellEverActive() == 0 { fflush(stderr); exit(0) }
    }
}

struct ShouldReopenIntent: AppIntent {
    static var title: LocalizedStringResource = "SwitchPad 要重開嗎？"
    static var description = IntentDescription("剛用「換遊戲」關閉 SwitchPad 時是「是」。在「SwitchPad 已關閉」的自動化裡用它決定要不要打開 SwitchPad。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let yes = shellRelaunchRequested() != 0
        if !yes { endIfOnlyAnswering() }
        return .result(value: yes)
    }
}


// One step instead of If + Open App: "重開 SwitchPad（換遊戲後）" brings the app to the front itself when Change games closed it, and does nothing
// otherwise. iOS 26's dynamic foreground mode: the intent starts in the background and moves to the foreground only when it has to.
struct ReopenAfterChangeIntent: AppIntent {
    static var title: LocalizedStringResource = "重開 SwitchPad（換遊戲後）"
    static var description = IntentDescription("剛用「換遊戲」關閉時重新打開 SwitchPad，其他時候什麼都不做。放在「SwitchPad 已關閉」的自動化裡就好。")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        if shellRelaunchRequested() != 0 && systemContext.currentMode.canContinueInForeground {
            try await continueInForeground(alwaysConfirm: false)
            return .result()
        }
        endIfOnlyAnswering()   // a plain close: nothing to do, and nothing left running
        return .result()
    }
}
