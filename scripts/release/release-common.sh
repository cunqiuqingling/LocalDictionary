#!/bin/zsh

set -euo pipefail

RELEASE_COMMON_PATH="${(%):-%x}"
RELEASE_SCRIPT_DIR="${RELEASE_COMMON_PATH:A:h}"
RELEASE_ROOT="${RELEASE_SCRIPT_DIR:h:h}"
RELEASE_PROJECT="$RELEASE_ROOT/App/LocalDictionary.xcodeproj"
RELEASE_SCHEME="LocalDictionary"
RELEASE_CONFIGURATION="Release"
RELEASE_PRODUCT="LocalDictionary"
RELEASE_BUNDLE_ID="com.localdict.LocalDictionary"
RELEASE_ARCHITECTURE="arm64"
RELEASE_DEPLOYMENT_TARGET="15.0"
RELEASE_BRANCH="feature/m24-release"

release_die() {
    print -u2 -- "release error: $*"
    exit 1
}

release_require_command() {
    command -v "$1" >/dev/null 2>&1 || release_die "required command is unavailable: $1"
}

release_require_xcode() {
    [[ -n "${DEVELOPER_DIR:-}" ]] ||
        release_die "DEVELOPER_DIR must explicitly select the reviewed Xcode installation"
    [[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] ||
        release_die "DEVELOPER_DIR does not contain xcodebuild: $DEVELOPER_DIR"
}

release_require_branch() {
    local branch
    branch="$(git -C "$RELEASE_ROOT" branch --show-current)"
    [[ "$branch" == "$RELEASE_BRANCH" ]] ||
        release_die "formal release requires branch $RELEASE_BRANCH (found: ${branch:-detached HEAD})"
}

release_require_clean_head() {
    local expected_head="$1"
    [[ -n "$expected_head" ]] || release_die "--expected-head is required for a formal release"
    release_require_branch
    [[ "$(git -C "$RELEASE_ROOT" rev-parse HEAD)" == "$expected_head" ]] ||
        release_die "HEAD does not match --expected-head"
    [[ -z "$(git -C "$RELEASE_ROOT" status --porcelain)" ]] ||
        release_die "formal release requires a clean worktree"
}

release_require_new_output() {
    local output="$1"
    [[ -n "$output" ]] || release_die "--output is required"
    [[ "$output" == /* ]] || release_die "--output must be an absolute path"
    [[ ! -e "$output" ]] || release_die "output path already exists: $output"
    /bin/mkdir -p "${output:h}"
}

release_build_settings() {
    local derived_data="$1"
    release_require_xcode
    "$DEVELOPER_DIR/usr/bin/xcodebuild" \
        -project "$RELEASE_PROJECT" \
        -scheme "$RELEASE_SCHEME" \
        -configuration "$RELEASE_CONFIGURATION" \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$derived_data" \
        -showBuildSettings
}

release_setting() {
    local settings_file="$1"
    local key="$2"
    /usr/bin/awk -F ' = ' -v key="$key" '
        $1 ~ "^[[:space:]]*" key "$" {
            print $2
            exit
        }
    ' "$settings_file"
}

release_require_version() {
    local supplied="$1"
    local actual="$2"
    [[ -n "$supplied" ]] || release_die "--version is required"
    [[ "$supplied" == "$actual" ]] ||
        release_die "version mismatch: requested $supplied, project is $actual"
    [[ "$actual" == <->(|.<->)(|.<->) ]] ||
        release_die "MARKETING_VERSION is not a numeric dotted version: $actual"
}

release_require_build_number() {
    local build="$1"
    [[ "$build" == <->(|.<->)* ]] ||
        release_die "CURRENT_PROJECT_VERSION is not a comparable numeric value: $build"
}

release_sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

release_file_size() {
    /usr/bin/stat -f '%z' "$1"
}

release_notary_state_class() {
    case "$1" in
        Submitted|"In Progress")
            print "pending"
            ;;
        Accepted)
            print "accepted"
            ;;
        Invalid|Rejected)
            print "rejected"
            ;;
        timeout)
            print "timeout"
            ;;
        *)
            print "unknown"
            return 1
            ;;
    esac
}

release_notary_outcome() {
    local service_state="$1"
    local log_result="$2"
    local staple_result="$3"
    local gatekeeper_result="$4"
    local service_class
    service_class="$(release_notary_state_class "$service_state")" || return 1
    case "$service_class" in
        pending) print "pending"; return 0 ;;
        timeout) print "timeout"; return 0 ;;
        rejected)
            [[ "$log_result" == "saved" ]] && print "rejected-log-saved" ||
                print "rejected-log-failed"
            return 0
            ;;
        accepted) ;;
        *) return 1 ;;
    esac
    [[ "$staple_result" == "passed" ]] || {
        print "staple-failed"
        return 0
    }
    [[ "$gatekeeper_result" == "passed" ]] || {
        print "gatekeeper-failed"
        return 0
    }
    print "releasable"
}

release_write_manifest() {
    local output="$1"
    shift
    /usr/bin/python3 - "$output" "$@" <<'PY'
import json
import sys

output = sys.argv[1]
pairs = sys.argv[2:]
if len(pairs) % 2:
    raise SystemExit("manifest arguments must be key/value pairs")
manifest = {"schemaVersion": 1}
for index in range(0, len(pairs), 2):
    key, value = pairs[index:index + 2]
    if key in {"artifactSize", "buildNumber"} and value.isdigit():
        value = int(value)
    elif key == "gitDirty":
        value = value == "true"
    manifest[key] = value
with open(output, "x", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
}
