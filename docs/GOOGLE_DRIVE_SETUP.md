# Google Drive: simple connection, maintainer-owned setup

## For readers

The intended normal flow on Android, Windows and Linux is **Connect Google Drive
→ choose an account → approve backup access**. You do not need to create a Google
Cloud project or enter client credentials. Google backup remains optional; the
offline library does not require an account.

The [1.2.1 preview](releases/1.2.1-google-connect-preview.md) includes this simpler
connection/readability flow. The older 1.2.0 preview has the manual-credential
layout. **The new APK cannot update public 1.2.0 in place; do not uninstall or
clear app data to bypass the signing mismatch.** See
[release verification and limits](engineering/evidence/RELEASE-1.2.1.md).
Live personal-account consent, refresh and backup remain unverified.

If you previously configured a custom Google project, the repair preserves it.
Choosing **Use standard Google connection** keeps its saved ID/secret, clears only
Google's old authorization grant and requires reconnecting. It does not delete
books, chats, preferences or other provider connections. Custom fields are optional
Advanced settings, not normal onboarding.

`UNREGISTERED_ON_API_CONSOLE` means the app's Google registration needs attention.
Contact the app maintainer with the package/certificate details from connection
help. Do not uninstall, clear app data, or replace a personal Google password.
The maintainer must correct the registration; entering a Web secret alone cannot
fix it. Google authentication and Drive authorization are separate: backup still
requires the user's consent to the requested Drive access.

## Android: one-time maintainer configuration

1. Use the project intended to own CloudReader's Google connection. Enable the
   Google Drive API and configure OAuth audience/consent and any test users.
2. Create an **Android** OAuth client for package
   `io.github.haige120.cloudreader` and the **actual distributed APK's signing
   SHA-1**. Inspect the installed app's connection help or the APK itself.
3. Retain a stable, recoverable signing key for future builds. A newly generated
   CI debug key is a different Android identity. Never overwrite an existing
   registration or change signing keys merely to work around an OAuth error.
4. Default Android authorization uses Google Play services and the Drive app-data
   scope. It does not require distributing a Web client secret or operating a
   CloudReader backend.

Older and current preview certificates need separate registrations. The public
1.2.0 APK certificate is
`4F:2D:16:4E:E4:43:9D:5E:6A:1F:76:F2:AF:38:EC:6A:A9:77:84:C7`.
This is evidence for that APK only, not a permanent release identity. Losing its
private signing key cannot be repaired by extracting the public certificate from
the APK. A safe in-place Android update requires the matching private signing key.

The locally built 1.2.1 APK uses the retained older preview key:
`E3:F7:0B:33:F7:71:2E:FC:B3:75:5B:82:59:5F:BF:43:19:1E:11:9B`.
Its Android registration is retained. The temporary 1.2.0 private key is unavailable;
the new APK is not a safe update path for that installation. The retained private
key stays on the maintainer's Mac and is not uploaded to GitHub.

Custom Web-client/server-code exchange remains an advanced compatibility option;
Google documents server-code exchange for backends. A Web client must belong to
the same project as the Android registration. It is not needed by ordinary users.

## Windows/Linux: one-time maintainer configuration

Create a dedicated OAuth client of type **Desktop app** in the selected project.
Do not reuse an unrelated Rclone client or a Web-server client secret. Both desktop
platforms use the system browser, a 127.0.0.1 loopback callback, random state and
PKCE. Desktop clients are public clients; their client secret is not a confidential
server credential and must not be treated as proof of identity.

At build time, either set `CLOUDREADER_GOOGLE_DESKTOP_CREDENTIALS` to the absolute
path of the downloaded Desktop client JSON, or set
`CLOUDREADER_GOOGLE_DESKTOP_CLIENT_ID` and
`CLOUDREADER_GOOGLE_DESKTOP_CLIENT_SECRET` in the build environment. The JSON path
accepts only Google's `installed` client shape, not a `web` client. The build
generates the bundled `cloudreader-google-oauth.properties` resource; no credentials
file belongs in tracked source. Do not reuse credentials exposed in screenshots.

Coordinated CI reads the client ID from repository variable
`CLOUDREADER_GOOGLE_DESKTOP_CLIENT_ID` and the Desktop client secret from Actions
secret `CLOUDREADER_GOOGLE_DESKTOP_CLIENT_SECRET`. These are **maintainer build
settings**, never fields an ordinary reader must fill in. Without a configured
default, the app reports a maintainer-setup problem rather than pretending sign-in
is ready or forcing users to create projects.

For the official 1.2.1 Windows/Linux packages, protected settings are configured.
Both actual bundled launchers must prove configuration presence and the expected
input fingerprint before publication. This is build-input verification, not a
successful Google account authorization.

The app enables a destination only after successful authorization. Failed Connect
does not falsely mark it connected. Changed client credentials invalidate only
Google grants; blank secrets preserve a saved value only for the same client ID.
Error text uses known provider codes and never raw token responses or credentials.

## Shared-project caution and release acceptance

The owner chose to keep the existing Google project. Keep its Rclone clients,
branding, consent audience and existing grants intact unless separately authorized.
OAuth app branding belongs to the project, not each individual client: a new
CloudReader client within the existing project does not give it separate branding.
Do not silently change projects or migrate existing backups.

Before claiming a user-ready release, verify the installed Android signing
identity, Android registration, bundled Desktop client, consent/audience settings,
and authorized sign-in/renewal on all target platforms. UI/unit tests and merely
opening an account picker are not a successful Google round trip. Any billing,
legal agreement, credential rotation, permission expansion or public consent
publication needs the owner's separate approval at the relevant step.

Official references:

- [Android authorization and app registration](https://developer.android.com/identity/authorization)
- [Google Desktop OAuth and PKCE](https://developers.google.com/identity/protocols/oauth2/native-app)
