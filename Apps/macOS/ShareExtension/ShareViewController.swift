import AppKit

final class ShareViewController: NSViewController {
    private let status = NSTextField(wrappingLabelWithString: "Adding to CloudReader…")
    private lazy var doneButton = NSButton(title: "Done", target: self, action: #selector(finish))
    private var started = false

    override func loadView() {
        let stack = NSStackView(views: [status, doneButton])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        stack.alignment = .centerX
        view = stack
        preferredContentSize = NSSize(width: 360, height: 130)
        doneButton.isEnabled = false
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        Task { await saveBooks() }
    }

    private func saveBooks() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var saved = 0
        var failure: Error?
        for provider in providers {
            do {
                try await SharedBookInbox.live.stage(provider)
                saved += 1
            } catch {
                failure = error
            }
        }
        if saved == 0 {
            status.stringValue = failure?.localizedDescription ?? SharedBookInbox.InboxError.unsupportedFile.localizedDescription
        } else {
            let result = saved == 1 ? "Book saved." : "\(saved) books saved."
            let skipped = providers.count - saved
            status.stringValue = result + " Open CloudReader to read." + (skipped > 0 ? " Failed to add \(skipped)." : "")
        }
        doneButton.isEnabled = true
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
