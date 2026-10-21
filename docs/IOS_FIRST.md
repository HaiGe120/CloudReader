# iOS first

The active app is a native SwiftUI project in `Apps/iOS`, with an iOS 26.0 deployment target. Native iOS 26 Liquid Glass is applied to the app's interactive controls, and the system tab bar uses its native glass appearance.

## Build and run

Install Xcode 26 or later with an iOS 26 SDK, then install XcodeGen (`brew install xcodegen`) if it is not already available. Generate the project and open it:

```sh
cd Apps/iOS
xcodegen generate --spec CloudReader.xcodegen.yml
open CloudReader.xcodeproj
```

Choose the `CloudReader` scheme and an iOS 26 or later iPhone/iPad simulator. The initial deployment target is 26.0. For a physical iPhone or iPad, select the same valid development team for the app and its **CloudReaderShare** extension in **Signing & Capabilities**, and enable the `group.io.github.haige120.cloudreader` App Group for both targets.

## What works in this native build

- Import EPUB, PDF, TXT, MOBI, AZW3, FB2, CBZ, and CBR files through the system Files picker or **Open in CloudReader**, including locations exposed by iCloud Drive and other file providers. The first imported book opens directly.
- Choose **CloudReader** in another app's share sheet to save a copy. Open CloudReader afterward; queued books are imported automatically and the first opens for reading. The extension does not force another app to launch CloudReader.
- Copy selected files into the app's private Application Support directory; the original Files-provider documents remain untouched.
- Persist the book index, imported copies, bookmarks, and PDF/EPUB/TXT reading positions locally; search the library and remove imported copies.
- Read PDF with PDFKit, TXT with a selectable native text reader, and DRM-free EPUB with an in-app chapter reader. EPUB preparation runs off the main thread and is cached for faster reopening; damaged or DRM-protected books show an explanation instead of an indefinite preview.
- On wide screens, switch TXT and PDF to facing pages and turn spreads horizontally; compact iPhone layouts remain single-page.
- Choose system, light, sepia, dark, or custom paper/text colors and a font and text size for TXT and EPUB. PDF uses its fixed page typography.
- Select text in TXT to add **Ask CloudReader AI** to the selection menu. Selecting text in PDF reveals an **Ask AI about selection** action. Selecting text in EPUB exposes its **Ask AI about selection** button. These actions open the assistant with the excerpt visible and sharing enabled; the passage is sent only after the user submits a question.
- Seed the library with **The Open Shelf**, an original CC0 demo book about the CloudReader project.
- Keep managed book files and reading state on-device, then sync books, progress, bookmark flags, deletions, and saved AI conversations to every selected destination. Sync runs after local changes and when the app becomes active.
- Direct adapters: Google Drive (private app-data folder), Dropbox, pCloud, WebDAV, and password-authenticated SFTP with the server's OpenSSH host public key pinned by the user.
- Files-folder sync: choose an iCloud Drive, SMB, or third-party Files-provider folder. The selected folder contains a `CloudReader` subfolder.
- Ask questions through OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, or a compatible custom endpoint; API keys stay in Keychain.
- Ask the configured provider through a Siri/Shortcuts App Intent, or share a prompt to another app from the assistant.

MOBI, AZW3, FB2, CBZ, and CBR import into the library but do not yet have readers. Google Drive, Dropbox, and pCloud require provider app IDs; CloudReader does not embed shared provider credentials. Google sign-in requires an iOS OAuth client ID and requests only the `drive.appdata` scope. Dropbox uses PKCE and requests file-content and metadata read/write scopes. pCloud uses its documented mobile token flow and automatically follows the account's US or EU API region. OAuth tokens and WebDAV/SFTP passwords stay in Keychain. Use HTTPS for WebDAV, especially on untrusted networks.

SMB can be used through a folder provided by Files. Direct SMB protocol support is not bundled. Files-folder sync depends on the provider app being installed and reachable. Sync currently runs while the app is foregrounded; it is not an iOS background transfer service. If two devices changed the same book while offline, the newer timestamp wins; a position conflict chooser remains future work.

## Provider setup

