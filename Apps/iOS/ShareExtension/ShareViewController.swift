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
                try await SharedBookInbox.live.stage(provider)
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

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
