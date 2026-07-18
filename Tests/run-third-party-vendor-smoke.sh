#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VENDOR="$ROOT/ThirdParty/vendor"
PROJECT="$ROOT/App/LocalDictionary.xcodeproj/project.pbxproj"
BUILD_SCRIPTS=(
  "$ROOT/MDictCore/ValidationCLI/build.sh"
  "$ROOT/MDictCore/DictionaryCoreCLI/build.sh"
)

expected=(
  libtomcrypt-ripemd128/LICENSE
  libtomcrypt-ripemd128/include/tomcrypt.h
  libtomcrypt-ripemd128/src/rmd128.c
  mdict-cpp/AUTHORS
  mdict-cpp/LICENSE
  mdict-cpp/patches/0003-libtomcrypt-ripemd128-adapter.patch
  mdict-cpp/src/adler32.cc
  mdict-cpp/src/binutils.cc
  mdict-cpp/src/encode/api.h
  mdict-cpp/src/encode/base64.h
  mdict-cpp/src/encode/char_decoder.h
  mdict-cpp/src/include/adler32.h
  mdict-cpp/src/include/binutils.h
  mdict-cpp/src/include/bounded_zlib.h
  mdict-cpp/src/include/checked_arithmetic.h
  mdict-cpp/src/include/resource_limits.h
  mdict-cpp/src/include/mdict.h
  mdict-cpp/src/include/mdict_extern.h
  mdict-cpp/src/include/mdict_simple_key.h
  mdict-cpp/src/include/xmlutils.h
  mdict-cpp/src/include/zlib_wrapper.h
  mdict-cpp/src/mdict.cc
  miniz/LICENSE
  miniz/miniz.c
  miniz/miniz.h
  miniz/miniz_common.h
  miniz/miniz_tdef.c
  miniz/miniz_tdef.h
  miniz/miniz_tinfl.c
  miniz/miniz_tinfl.h
)

actual=("${(@f)$(cd "$VENDOR" && find . -type f -print | sed 's#^\./##' | sort)}")
sorted_expected=("${(@f)$(printf '%s\n' "${expected[@]}" | sort)}")
[[ "${(j:\n:)actual}" == "${(j:\n:)sorted_expected}" ]] || {
  print -u2 "Vendored dependency file set is not minimal or is incomplete."
  exit 1
}

(cd "$ROOT/ThirdParty" && shasum -a 256 -c SHA256SUMS >/dev/null)

for relative_path in "${expected[@]}"; do
  [[ -f "$VENDOR/$relative_path" ]] || exit 1
  git check-ignore -q "$VENDOR/$relative_path" && {
    print -u2 "Reviewed vendor file is still ignored: $relative_path"
    exit 1
  }
done

for forbidden in turbobase64 minilzo hunspell googletest benchmark examples tests; do
  find "$VENDOR" -type d -name "$forbidden" -print -quit | grep -q . && {
    print -u2 "Forbidden dependency directory present: $forbidden"
    exit 1
  }
done

scan_files=(
  "$PROJECT"
  "${BUILD_SCRIPTS[@]}"
  "${(@f)$(/usr/bin/find "$ROOT/Tests" -type f \
    ! -name README.md ! -name run-third-party-vendor-smoke.sh -print)}"
)
if /usr/bin/grep -Eq \
    'ThirdParty/mdict-cpp|src/ripemd128\.c|miniz_zip|turbobase64' \
    "${scan_files[@]}"; then
  print -u2 "A build or test path still references the ignored checkout."
  exit 1
else
  scan_exit=$?
  if (( scan_exit != 1 )); then
    print -u2 "Unable to complete the portable build-path scan."
    exit 1
  fi
fi

if /usr/bin/grep -REq 'Katholieke Universiteit Leuven|All Rights Reserved' \
    "$VENDOR/libtomcrypt-ripemd128"; then
  print -u2 "The unlicensed legacy RIPEMD sample is still present."
  exit 1
else
  scan_exit=$?
  if (( scan_exit != 1 )); then
    print -u2 "Unable to complete the portable RIPEMD source scan."
    exit 1
  fi
fi

print "Third-party vendor smoke passed"
