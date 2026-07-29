// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Navigation Validator

/// Validates navigation intents during the installer flow.
///
/// Conforming types determine whether a given navigation action is allowed
/// from a specific page. When an intent is rejected, ``blockerMessage(for:from:)``
/// provides a user-facing explanation.
public protocol InstallerNavigationValidating {
    /// Returns `true` if the given navigation intent is allowed from the current page.
    func canNavigate(to intent: InstallerNavigationIntent, from page: InstallerPage) -> Bool

    /// A user-facing message explaining why the intent was rejected.
    ///
    /// This is only called when `canNavigate(to:from:)` returns `false`.
    func blockerMessage(for intent: InstallerNavigationIntent, from page: InstallerPage) -> String
}

// MARK: - Navigation Footer

/// A reusable footer toolbar with Back, Stop & Clean, and Next buttons.
///
/// All buttons remain tappable at all times — disabled states are never used.
/// When a navigation intent is rejected by the validator, the footer displays a
/// blocker alert instead of greying out the button.
public struct InstallerNavigationFooter: View {
    let validator: any InstallerNavigationValidating
    let currentPage: InstallerPage
    let onNavigate: (InstallerNavigationIntent) async -> Void

    @State private var blockerMessage: String?

    public init(
        validator: any InstallerNavigationValidating,
        currentPage: InstallerPage,
        onNavigate: @escaping (InstallerNavigationIntent) async -> Void
    ) {
        self.validator = validator
        self.currentPage = currentPage
        self.onNavigate = onNavigate
    }

    public var body: some View {
        HStack {
            Button("Back") {
                handleNavigation(.back)
            }
            .accessibilityIdentifier("navigation.back")

            Spacer()

            Button("Stop & Clean") {
                handleNavigation(.stopAndClean)
            }
            .accessibilityIdentifier("navigation.stopClean")

            Spacer()

            Button("Next") {
                handleNavigation(.next)
            }
            .accessibilityIdentifier("navigation.next")
        }
        .padding()
        .alert(
            "Navigation Blocked",
            isPresented: .init(
                get: { blockerMessage != nil },
                set: { if !$0 { blockerMessage = nil } }
            ),
            presenting: blockerMessage
        ) { _ in
            Button("OK") { blockerMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func handleNavigation(_ intent: InstallerNavigationIntent) {
        if validator.canNavigate(to: intent, from: currentPage) {
            Task {
                await onNavigate(intent)
            }
        } else {
            blockerMessage = validator.blockerMessage(for: intent, from: currentPage)
        }
    }
}

// MARK: - Default Validator (optional convenience)

/// Provides sensible defaults for the installer flow:
///
/// - Back is always allowed.
/// - Next is allowed on every page except the last (diagnostics).
/// - Stop & Clean is always allowed.
///
/// Override ``blockerMessage(for:from:)`` to customise the rejection text.
open class DefaultInstallerNavigationValidator: InstallerNavigationValidating {
    public init() {}

    open func canNavigate(to intent: InstallerNavigationIntent, from page: InstallerPage) -> Bool {
        switch intent {
        case .back:
            return true
        case .next:
            // Block Next on the final page.
            return page != .diagnostics
        case .stopAndClean:
            return true
        }
    }

    open func blockerMessage(for intent: InstallerNavigationIntent, from page: InstallerPage) -> String {
        switch intent {
        case .next:
            return "You have reached the end of the setup flow. Close the window or go back."
        case .back:
            return "Going back is currently not allowed."
        case .stopAndClean:
            return "Stop & Clean is not available right now."
        }
    }
}

#if DEBUG
extension DefaultInstallerNavigationValidator {
    /// Convenience for instantiating a validator.
    static var `default`: DefaultInstallerNavigationValidator {
        DefaultInstallerNavigationValidator()
    }
}
#endif