1. **Google Drive:** create an iOS OAuth client for the CloudReader bundle identifier, enable the Drive API, and enter its client ID in Settings. CloudReader derives the required reversed-client-ID callback and stores sync data in Drive's private app-data folder.
2. **Dropbox:** create a scoped-access app and enable `files.content.read`, `files.content.write`, `files.metadata.read`, and `files.metadata.write`. Register `db-<APP_KEY>://2/token` as the redirect URI, then enter the app key in Settings. CloudReader uses PKCE and does not need an app secret.
3. **pCloud:** create an app in the pCloud developer console, register `cloudreader://pcloud-oauth` as the redirect URI, and enter the app ID in Settings. CloudReader uses the pCloud OAuth flow intended for mobile clients, keeps the token in Keychain, and routes API calls to the region returned during authorization.
4. **WebDAV:** enter the HTTPS server base URL and credentials. CloudReader creates a `CloudReader` collection below that URL.
5. **SFTP:** enter the server, port, user, password, writable remote directory, and the server's OpenSSH public host key. CloudReader verifies the pinned key during SSH negotiation and refuses a different key.
6. **iCloud Drive, SMB, or other Files locations:** choose a sync folder through the system Files picker, then select **Files folder** as one of the sync destinations. Choose the same shared folder on other devices. MEGA or PikPak can use this route when the installed app exposes its storage in Files; neither has a direct iOS adapter yet.

Select one or more connected destinations per library. CloudReader merges changes from each selected destination and writes the combined library back to all of them. Configure and select the matching destinations on each device. Other providers can still be used to import books from Files. Provider tokens, AI API keys, and passwords are not written into the sync manifest.

## AI assistant setup

In **Settings → AI assistant**, choose **Remote API** or **Apple on-device model**. For a remote provider, choose its API format, enter the model ID and API key, and optionally provide a full endpoint URL. Leave the URL blank to use the provider's standard endpoint. Custom endpoints must implement the selected protocol shape. API keys stay in this device's Keychain; remote requests go directly from the app to the configured endpoint and require an internet connection. The on-device option uses Apple Foundation Models on iOS 26+ when the device supports Apple Intelligence, it is enabled, and the model is ready. The app reports when it is unavailable.

AI conversations are saved locally as you chat and appear in **Conversation history**. When sync destinations are selected, CloudReader syncs the messages and the book context saved with that conversation, including any selected passage, to each destination. API keys remain in Keychain and are never included. When opened from a book, the assistant has an **Include book text in my request** switch. The current build can extract a bounded excerpt from TXT and PDF files, or use the passage selected from either format. EPUB can attach the passage selected in its in-app reader; extracting a whole-book EPUB excerpt is not supported yet. An excerpt is sent to a remote AI only when the reader presses **Send**. A general question from the library sends no book text.

Say “Ask CloudReader a question” to Siri or Shortcuts and provide the question when prompted; this uses the selected AI provider and does not attach a book automatically. For Apple's system ChatGPT experience, configure ChatGPT under **Settings → Apple Intelligence & Siri → ChatGPT** on a supported device. The assistant's share button passes prompt text to the iOS share sheet; ChatGPT can be selected if iOS exposes it as a destination. CloudReader does not use a private ChatGPT URL scheme or sign into the ChatGPT app.

The default iOS CloudReader profile stores one active AI configuration. The client currently sends non-streaming text requests and supports the endpoint protocol's basic text response; tool/function calling, image attachments, and audio are future work.

## Validation before broadening platform work

Test on an iOS 26+ simulator and a physical device, including the iPhone Duo's compact and expanded postures:

- import EPUB, PDF, and TXT from On My iPhone/iPad and a Files provider; test **Open in CloudReader** and sharing to CloudReader from another app, then foreground CloudReader to finish the import;
- confirm the imported copy and PDF/EPUB/TXT reading position persist after force-quitting and that the selected original file remains unchanged;
- test PDF zoom, rotation, and page navigation, EPUB chapter navigation, reopening from cache, selected-passage AI, and invalid/DRM-protected book errors, UTF-8/UTF-16 TXT, and CJK content;
- test facing-page layout on the iPhone Duo and iPad, text themes/fonts and custom colors, resuming after changing type size, and Ask AI from a selected TXT/PDF passage;
- check Dynamic Type, VoiceOver, light and dark appearance, landscape layouts, and the visible interaction of the native Liquid Glass controls;
- test two-device sync, token refresh, SFTP host-key mismatch, WebDAV authentication failures, SMB through Files, deletions, and interrupted transfers;
- configure signing and validate a TestFlight archive before App Store submission.
