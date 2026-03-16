import SwiftUI

/// Menu bar application for monitoring Claude usage limits
@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(ClaudeBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scenes — everything is driven by the AppDelegate's NSStatusItem + NSPopover
        Settings { EmptyView() }
    }
}
