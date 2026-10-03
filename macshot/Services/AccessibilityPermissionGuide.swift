import Foundation
import PermissionFlow

/// Opens Accessibility settings with a draggable app card.
@MainActor
enum AccessibilityPermissionGuide {
    private static let controller = PermissionFlow.makeController()

    static func show() {
        controller.setLocaleIdentifier(LanguageManager.shared.resolvedLanguage)
        controller.authorize(
            pane: .accessibility,
            suggestedAppURLs: [Bundle.main.bundleURL]
        )
    }
}
