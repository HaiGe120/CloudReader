import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 320)

        titleLabel.text = "Adding to CloudReader"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        messageLabel.text = "Saving a copy of your book…"
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)
        doneButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [activityIndicator, titleLabel, messageLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        activityIndicator.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        Task { await saveSharedBooks() }
    }

    private func saveSharedBooks() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var saved = 0
        var failures = 0
        var lastError: Error?
        for provider in providers {
            do {
                try await stage(provider)
                saved += 1
            } catch {
                failures += 1
                lastError = error
            }
        }

        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        doneButton.isHidden = false
        if saved > 0 {
            titleLabel.text = saved == 1 ? "Book saved" : "\(saved) books saved"
            messageLabel.text = "Open CloudReader to read \(saved == 1 ? "your book" : "them"). \(saved == 1 ? "It will" : "They will") be added to your library automatically."
            if failures > 0 { messageLabel.text? += " \(failures) \(failures == 1 ? "file could" : "files could") not be added." }
        } else {
            titleLabel.text = "Couldn't add this book"
            messageLabel.text = lastError?.localizedDescription ?? SharedBookInbox.InboxError.unsupportedFile.localizedDescription
        }
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    private func stage(_ provider: NSItemProvider) async throws {
        let suggestedName = provider.suggestedName
        let specificTypeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier), let fileExtension = type.preferredFilenameExtension else { return false }
            return SharedBookInbox.supportedExtensions.contains(fileExtension.lowercased())
        }
        let suggestedExtension = suggestedName.map { ($0 as NSString).pathExtension.lowercased() }
        let genericTypeIdentifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
        let typeIdentifier = specificTypeIdentifier ?? (suggestedExtension.map { SharedBookInbox.supportedExtensions.contains($0) } == true ? genericTypeIdentifier : nil)

        if let typeIdentifier {
            let preferredExtension = specificTypeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? suggestedExtension
            do {
                try await stageFileRepresentation(provider, typeIdentifier: typeIdentifier, suggestedName: suggestedName, preferredExtension: preferredExtension)
                return
            } catch {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { throw error }
            }
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { throw SharedBookInbox.InboxError.unsupportedFile }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url else {
                    continuation.resume(throwing: error ?? SharedBookInbox.InboxError.unsupportedFile)
                    return
                }
                do {
                    try SharedBookInbox.live.stageFile(at: url, suggestedName: suggestedName)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func stageFileRepresentation(_ provider: NSItemProvider, typeIdentifier: String, suggestedName: String?, preferredExtension: String?) async throws {
        // Item-provider URLs are valid only inside this completion handler.
        // Copy into the app group before resuming the async operation.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? SharedBookInbox.InboxError.unsupportedFile)
                    return
                }
                do {
                    try SharedBookInbox.live.stageFile(at: url, suggestedName: suggestedName, preferredExtension: preferredExtension)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
