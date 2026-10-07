import AppKit

/// Explains automatic paste before macOS asks for Accessibility.
///
/// Declining keeps the clip on the clipboard and stays quiet until Preferences
/// asks again. Allowing opens the system prompt, which is the only place the
/// permission is actually granted.
@MainActor
enum AutomaticPastePrompt {
    /// Returns true when clip'M may synthesize Command-V.
    @discardableResult
    static func allowsPaste(settings: ClipMenuSettings, ignoreDecline: Bool = false) -> Bool {
        if PasteService.accessibilityStatus().isTrusted { return true }
        if settings.declinedAutomaticPaste && !ignoreDecline { return false }

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        let alert = NSAlert()
        alert.messageText = "Paste in one step?"
        alert.informativeText = """
        \(AppDistribution.displayName) can paste the clip you choose in one step when you allow Accessibility.

        macOS will then say \(AppDistribution.displayName) would like to control this computer. The only controlling \(AppDistribution.displayName) does is pasting the things you choose to paste.

        If you skip this, \(AppDistribution.displayName) still keeps track of what you copy. Choosing a clip copies it, and you paste it yourself. That takes two steps. Allow Automatic Paste and you skip the second one.
        """
        alert.addButton(withTitle: "Allow Automatic Paste")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            return PasteService.requestAccessibilityPermissionIfNeeded()
        }
        settings.declinedAutomaticPaste = true
        return false
    }
}
