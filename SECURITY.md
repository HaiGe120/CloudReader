# Security policy

The current Android/Windows/Linux downloads are previews, not a security audit
or production-hardening guarantee. There is no guaranteed support/response
period; identify the exact package, source revision and platform in a report.

## Report privately

Use GitHub's [private vulnerability reporting](https://github.com/HaiGe120/CloudReader/security/advisories/new).
Do not publish an exploit or include real keys, passwords, OAuth tokens, private
books, synced manifests or personal paths in a public issue.

Include the affected version/OS, a minimal reproduction with a synthetic book or
isolated destination, expected/actual behavior and likely impact. Sanitize logs
and screenshots. If private reporting is unavailable, open a public issue
requesting a private contact **without disclosing the vulnerability**.

## Important boundaries

- Book files/manifests are untrusted. Report archive traversal, resource
  exhaustion, unsafe WebKit content, command execution and arbitrary file access.
- Credentials and AI keys must not enter sync data, exports or logs. Desktop
  vault failure defaults to session-only secrets; an opted-in plaintext fallback
  is not equivalent to OS vault storage.
- AI context needs consent. Saved conversations/passages may be synchronized;
  use only provider accounts and destinations you trust.
- Sync is not application-level end-to-end encrypted. Schema v1 has no remote
  compare-and-swap guarantee: concurrent writers can overwrite unseen changes.
  Keep backups and sync devices sequentially.
- Debug APKs and unsigned Windows installers are previews. Check published
  hashes, but do not treat checksums as trusted production signing. Never delete
  an existing library to bypass a signing mismatch.

Use disposable libraries/accounts for security tests. Do not test another
person's library, provider service or account without authorization.
