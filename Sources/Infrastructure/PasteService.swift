import CoreGraphics
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Synthesises a Cmd+V key event to paste the current pasteboard contents
/// into the frontmost application.
///
/// Requires Accessibility permission (`AXIsProcessTrusted()`).  The legacy
/// implementation lives in `legacy/Source/AppController.m -pasteFromClipboard`.
actor PasteService {
    private static let log = Logger(subsystem: "com.naotaka.ClipMenu", category: "PasteService")
    static let simulatedPasteNotification = Notification.Name("PasteService.simulatedPasteNotification")
    private var cachedVKeyCode: CGKeyCode?
    private var loggedMissingAXThisSession = false
    private var inputSourceObserver: NSObjectProtocol?

    struct AccessibilityStatus {
        let isTrusted: Bool
        let bundleIdentifier: String
        let executablePath: String
    }

    private func observeInputSourceIfNeeded() {
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.invalidateCachedKeyCode() }
        }
    }

    deinit {
        if let inputSourceObserver { NotificationCenter.default.removeObserver(inputSourceObserver) }
    }

    func paste() async {
        if Self.isPasteUITestMode {
            await MainActor.run {
                let value = NSPasteboard.general.string(forType: .string) ?? ""
                NotificationCenter.default.post(
                    name: Self.simulatedPasteNotification,
                    object: nil,
                    userInfo: ["string": value]
                )
            }
            return
        }

        let allowed = await MainActor.run {
            AutomaticPastePrompt.allowsPaste(settings: AppRuntime.shared.settings)
        }
        guard allowed else {
            Self.log.info("Clip left on the clipboard for the user to paste")
            return
        }
        guard isAccessibilityTrusted() else {
            Self.log.error("Paste aborted: Accessibility permission not granted")
            return
        }
        guard let keyCode = await resolvedVKeyCode() else {
            Self.log.error("Paste aborted: could not resolve V key code")
            return
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Self.log.error("Paste aborted: could not create CGEventSource")
            return
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        Self.log.info("Posted Cmd+V events using keyCode=\(keyCode, privacy: .public)")
    }

    nonisolated static func accessibilityStatus() -> AccessibilityStatus {
        AccessibilityStatus(
            isTrusted: isPasteUITestMode ? true : AXIsProcessTrusted(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "<nil>",
            executablePath: Bundle.main.executableURL?.path ?? "<unknown>"
        )
    }

    /// Shows the system Accessibility prompt. Call only after the in-app explanation.
    @discardableResult
    nonisolated static func requestAccessibilityPermissionIfNeeded() -> Bool {
        if isPasteUITestMode { return true }
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated private static var isPasteUITestMode: Bool {
        ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1"
    }

    private func isAccessibilityTrusted() -> Bool {
        if Self.accessibilityStatus().isTrusted {
            return true
        }

        if !loggedMissingAXThisSession {
            loggedMissingAXThisSession = true
            let status = Self.accessibilityStatus()
            Self.log.error("Accessibility permission missing. bundleID=\(status.bundleIdentifier, privacy: .public) execPath=\(status.executablePath, privacy: .public)")
        }
        return false
    }

    private func invalidateCachedKeyCode() {
        cachedVKeyCode = nil
    }

    /// HIToolbox input-source APIs must run on the main thread.
    private func resolvedVKeyCode() async -> CGKeyCode? {
        observeInputSourceIfNeeded()
        if let cachedVKeyCode {
            return cachedVKeyCode
        }
        let code = await MainActor.run {
            Self.lookupVKeyCodeFromCurrentLayout()
        }
        cachedVKeyCode = code
        return code
    }

    @MainActor
    private static func lookupVKeyCodeFromCurrentLayout() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return 9
        }

        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layout) else {
            return 9
        }

        let keyboardLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(bytes))

        for keyCode in 0..<128 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0

            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )

            guard status == noErr, length > 0 else { continue }
            let mapped = String(utf16CodeUnits: chars, count: Int(length))
            if mapped.caseInsensitiveCompare("v") == .orderedSame {
                return CGKeyCode(keyCode)
            }
        }

        return 9
    }
}

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
