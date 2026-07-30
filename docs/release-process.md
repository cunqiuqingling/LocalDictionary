# LocalDictionary release process

This document describes the prepared Developer ID distribution process. It does not
declare that a signed or notarized binary has been published. The repository version is
currently `0.1` with build number `1`; a human must freeze the final version before any
tag or public release.

## Security boundary

The formal sequence is:

1. Start from an explicitly approved, clean commit on `feature/m24-release`.
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
stapling, or Gatekeeper success occurred. The Mach-O linker may attach an ad-hoc
signature required by modern macOS; the verifier accepts only no signature or that
authority-free ad-hoc form and never treats it as Developer ID signing. A dirty tree is
accepted only with the explicit test-only `--allow-dirty-dry-run` option.

`build-release.sh --mode developer-id` requires a clean worktree, exact branch and HEAD,
an explicit version matching Xcode build settings, an explicit Team ID, and exactly one
matching Developer ID Application identity. It uses Xcode's standard archive/export
flow with the current `developer-id` export method.

`notarize-release.sh` is a separate action. It rejects unsigned asset names, validates
the signed bundle, requires a clean exact HEAD and an explicit Keychain profile, and
cannot submit unless `--submit-notarization` is also present. Failed service responses
stop the pipeline; a sanitized diagnostic log may be retained outside the repository.

`prepare-github-release.sh` is offline. It validates a canonical notarized asset,
checksum, and manifest, then writes release notes and a draft-first command for later
human execution.

## Canonical output

The public asset is:

`LocalDictionary-<version>-macOS-arm64.zip`

It contains only `LocalDictionary.app`. Public checksums are recorded in
`SHA256SUMS`; `release-manifest.json` records the version, build, bundle identifier,
architecture, minimum macOS, commit, Xcode/SDK, size, SHA-256, signing summary,
entitlements, notarization submission ID when one truly exists, staple and Gatekeeper
status, and build timestamp. A dSYM may be retained separately for crash diagnosis but
is not a default public asset.

## Entitlements and permissions

`App/LocalDictionaryRelease.entitlements` is intentionally empty. Code evidence does
not justify JIT, unsigned executable memory, disabled library validation, debugger,
DYLD, Apple Events, camera, microphone, location, network-server, sandbox file, or
Keychain-group exceptions. Hardened Runtime is enabled only for Release.

App Sandbox remains disabled because enabling it is a product architecture change and
could break the existing global selection and user-selected dictionary workflows.
Hardened Runtime and App Sandbox are separate controls. The app requests Accessibility
only when the user uses global selection lookup; it does not require Screen Recording,
microphone, or system-audio permission.

## External inputs for final acceptance

- one valid Developer ID Application certificate and private key;
- the corresponding Apple Team ID;
- a user-created `notarytool` Keychain profile name;
- an approved final version/build and clean commit;
- GitHub repository write permission;
- explicit authorization for signing, notarization submission, tag creation, pushing,
  draft creation, asset upload, and publication.

None of these values or secrets belongs in the repository.
