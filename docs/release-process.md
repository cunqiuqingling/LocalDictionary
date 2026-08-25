# LocalDictionary release process

This document describes both the zero-cost community unsigned path and the prepared,
optional Developer ID distribution process. It does not declare that any binary has been
published. The repository version is
currently `0.1` with build number `1`; a human must freeze the final version before any
tag or public release.

## Security boundary

The formal sequence is:

1. Start from an explicitly approved, clean commit on
   `feature/prerelease-offline-language`.
2. Run `scripts/release/audit-release.sh`.
3. Archive the `LocalDictionary` scheme in Release for generic macOS.
4. Export with one unambiguous `Developer ID Application` identity, the approved Team
   ID, hardened runtime, secure timestamp, and the unique Release entitlements file.
5. Enumerate and sign nested code from the inside out. The current bundle has no nested
   Mach-O code; the app executable is the only Mach-O. `codesign --deep` is not used as
   the signing strategy.
6. Verify the signature and create a separately named
   `LocalDictionary-<version>-macOS-arm64-NOTARIZATION-SUBMISSION.zip`. It is not the
   canonical public asset.
7. Only after explicit human authorization, run `notarize-release.sh` with a
   user-created Keychain profile and `--submit-notarization`.
8. Require an `Accepted` result, staple the ticket to the app, validate the staple,
   verify the signature, and run Gatekeeper assessment.
9. Create the final ZIP from the stapled app, then calculate `SHA256SUMS` and the release
   manifest. Do not mutate the app or ZIP afterward.
10. Prepare a draft-first GitHub Release. Review the tag, notes, assets, checksums, and
    manifest before a separate, explicitly authorized network action.

The scripts never create certificates, read generic Keychain passwords, store an
app-specific password, accept an Apple ID password on the command line, call `altool`,
create a tag, push, or invoke `gh release create`. The prepared GitHub command is text
for a human to review; it is never executed automatically.

## Modes

`audit-release.sh` performs configuration and local-tool auditing without building or
reading credentials.

`build-release.sh --mode unsigned-dry-run` archives with
`CODE_SIGNING_ALLOWED=NO`. Its asset name includes
`UNSIGNED-NOT-FOR-DISTRIBUTION`, and the manifest records that no notarization,
stapling, or Gatekeeper success occurred. After Xcode produces the archive, the release
script replaces the executable-only linker signature with an authority-free ad-hoc signature
over the complete App Bundle, enables Hardened Runtime, and seals `Info.plist` and all bundled
resources. The verifier requires strict bundle signature validation and never treats this as
Developer ID signing. A dirty tree is accepted only with the explicit test-only
`--allow-dirty-dry-run` option.

`build-release.sh --mode community-unsigned` is the zero-cost public distribution mode.
It requires a clean exact branch/HEAD and rejects the dry-run dirty override, Team ID,
and signing identity. It archives with signing disabled, produces
`LocalDictionary-<version>-macOS-arm64-unsigned.zip`, and records
`github-community-unsigned`, `ad-hoc`, `authority-free-ad-hoc`, `not-submitted`,
`stapled: false`, and `gatekeeperDirectOpen: not-guaranteed` in the manifest. The complete
App Bundle is ad-hoc signed with Hardened Runtime and an empty entitlement set so
`codesign --verify --deep --strict` succeeds. This prevents an incomplete linker signature
from being reported as a damaged bundle, but it is not a Developer ID signature and is not
eligible for Apple notarization.

`build-release.sh --mode developer-id` requires a clean worktree, exact branch and HEAD,
an explicit version matching Xcode build settings, an explicit Team ID, and exactly one
matching Developer ID Application identity. It uses Xcode's standard archive/export
flow with the current `developer-id` export method.

`notarize-release.sh` is a separate action. It rejects unsigned asset names, validates
the signed bundle, requires a clean exact HEAD and an explicit Keychain profile, and
cannot submit unless `--submit-notarization` is also present. Failed service responses
stop the pipeline; a sanitized diagnostic log may be retained outside the repository.

`prepare-github-release.sh` is offline. With `--mode notarized` it validates the
canonical notarized asset. With `--mode community-unsigned` it validates the distinct
unsigned name and exact fail-closed manifest fields. Both modes write release notes and
a draft-first command for later human review; neither invokes GitHub.

## Canonical output

The notarized public asset is:

`LocalDictionary-<version>-macOS-arm64.zip`

The community unsigned public asset is:

`LocalDictionary-<version>-macOS-arm64-unsigned.zip`

It contains only `LocalDictionary/LocalDictionary.app`. The outer folder prevents Finder
from adding a numeric duplicate suffix to the App Bundle itself when users extract multiple
downloads in the same directory; the App filename, `CFBundleName`, and `CFBundleDisplayName`
remain exactly `LocalDictionary`. Public checksums are recorded in
`SHA256SUMS`; `release-manifest.json` records the version, build, bundle identifier,
architecture, minimum macOS, commit, Xcode/SDK, size, SHA-256, signing summary,
entitlements, notarization submission ID when one truly exists, staple and Gatekeeper
status, distribution channel, and build timestamp. A dSYM may be retained separately for crash diagnosis but
is not a default public asset.

Release ZIPs are created without resource-fork/AppleDouble sidecar entries. Verification
rejects `._*` and `__MACOSX` entries, tests ZIP integrity, enforces the canonical nested
App path and exact Bundle display name, and requires the extracted community App Bundle
to retain its complete resource seal.

Community users must verify `SHA256SUMS` and obtain the asset from the official project
release. Its authority-free ad-hoc signature provides bundle integrity but no Apple-trusted
developer identity. Because it has neither Developer ID signing nor notarization, Gatekeeper
may block first launch. The supported exception is the per-app “Open Anyway” action in
System Settings → Privacy & Security. Documentation must never tell users to disable
Gatekeeper globally or strip quarantine with `xattr`.

## Entitlements and permissions

`App/LocalDictionaryRelease.entitlements` is intentionally empty. Code evidence does
not justify JIT, unsigned executable memory, disabled library validation, debugger,
DYLD, Apple Events, camera, microphone, location, network-server, sandbox file, or
Keychain-group exceptions. Hardened Runtime is enabled only for Release.

App Sandbox remains disabled because enabling it is a product architecture change and
could break the existing global selection and user-selected dictionary workflows.
Hardened Runtime and App Sandbox are separate controls. On first launch the app explains
the optional Accessibility permission before showing the User Guide reminder. Accessibility
is used only for global selection lookup; manual search works without it. The app does not
require Screen Recording, microphone, or system-audio permission.

## External inputs for final acceptance

- one valid Developer ID Application certificate and private key;
- the corresponding Apple Team ID;
- a user-created `notarytool` Keychain profile name;
- an approved final version/build and clean commit;
- GitHub repository write permission;
- explicit authorization for signing, notarization submission, tag creation, pushing,
  draft creation, asset upload, and publication.

None of these values or secrets belongs in the repository.
