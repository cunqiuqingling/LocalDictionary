#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
RELEASE="$ROOT/scripts/release"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-release-tooling.XXXXXX")"
DIRTY_MARKER="$ROOT/.release-tooling-smoke-dirty.$$"
trap '/bin/rm -rf "$WORK"; /bin/rm -f "$DIRTY_MARKER"' EXIT
ASSERTIONS=0

expect_failure() {
    local label="$1"
    shift
    local output="$WORK/$label.log"
    if "$@" >"$output" 2>&1; then
        print -u2 "release command unexpectedly passed: $label"
        exit 1
    fi
    (( ASSERTIONS += 1 ))
}

expect_failure build-missing "$RELEASE/build-release.sh"
expect_failure build-mode "$RELEASE/build-release.sh" --mode invalid
expect_failure build-existing-output "$RELEASE/build-release.sh" \
    --mode unsigned-dry-run --version 0.1 --output "$WORK"
expect_failure dirty-formal "$RELEASE/build-release.sh" \
    --mode developer-id --version 0.1 --output "$WORK/formal" \
    --expected-head deadbeef --identity "Developer ID Application: Synthetic" --team-id SYNTHETIC
/usr/bin/touch "$DIRTY_MARKER"
expect_failure no-dirty-opt-in "$RELEASE/build-release.sh" \
    --mode unsigned-dry-run --version 0.1 --output "$WORK/no-opt-in"
/bin/rm -f "$DIRTY_MARKER"
expect_failure notary-no-submit "$RELEASE/notarize-release.sh"
expect_failure notary-profile-only "$RELEASE/notarize-release.sh" \
    --keychain-profile synthetic-profile

/bin/mkdir -p "$WORK/Synthetic App.app"
print synthetic >"$WORK/LocalDictionary-0.1-macOS-arm64-UNSIGNED-NOT-FOR-DISTRIBUTION.zip"
expect_failure unsigned-notary "$RELEASE/notarize-release.sh" \
    --app "$WORK/Synthetic App.app" \
    --submission-zip "$WORK/LocalDictionary-0.1-macOS-arm64-UNSIGNED-NOT-FOR-DISTRIBUTION.zip" \
    --output "$WORK/notary output" \
    --version 0.1 \
    --keychain-profile synthetic-profile \
    --expected-head deadbeef \
    --submit-notarization
expect_failure github-unsigned "$RELEASE/prepare-github-release.sh" \
    --version 0.1 \
    --artifact "$WORK/LocalDictionary-0.1-macOS-arm64-UNSIGNED-NOT-FOR-DISTRIBUTION.zip" \
    --checksums "$WORK/missing-checksums" \
    --manifest "$WORK/missing-manifest" \
    --output "$WORK/GitHub Output With Spaces" \
    --repository owner/repo

source "$RELEASE/release-common.sh"
for state in Submitted "In Progress"; do
    [[ "$(release_notary_state_class "$state")" == pending ]]
    (( ASSERTIONS += 1 ))
done
[[ "$(release_notary_state_class Accepted)" == accepted ]]
(( ASSERTIONS += 1 ))
for state in Invalid Rejected; do
    [[ "$(release_notary_state_class "$state")" == rejected ]]
    (( ASSERTIONS += 1 ))
done
[[ "$(release_notary_state_class timeout)" == timeout ]]
(( ASSERTIONS += 1 ))
if release_notary_state_class SyntheticUnknown >/dev/null 2>&1; then
    print -u2 "unknown notary state was accepted"
    exit 1
fi
(( ASSERTIONS += 1 ))

[[ "$(release_notary_outcome Submitted missing missing missing)" == pending ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome "In Progress" missing missing missing)" == pending ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome Rejected saved missing missing)" == rejected-log-saved ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome Invalid failed missing missing)" == rejected-log-failed ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome timeout missing missing missing)" == timeout ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome Accepted missing failed missing)" == staple-failed ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome Accepted missing passed failed)" == gatekeeper-failed ]]
(( ASSERTIONS += 1 ))
[[ "$(release_notary_outcome Accepted missing passed passed)" == releasable ]]
(( ASSERTIONS += 1 ))

for script in "$RELEASE"/*.sh "$ROOT/Tests"/run-m24-*.sh; do
    /bin/zsh -n "$script"
    (( ASSERTIONS += 1 ))
done

"$RELEASE/audit-release.sh" >"$WORK/audit.log"
/usr/bin/grep -q '^audit_status=passed$' "$WORK/audit.log"
(( ASSERTIONS += 1 ))
/usr/bin/grep -q '^external_credentials=not_read$' "$WORK/audit.log"
(( ASSERTIONS += 1 ))

require_pattern() {
    /usr/bin/grep -Eq "$1" "$2" || {
        print -u2 "missing fail-closed implementation pattern: $1"
        exit 1
    }
    (( ASSERTIONS += 1 ))
}
require_pattern 'IDENTITY_MATCHES.*== "1"' "$RELEASE/build-release.sh"
require_pattern 'release_require_clean_head' "$RELEASE/build-release.sh"
require_pattern 'notarytool log' "$RELEASE/notarize-release.sh"
require_pattern 'stapler staple' "$RELEASE/notarize-release.sh"
require_pattern 'spctl --assess' "$RELEASE/notarize-release.sh"

print "M24ReleaseToolingSmoke PASS ($ASSERTIONS/$ASSERTIONS)"
