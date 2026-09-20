import AppKit

/// Owns the native settings dialog; website policy and persistence stay in WebsitePreferences.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let preferences: WebsitePreferences
    private let websiteField = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var draft: WebsiteSettingsDraft?

    init(preferences: WebsitePreferences) {
        self.preferences = preferences
        super.init(window: nil)
        loadWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kickoff Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let label = NSTextField(labelWithString: "Website URL")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)

        websiteField.setAccessibilityLabel("Website URL")
        websiteField.placeholderString = WebsiteURL.approvedDefault.absoluteString

        let helper = NSTextField(labelWithString: "Open this website in both Chrome panes.")
        helper.textColor = .secondaryLabelColor

        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.isHidden = true
        errorLabel.setAccessibilityLabel("Website URL error")

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let form = NSStackView(views: [label, websiteField, helper, errorLabel])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 7
        websiteField.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        helper.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        errorLabel.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let content = NSView()
        window.contentView = content
        form.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(form)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            form.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -14),
        ])
        window.defaultButtonCell = saveButton.cell as? NSButtonCell
        window.initialFirstResponder = websiteField
        self.window = window
    }

    func show() {
        guard let window else {
            assertionFailure("Kickoff Settings window was not constructed.")
            return
        }
        if !window.isVisible {
            let draft = preferences.makeDraft()
            self.draft = draft
            websiteField.stringValue = draft.text
            showError(nil)
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(websiteField)
    }

    func windowWillClose(_ notification: Notification) {
        draft?.cancel()
        draft = nil
        showError(nil)
    }

    @objc private func cancel() {
        window?.performClose(nil)
    }

    @objc private func save() {
        guard let draft else { return }
        do {
            draft.update(websiteField.stringValue)
            _ = try draft.save()
            window?.performClose(nil)
        } catch let error as WebsiteValidationError {
            showError(error.description)
        } catch {
            showError("The website URL could not be saved.")
        }
    }

    private func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        if message != nil {
            window?.makeFirstResponder(websiteField)
        }
    }
}
