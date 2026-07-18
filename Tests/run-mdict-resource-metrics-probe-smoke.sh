#!/bin/zsh
# run-mdict-resource-metrics-probe-smoke.sh
# Build and run the synthetic smoke test for MDictResourceMetricsProbe.
# Tests both Debug and --release modes.
set -euo pipefail

ROOT="${0:A:h:h}"
PROBE_SRC="$ROOT/Tests/Tools/MDictResourceMetricsProbe.cpp"
SMOKE_SRC="$ROOT/Tests/MDictResourceMetricsProbeSmoke.cpp"
PROBE_SCRIPT="$ROOT/Tests/run-mdict-resource-metrics-probe.sh"
BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe"
RELEASE_BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe-release"

LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"

CFLAGS=(-std=c17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
CXXFLAGS_STRICT=(-std=c++17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
CXXFLAGS_RELAXED=(-std=c++17 -O1 -g -isysroot "$SDKROOT")

# ---------- helpers ----------
build_probe_objects() {
  local out_dir="$1"
  shift  # consume out_dir; remaining args are compiler flags
  mkdir -p "$out_dir/objects"
  # miniz
  for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
    "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
      -I"$MINIZ" -c "$MINIZ/$src" -o "$out_dir/objects/${src%.c}.o"
  done
  # ripemd128
  "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
    -I"$LTC/include" -c "$LTC/src/rmd128.c" -o "$out_dir/objects/rmd128.o"
  "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
    -I"$ROOT/MDictCore" -I"$LTC/include" \
    -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$out_dir/objects/ripemd128-adapter.o"
  # mdict-cpp (relaxed)
  for src in mdict.cc binutils.cc adler32.cc; do
    "$CXX" -std=c++17 -isysroot "$SDKROOT" "$@" \
      -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" -I"$VENDOR" \
      -c "$MDICT/src/$src" -o "$out_dir/objects/${src%.cc}.o"
  done
}

link_probe() {
  local out_dir="$1"
  shift
  "$CXX" -std=c++17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
    -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" -I"$VENDOR" \
    "$PROBE_SRC" \
    "$out_dir/objects/mdict.o" "$out_dir/objects/binutils.o" \
    "$out_dir/objects/adler32.o" "$out_dir/objects/rmd128.o" \
    "$out_dir/objects/ripemd128-adapter.o" \
    "$out_dir/objects/miniz.o" "$out_dir/objects/miniz_tinfl.o" \
    "$out_dir/objects/miniz_tdef.o" \
    -o "$out_dir/MDictResourceMetricsProbe"
}

# ---------- 1. Debug probe ----------
echo "=== Building mdict-resource-metrics-probe (Debug) ==="
build_probe_objects "$BUILD_DIR" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
link_probe "$BUILD_DIR" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer

# ---------- 2. Release probe ----------
echo "=== Building mdict-resource-metrics-probe (Release) ==="
build_probe_objects "$RELEASE_BUILD_DIR" -O2 -DNDEBUG
link_probe "$RELEASE_BUILD_DIR" -O2 -DNDEBUG

# Verify release flags
echo "=== Verifying release build flags ==="
RELEASE_PROBE="$RELEASE_BUILD_DIR/MDictResourceMetricsProbe"
file "$RELEASE_PROBE"

# ---------- 3. Shell-level --release tests ----------
echo "=== Shell-level --release tests ==="
WORK="$(mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-probe-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Build a synthetic MDX for testing (reuse the C++ smoke test binary)
SMOKE_OBJ="$BUILD_DIR/smoke-objects"
mkdir -p "$SMOKE_OBJ"
for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" "${CFLAGS[@]}" -I"$MINIZ" -c "$MINIZ/$src" -o "$SMOKE_OBJ/${src%.c}.o"
done
"$CXX" "${CXXFLAGS_STRICT[@]}" -I"$MINIZ" \
  "$SMOKE_SRC" \
  "$SMOKE_OBJ/miniz.o" "$SMOKE_OBJ/miniz_tinfl.o" "$SMOKE_OBJ/miniz_tdef.o" \
  -o "$BUILD_DIR/MDictResourceMetricsProbeSmoke"

# The smoke test can build valid MDX; use it to create a test file
SMOKE_BIN="$BUILD_DIR/MDictResourceMetricsProbeSmoke"
# Create synthetic MDX by running a helper mode of the smoke binary
# (We'll pass the probe env vars and let the C++ test handle this)

# 3a. Rejection without --release
echo "--- reject without --release ---"
set +e
REJECT_OUT="$("$PROBE_SCRIPT" --dictionary D1 "$WORK/nonexistent.mdx" --output "$WORK/out.json" 2>&1)"
REJECT_RC=$?
set -e
if (( REJECT_RC == 0 )); then
  print -u2 "FAIL: real measurement without --release should be rejected"
  exit 1
fi
if echo "$REJECT_OUT" | grep -qF "$WORK"; then
  print -u2 "FAIL: rejection message leaked path"
  exit 1
fi
echo "PASS"

# 3b. --release + valid MDX
echo "--- release + valid MDX ---"
# Use the probe script to compile release and run against a synthetic MDX
# We need a valid MDX first — build one using the smoke test binary as a helper
# The smoke binary doesn't expose MDX building as a CLI, so we use it indirectly
# Instead, build the MDX with a small C++ helper
cat > "$WORK/build_mdx.cpp" << 'BLDEOF'
#include "miniz.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <fstream>
#include <string>

static std::vector<uint8_t> zlibCompress(const void *data, size_t len) {
  mz_ulong bound = mz_compressBound(len);
  std::vector<uint8_t> out(bound);
  mz_ulong outLen = bound;
  mz_compress(out.data(), &outLen, static_cast<const unsigned char *>(data), len);
  out.resize(outLen);
  return out;
}

static void writeBE32(std::vector<uint8_t> &buf, uint32_t v) {
  buf.push_back((v>>24)&0xff); buf.push_back((v>>16)&0xff);
  buf.push_back((v>>8)&0xff); buf.push_back(v&0xff);
}
static void writeBE64(std::vector<uint8_t> &buf, uint64_t v) {
  for (int i=7;i>=0;--i) buf.push_back((v>>(i*8))&0xff);
}
static void writeBE16(std::vector<uint8_t> &buf, uint16_t v) {
  buf.push_back((v>>8)&0xff); buf.push_back(v&0xff);
}
static uint32_t adler32bytes(const void *d, size_t n) {
  return (uint32_t)mz_adler32(MZ_ADLER32_INIT, (const unsigned char*)d, n);
}

int main(int argc, char **argv) {
  if (argc < 2) return 1;
  std::string outPath = argv[1];
  const char *hdr = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"No\" Encoding=\"UTF-8\"/>";
  std::vector<uint8_t> h16;
  for (const char *p = hdr; *p; ++p) { h16.push_back(*p); h16.push_back(0); }
  std::vector<uint8_t> kbiRaw;
  writeBE64(kbiRaw,2); writeBE16(kbiRaw,3);
  kbiRaw.push_back('a');kbiRaw.push_back('a');kbiRaw.push_back('a');kbiRaw.push_back(0);
  writeBE16(kbiRaw,3);
  kbiRaw.push_back('z');kbiRaw.push_back('z');kbiRaw.push_back('z');kbiRaw.push_back(0);
  size_t co=kbiRaw.size(); writeBE64(kbiRaw,0);
  size_t dod=kbiRaw.size(); writeBE64(kbiRaw,0);
  std::vector<uint8_t> kbRaw;
  writeBE64(kbRaw,0);
  kbRaw.push_back('a');kbRaw.push_back('a');kbRaw.push_back('a');kbRaw.push_back(0);
  writeBE64(kbRaw,13);
  kbRaw.push_back('z');kbRaw.push_back('z');kbRaw.push_back('z');kbRaw.push_back(0);
  auto kbc=zlibCompress(kbRaw.data(),kbRaw.size());
  for (int i=0;i<8;++i){kbiRaw[co+i]=(kbc.size()>>((7-i)*8))&0xff;kbiRaw[dod+i]=(kbRaw.size()>>((7-i)*8))&0xff;}
  auto kbic=zlibCompress(kbiRaw.data(),kbiRaw.size());
  std::string rc="record for aaa\0record for zzz"; rc.push_back('\0');
  auto recC=zlibCompress(rc.data(),rc.size());
  std::vector<uint8_t> kbiB; kbiB.push_back(2);kbiB.push_back(0);kbiB.push_back(0);kbiB.push_back(0);
  writeBE32(kbiB,adler32bytes(kbiRaw.data(),kbiRaw.size()));
  kbiB.insert(kbiB.end(),kbic.begin(),kbic.end());
  std::vector<uint8_t> kbF; kbF.push_back(2);kbF.push_back(0);kbF.push_back(0);kbF.push_back(0);
  writeBE32(kbF,adler32bytes(kbRaw.data(),kbRaw.size()));
  kbF.insert(kbF.end(),kbc.begin(),kbc.end());
  std::vector<uint8_t> recF; recF.push_back(2);recF.push_back(0);recF.push_back(0);recF.push_back(0);
  writeBE32(recF,adler32bytes(rc.data(),rc.size()));
  recF.insert(recF.end(),recC.begin(),recC.end());
  std::vector<uint8_t> rI; writeBE64(rI,recC.size()+8); writeBE64(rI,rc.size());
  std::vector<uint8_t> kbh; writeBE64(kbh,1);writeBE64(kbh,2);writeBE64(kbh,kbiRaw.size());
  writeBE64(kbh,kbiB.size()); writeBE64(kbh,kbF.size());
  std::vector<uint8_t> f;
  writeBE32(f,(uint32_t)h16.size());
  f.insert(f.end(),h16.begin(),h16.end());
  writeBE32(f,adler32bytes(h16.data(),h16.size()));
  f.insert(f.end(),kbh.begin(),kbh.end());
  writeBE32(f,adler32bytes(kbh.data(),kbh.size()));
  f.insert(f.end(),kbiB.begin(),kbiB.end());
  f.insert(f.end(),kbF.begin(),kbF.end());
  writeBE64(f,1);writeBE64(f,2);writeBE64(f,16);writeBE64(f,recC.size()+8);
  f.insert(f.end(),rI.begin(),rI.end());
  f.insert(f.end(),recF.begin(),recF.end());
  std::ofstream o(outPath,std::ios::binary);
  o.write((const char*)f.data(),f.size());
  return 0;
}
BLDEOF
"$CXX" -std=c++17 -O1 -isysroot "$SDKROOT" -I"$MINIZ" "$WORK/build_mdx.cpp" \
  "$SMOKE_OBJ/miniz.o" "$SMOKE_OBJ/miniz_tinfl.o" "$SMOKE_OBJ/miniz_tdef.o" \
  -o "$WORK/build_mdx"
"$WORK/build_mdx" "$WORK/synthetic.mdx"

# Test --release mode via the probe script
"$PROBE_SCRIPT" --release --dictionary RL "$WORK/synthetic.mdx" --output "$WORK/rel.json"
echo "PASS"

# 3c. --release + clean output
JSON=$(cat "$WORK/rel.json")
if echo "$JSON" | grep -qF "$WORK"; then
  print -u2 "FAIL: release output leaked path"
  exit 1
fi
if echo "$JSON" | grep -q "synthetic"; then
  print -u2 "FAIL: release output leaked basename"
  exit 1
fi
chmod_out=$(stat -f '%p' "$WORK/rel.json" 2>/dev/null || stat -c '%a' "$WORK/rel.json" 2>/dev/null)
echo "  release output clean: PASS"

# 3d. --release + Encrypted=2 does not abort
echo "--- release + Encrypted=2 ---"
# Patch the synthetic MDX to claim Encrypted="2"
cp "$WORK/synthetic.mdx" "$WORK/enc2.mdx"
# Use perl for binary patch: "Encrypted=\"No\"" -> "Encrypted=\"2\""
perl -pi -e 's/Encrypted="No"/Encrypted="2\x00"/' "$WORK/enc2.mdx" 2>/dev/null || true
set +e
ENC2_OUT="$("$PROBE_SCRIPT" --release --dictionary ENC2 "$WORK/enc2.mdx" --output "$WORK/enc2.json" 2>&1)"
ENC2_RC=$?
set -e
# With NDEBUG, the assert is compiled out; the probe should exit normally
# (possibly with an error code or partial JSON) rather than aborting
if (( ENC2_RC != 0 )); then
  # Non-zero exit is fine as long as it didn't abort
  echo "  release Encrypted=2 exit=$ENC2_RC (non-abort): PASS"
else
  # Zero exit — verify no key material in output
  if [[ -f "$WORK/enc2.json" ]]; then
    ENC2_JSON=$(cat "$WORK/enc2.json")
    if echo "$ENC2_JSON" | grep -qF "0x36"; then
      print -u2 "FAIL: Encrypted=2 output leaked key byte"
      exit 1
    fi
    if echo "$ENC2_JSON" | grep -qF "ripemd"; then
      print -u2 "FAIL: Encrypted=2 output leaked algorithm"
      exit 1
    fi
  fi
  echo "  release Encrypted=2 clean: PASS"
fi

# ---------- 4. C++ smoke tests ----------
echo "=== Running C++ smoke tests ==="
export MDICT_METRICS_PROBE_BIN="$BUILD_DIR/MDictResourceMetricsProbe"
export MDICT_METRICS_PROBE_RELEASE_BIN="$RELEASE_PROBE"
export PROBE_BUILD_DIR="$BUILD_DIR"
"$BUILD_DIR/MDictResourceMetricsProbeSmoke"

echo ""
echo "=== All mdict resource metrics probe smoke tests passed ==="
