import AppKit

@MainActor
enum DictionaryPanelFooterLayout {
    static func assemble(
        footer: NSStackView,
        localGroup: NSStackView,
        translationHostView: NSView,
        statusLabel: NSTextField,
        aiGroup: NSStackView
    ) {
        translationHostView.translatesAutoresizingMaskIntoConstraints = false
        translationHostView.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
            .isActive = true
        translationHostView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
            .isActive = true
        footer.addArrangedSubview(localGroup)
        footer.addArrangedSubview(translationHostView)
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(aiGroup)
        statusLabel.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        translationHostView.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 3
        footer.translatesAutoresizingMaskIntoConstraints = false
    }
}
