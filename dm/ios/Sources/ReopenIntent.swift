// The Shortcuts action "SwitchPad 要重開嗎？": true when the app was just closed by the Home menu's Change games (main.m saw its flag at launch).
// A personal automation on "SwitchPad is closed" asks it and opens SwitchPad when it is true, so changing games needs nobody at the iPad. Asking the app
// itself replaces reading Documents/relaunch.txt from the shortcut, which made iOS ask for the folder every time.
import AppIntents
import UIKit

@_silgen_name("shell_relaunch_requested") private func shellRelaunchRequested() -> Int32

struct ShouldReopenIntent: AppIntent {
    static var title: LocalizedStringResource = "SwitchPad 要重開嗎？"
    static var description = IntentDescription("剛用「換遊戲」關閉 SwitchPad 時是「是」。在「SwitchPad 已關閉」的自動化裡用它決定要不要打開 SwitchPad。")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let yes = shellRelaunchRequested() != 0
        // Started in the background only to answer: end the process, so Open App starts SwitchPad fresh and a plain close leaves nothing running
        if UIApplication.shared.applicationState == .background {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if UIApplication.shared.applicationState == .background { fflush(stderr); exit(0) }
            }
        }
        return .result(value: yes)
    }
}

