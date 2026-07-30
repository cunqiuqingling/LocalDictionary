# LocalDictionary release checklist

## Before archive

- [ ] Distribution mode is explicitly chosen: `community-unsigned` or `developer-id`;
      unsigned status is never described as notarized or Developer ID signed.
- [ ] Human approved the marketing version and build number.
- [ ] Worktree is clean, branch and HEAD are exact, and all public tests passed.
- [ ] `audit-release.sh` passes with the reviewed Xcode selected by `DEVELOPER_DIR`.
- [ ] Production Resource Center endpoint, allowed payload hosts, and trust keys are
      empty.
- [ ] Root GPL-3.0-only license, privacy text, third-party notice, mdict-cpp license, and
      miniz license are byte-identical to the bundled `ReleaseLegal` resources; the
      LibTomCrypt license matches after the documented one-space normalization.
- [ ] Exactly one approved Developer ID Application identity is available.
- [ ] Team ID and user-created notary Keychain profile name are supplied out of band.

## Archive, signing, and notarization

- [ ] Archive uses scheme `LocalDictionary`, Release, generic macOS, arm64.
- [ ] Export uses Developer ID, Hardened Runtime, secure timestamp, and the empty
      Release entitlements file.
- [ ] Bundle audit passes before and after signing.
- [ ] Nested Mach-O list is reviewed; current expectation is only
      `Contents/MacOS/LocalDictionary`.
- [ ] `codesign -d --verbose=4`, entitlement display, and strict deep verification pass.
- [ ] Notarization submission was separately and explicitly authorized.
- [ ] Service result is `Accepted`; submission ID is recorded.
- [ ] Staple, staple validation, post-staple signature verification, and Gatekeeper
      assessment pass.

## Artifact and GitHub

- [ ] Community mode uses
      `LocalDictionary-<version>-macOS-arm64-unsigned.zip`; its manifest says
      `github-community-unsigned`, `unsigned`, `not-submitted`, `stapled: false`, and
      `gatekeeperDirectOpen: not-guaranteed`.
- [ ] Developer ID mode uses `LocalDictionary-<version>-macOS-arm64.zip` only after
      accepted notarization and successful staple/Gatekeeper verification.
- [ ] Final ZIP was regenerated from the stapled app and contains only
      `LocalDictionary.app`.
- [ ] Final name is `LocalDictionary-<version>-macOS-arm64.zip`.
- [ ] `SHA256SUMS` and `release-manifest.json` match the immutable final ZIP.
- [ ] Release notes accurately state macOS 15+, Apple Silicon, privacy/network behavior,
      empty production Resource Center catalog, manual MDX import, and known limits.
- [ ] No commercial dictionary, user data, test fixture, secret, dSYM, or build cache is
      in the public ZIP.
- [ ] Tag creation, push, draft creation, uploads, and publication each have explicit
      human approval.
- [ ] Draft assets and checksums are reviewed before making the release public.

## Installation and removal

1. Download the ZIP and `SHA256SUMS`, then verify:
   `shasum -a 256 -c SHA256SUMS`.
2. Unzip and move `LocalDictionary.app` to `/Applications` or `~/Applications`.
3. For a notarized build, start the app normally. For a community unsigned build, first
   try opening normally; if macOS blocks it, use only System Settings → Privacy &
   Security → Open Anyway for this app. Do not disable Gatekeeper and do not remove
   quarantine with `xattr`.
4. Grant Accessibility only if using Option-Space selection lookup.
5. Import an owned/licensed MDX manually. The app does not ship commercial dictionaries.
6. The production Resource Center is intentionally empty until reviewed signed resource
   configuration is deployed.
7. Removing the app does not remove user data. To remove dictionaries, Catalog state,
   settings, or Keychain entries, use the corresponding app/system controls and review
   the data separately before deletion.
