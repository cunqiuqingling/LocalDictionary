# LocalDictionary <VERSION>

LocalDictionary is a native macOS menu-bar dictionary for macOS 15 or later on
Apple Silicon (arm64).

## Highlights

- Option-Space global selection lookup and manual search.
- Local, user-imported MDX indexing and query.
- Dictionary management, ordering, removal, favorites, and optional Obsidian notes.
- Chinese-to-English reverse lookup derived locally from the user's enabled bilingual
  dictionaries after an explicit index-build action.
- Apple system offline Chinese/English translation, with language-pack preparation only
  after an explicit user click.
- Long-text translation, at most 15 vocabulary items, per-sentence basic structure
  hints, and separate explicit per-sentence AI entry points.
- Selection-button placement that avoids known selection rectangles without Screen
  Recording.
- Optional AI explanation only after the user configures and invokes a provider.

## Privacy and network behavior

Local dictionary lookup stays on the Mac. Manually imported dictionary data is not
uploaded. AI requests occur only when a user has configured a provider and actively
uses the AI feature; its API key is stored in macOS Keychain. LocalDictionary does not
sell user data.

The production Resource Center endpoint, payload-host allowlist, and trust store are
currently empty, so it presents a safe empty state and performs no default resource
network request. Commercial dictionaries and dictionary payloads are not distributed
with the app.

## Install and verify

Download the arm64 ZIP and `SHA256SUMS` from the official project release, then run
`shasum -a 256 -c SHA256SUMS`. Unzip it and move `LocalDictionary.app` to
`/Applications` or `~/Applications`.

If this release uses the `-unsigned.zip` community asset, it has no Developer ID
signature or Apple notarization and Gatekeeper direct-open is not guaranteed. Try
opening it normally; if macOS blocks it, use System Settings → Privacy & Security →
Open Anyway for this app. Do not disable Gatekeeper or remove quarantine with `xattr`.
Grant Accessibility only if you want Option-Space to read the selected text. Import an
MDX only when you have the right to use it.

## Known limitations

- Intel Macs are not supported.
- Scanned PDFs require OCR outside LocalDictionary.
- Selection extraction varies by application; copying text into the search field
  remains the fallback.
- The production Resource Center currently has no listed resources.
- Basic system translation quality varies by language pair and installed Apple model;
  it is not represented as AI-quality or guaranteed.

## License

LocalDictionary original project code is distributed under GPL-3.0-only. Bundled
third-party components retain their existing licenses. Commercial dictionaries and
user-imported dictionary data are not part of the app distribution or relicensed by
the project.

See `docs/privacy.md`, `docs/release-process.md`, and `docs/release-checklist.md` in the
source repository for complete details.
