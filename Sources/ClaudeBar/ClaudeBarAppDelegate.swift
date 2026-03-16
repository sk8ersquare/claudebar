import AppKit
import SwiftUI
import UserNotifications

/// App delegate that manages the menu bar status item and popover.
///
/// Uses NSStatusItem + NSPopover instead of MenuBarExtra to ensure
/// the popover always appears directly below the menu bar icon.
@MainActor
final class ClaudeBarAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    let service = UsageService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must set delegate BEFORE requesting permission — required for
        // LSUIElement (menu bar) apps to actually receive/display notifications
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarButton()

        let hostingView = NSHostingView(
            rootView: UsageView()
                .environment(service)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let viewController = NSViewController()
        viewController.view = NSView()
        viewController.view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
        ])

        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Observe service changes to update the menu bar label
        observeServiceChanges()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateMenuBarButton() {
        guard let button = statusItem.button else { return }
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Usage")
        let attrString = NSMutableAttributedString(attachment: attachment)

        if service.showPercentage, let percent = service.usage?.fiveHour?.percent {
            let percentStr = NSAttributedString(
                string: " \(percent)%",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)]
            )
            attrString.append(percentStr)
        }

        button.attributedTitle = attrString
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when the app is frontmost (required for menu bar apps)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    // MARK: - Private

    private func observeServiceChanges() {
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                withObservationTracking {
                    self.updateMenuBarButton()
                } onChange: {
                    // onChange fires once then we re-register in the next loop iteration
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
