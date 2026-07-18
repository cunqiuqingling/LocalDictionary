// MDictResourceMetricsProbe – anonymous resource metrics for MDX files.
//
// This is a test-only command-line tool.  It is NOT part of the App target
// and MUST NOT be shipped in the application bundle.
//
// It reads only metadata (initMetadataOnly) — no record content, no key
// materialisation, no SQLite index, no formatter, no network access.

#include "mdict.h"

#include <cerrno>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <vector>

// ---------------------------------------------------------------------------
// Error codes — closed enum for the JSON "errorCode" field.
// ---------------------------------------------------------------------------
enum class ProbeError {
  none = 0,
  fileUnavailable,
  invalidHeader,
  unsupportedVersion,
  encryptedMetadataUnsupported,
  arithmeticOverflow,
  offsetOutOfBounds,
  malformedMetadata,
  unsupportedCompression,
  internalFailure,
};

static const char *errorCodeString(ProbeError e) {
  switch (e) {
  case ProbeError::none: return nullptr;
  case ProbeError::fileUnavailable: return "fileUnavailable";
  case ProbeError::invalidHeader: return "invalidHeader";
  case ProbeError::unsupportedVersion: return "unsupportedVersion";
  case ProbeError::encryptedMetadataUnsupported: return "encryptedMetadataUnsupported";
  case ProbeError::arithmeticOverflow: return "arithmeticOverflow";
  case ProbeError::offsetOutOfBounds: return "offsetOutOfBounds";
  case ProbeError::malformedMetadata: return "malformedMetadata";
  case ProbeError::unsupportedCompression: return "unsupportedCompression";
  case ProbeError::internalFailure: return "internalFailure";
  }
  return "internalFailure";
}

// ---------------------------------------------------------------------------
// Overflow-safe helpers
// ---------------------------------------------------------------------------
struct SafeU64 {
  uint64_t value = 0;
  bool overflow = false;
};

static SafeU64 safeAdd(uint64_t a, uint64_t b) {
  SafeU64 r;
  r.overflow = (a > UINT64_MAX - b);
  r.value = r.overflow ? 0 : a + b;
  return r;
}

static SafeU64 safeMax(uint64_t a, uint64_t b) {
  return {a > b ? a : b, false};
}

// ---------------------------------------------------------------------------
// File-size helper (stat)
// ---------------------------------------------------------------------------
static bool fileSizeBytes(const char *path, uint64_t &out) {
  struct stat st;
  if (stat(path, &st) != 0) return false;
  if (st.st_size < 0) return false;
  out = static_cast<uint64_t>(st.st_size);
  return true;
}

// ---------------------------------------------------------------------------
// Engine-version helpers
// ---------------------------------------------------------------------------
static int engineVersionMajor(float v) { return static_cast<int>(v); }
static int engineVersionMinor(float v) {
  return static_cast<int>((v - static_cast<float>(static_cast<int>(v))) * 10.0f + 0.5f);
}

// ---------------------------------------------------------------------------
// Simple JSON builder (no library dependency)
// ---------------------------------------------------------------------------
struct JSONWriter {
  std::string buf;
  bool first_field = true;
  bool in_object = false;

  void openObject() {
    buf += '{';
    first_field = true;
    in_object = true;
  }
  void closeObject() { buf += '}'; in_object = false; }
  void openArray() { buf += '['; first_field = true; }
  void closeArray() { buf += ']'; }

  void comma() { if (!first_field) buf += ','; first_field = false; }

  void key(const char *k) { comma(); buf += '"'; buf += k; buf += "\":"; }

  void str(const char *s) { buf += '"'; buf += s; buf += '"'; }
  void u64(uint64_t v) { buf += std::to_string(v); }
  void i64(int64_t v) { buf += std::to_string(v); }
  void i32(int v) { buf += std::to_string(v); }
  void boolean(bool v) { buf += v ? "true" : "false"; }
  void null() { buf += "null"; }

  void fieldStr(const char *k, const char *v) { key(k); str(v); }
  void fieldU64(const char *k, uint64_t v) { key(k); u64(v); }
  void fieldI32(const char *k, int v) { key(k); i32(v); }

  void startUnavailableArray(const char *k) {
    key(k);
    buf += '[';
    first_field = true;
  }
  void addUnavailable(const char *reason) {
    if (!first_field) buf += ',';
    first_field = false;
    buf += '"'; buf += reason; buf += '"';
  }
  void endUnavailableArray() { buf += ']'; }
};

// ---------------------------------------------------------------------------
// Per-dictionary metrics
// ---------------------------------------------------------------------------
struct DictMetrics {
  std::string anonymousID;
  ProbeError error = ProbeError::none;

  // populated when no error
  uint64_t actualFileBytes = 0;
  uint64_t headerBytes = 0;
  uint64_t keyBlockInfoCompressedBytes = 0;
  uint64_t keyBlockInfoDecompressedBytes = 0;
  uint64_t keyBlockCount = 0;
  uint64_t entryCount = 0;
  uint64_t maxSingleKeyBlockCompressed = 0;
  uint64_t maxSingleKeyBlockDecompressed = 0;
  uint64_t totalKeyBlockCompressed = 0;
  uint64_t totalKeyBlockDecompressed = 0;
  // maximumSingleKeyBytes – unavailable without full key-block parse
  uint64_t recordBlockInfoBytes = 0;
  uint64_t recordBlockCount = 0;
  uint64_t maxSingleRecordBlockCompressed = 0;
  uint64_t maxSingleRecordBlockDecompressed = 0;
  uint64_t totalRecordBlockCompressed = 0;
  uint64_t totalRecordBlockDecompressed = 0;
  // maximumObservedRecordRangeBytes – unavailable without entry-level parse
  int encryptedMode = 0;
  int engineVersionMajor_ = 0;
  int engineVersionMinor_ = 0;

  // list of unavailable field names
  std::vector<const char *> unavailable;
};

// ---------------------------------------------------------------------------
// Core metrics collector
// ---------------------------------------------------------------------------
static DictMetrics collectMetrics(const char *anonymousID, const char *path) {
  DictMetrics m;
  m.anonymousID = anonymousID;

  // 1. file size
  if (!fileSizeBytes(path, m.actualFileBytes)) {
    m.error = ProbeError::fileUnavailable;
    return m;
  }

  // 2. init metadata-only
  mdict::Mdict dict(path);
  try {
    dict.initMetadataOnly();
  } catch (const std::exception &) {
    // Try to classify the error
    if (dict.engineVersion() < 2.0f) {
      m.error = ProbeError::unsupportedVersion;
      return m;
    }
    m.error = ProbeError::invalidHeader;
    return m;
  }

  // 3. Encrypted=2 support check
  if (dict.encryptionMode() == 2 /* ENCRYPT_KEY_INFO_ENC */) {
    // Encrypted=2 goes through decrypt path in decode_key_block_info.
    // That path is exercised by initMetadataOnly and should have succeeded
    // if we got here.  We report the mode but do not expose key material.
  }

  // 4. Basic scalars
  m.headerBytes = dict.headerBytesSize();
  m.keyBlockInfoCompressedBytes = dict.keyBlockInfoCompressedSize();
  m.keyBlockInfoDecompressedBytes = dict.keyBlockInfoDecompressedSize();
  m.keyBlockCount = dict.keyBlockCount();
  m.entryCount = dict.entryCount();
  m.totalKeyBlockCompressed = dict.keyBlockCompressedSize();
  m.recordBlockInfoBytes = dict.recordBlockHeaderSizeValue();
  m.recordBlockCount = dict.recordBlockCount();
  m.totalRecordBlockCompressed = dict.recordBlockCompressedSize();
  m.encryptedMode = dict.encryptionMode();
  float ver = dict.engineVersion();
  m.engineVersionMajor_ = engineVersionMajor(ver);
  m.engineVersionMinor_ = engineVersionMinor(ver);

  // 5. Key-block per-item max & total decompressed
  {
    const auto &kbl = dict.keyBlockInfoList();
    uint64_t kb_decomp_total = 0;
    uint64_t kb_comp_max = 0;
    uint64_t kb_decomp_max = 0;
    bool kb_overflow = false;
    for (const auto *kb : kbl) {
      auto s1 = safeAdd(kb_decomp_total, kb->key_block_decomp_size);
      if (s1.overflow) { kb_overflow = true; break; }
      kb_decomp_total = s1.value;

      auto mx_c = safeMax(kb_comp_max, kb->key_block_comp_size);
      auto mx_d = safeMax(kb_decomp_max, kb->key_block_decomp_size);
      kb_comp_max = mx_c.value;
      kb_decomp_max = mx_d.value;
    }
    if (kb_overflow) {
      m.error = ProbeError::arithmeticOverflow;
      return m;
    }
    m.maxSingleKeyBlockCompressed = kb_comp_max;
    m.maxSingleKeyBlockDecompressed = kb_decomp_max;
    m.totalKeyBlockDecompressed = kb_decomp_total;

    // Cross-validate: total compressed from header should match sum of per-block
    // (key_block_size is the total compressed size from the file header)
  }

  // 6. Record-block per-item max & total decompressed
  {
    const auto &rh = dict.recordHeaderList();
    uint64_t rb_decomp_total = 0;
    uint64_t rb_comp_max = 0;
    uint64_t rb_decomp_max = 0;
    bool rb_overflow = false;
    for (const auto *r : rh) {
      auto s1 = safeAdd(rb_decomp_total, r->decompressed_size);
      if (s1.overflow) { rb_overflow = true; break; }
      rb_decomp_total = s1.value;

      auto mx_c = safeMax(rb_comp_max, r->compressed_size);
      auto mx_d = safeMax(rb_decomp_max, r->decompressed_size);
      rb_comp_max = mx_c.value;
      rb_decomp_max = mx_d.value;
    }
    if (rb_overflow) {
      m.error = ProbeError::arithmeticOverflow;
      return m;
    }
    m.maxSingleRecordBlockCompressed = rb_comp_max;
    m.maxSingleRecordBlockDecompressed = rb_decomp_max;
    m.totalRecordBlockDecompressed = rb_decomp_total;
  }

  // 7. Mark unavailable fields
  m.unavailable.push_back("maximumSingleKeyBytes");
  m.unavailable.push_back("maximumObservedRecordRangeBytes");

  return m;
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------
static void writeDictJSON(JSONWriter &w, const DictMetrics &m) {
  w.openObject();
  w.fieldStr("anonymousID", m.anonymousID.c_str());

  if (m.error != ProbeError::none) {
    w.fieldStr("errorCode", errorCodeString(m.error));
    w.closeObject();
    return;
  }

  w.fieldU64("actualFileBytes", m.actualFileBytes);
  w.fieldU64("headerBytes", m.headerBytes);
  w.fieldU64("keyBlockInfoCompressedBytes", m.keyBlockInfoCompressedBytes);
  w.fieldU64("keyBlockInfoDecompressedBytes", m.keyBlockInfoDecompressedBytes);
  w.fieldU64("keyBlockCount", m.keyBlockCount);
  w.fieldU64("entryCount", m.entryCount);
  w.fieldU64("maximumSingleKeyBlockCompressedBytes", m.maxSingleKeyBlockCompressed);
  w.fieldU64("maximumSingleKeyBlockDecompressedBytes", m.maxSingleKeyBlockDecompressed);
  w.fieldU64("totalKeyBlockCompressedBytes", m.totalKeyBlockCompressed);
  w.fieldU64("totalKeyBlockDecompressedBytes", m.totalKeyBlockDecompressed);

  if (!m.unavailable.empty()) {
    w.startUnavailableArray("maximumSingleKeyBytes");
    for (const auto *reason : m.unavailable) {
      if (std::strcmp(reason, "maximumSingleKeyBytes") == 0 ||
          std::strcmp(reason, "maximumObservedRecordRangeBytes") == 0) {
        w.addUnavailable(reason);
      }
    }
    w.endUnavailableArray();
  }

  w.fieldU64("recordBlockInfoBytes", m.recordBlockInfoBytes);
  w.fieldU64("recordBlockCount", m.recordBlockCount);
  w.fieldU64("maximumSingleRecordBlockCompressedBytes", m.maxSingleRecordBlockCompressed);
  w.fieldU64("maximumSingleRecordBlockDecompressedBytes", m.maxSingleRecordBlockDecompressed);
  w.fieldU64("totalRecordBlockCompressedBytes", m.totalRecordBlockCompressed);
  w.fieldU64("totalRecordBlockDecompressedBytes", m.totalRecordBlockDecompressed);

  if (!m.unavailable.empty()) {
    w.startUnavailableArray("maximumObservedRecordRangeBytes");
    for (const auto *reason : m.unavailable) {
      if (std::strcmp(reason, "maximumObservedRecordRangeBytes") == 0) {
        w.addUnavailable(reason);
      }
    }
    w.endUnavailableArray();
  }

  w.fieldI32("encryptedMode", m.encryptedMode);
  w.fieldI32("engineVersionMajor", m.engineVersionMajor_);
  w.fieldI32("engineVersionMinor", m.engineVersionMinor_);

  w.closeObject();
}

// ---------------------------------------------------------------------------
// Argument parser
// ---------------------------------------------------------------------------
struct ArgDict {
  std::string id;
  std::string path;
};

static void printUsage(const char *prog) {
  std::fprintf(stderr,
    "Usage: %s --dictionary <ID> <path> [--dictionary <ID> <path> ...] \\\n"
    "       --output <output.json> [--force]\n"
    "\n"
    "  --dictionary ID path   Associate an anonymous ID with an MDX file.\n"
    "                         May be repeated.\n"
    "  --output path          Write JSON metrics to this file (0600).\n"
    "  --force                Overwrite existing output file.\n"
    "\n"
    "The tool reads only MDX metadata. It never reads record content,\n"
    "key text, or header XML — and it never creates an SQLite index.\n",
    prog);
}

int main(int argc, char **argv) {
  std::vector<ArgDict> dictionaries;
  const char *outputPath = nullptr;
  bool force = false;

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--dictionary") == 0) {
      if (i + 2 >= argc) { printUsage(argv[0]); return 1; }
      ArgDict ad;
      ad.id = argv[++i];
      ad.path = argv[++i];
      dictionaries.push_back(std::move(ad));
    } else if (std::strcmp(argv[i], "--output") == 0) {
      if (i + 1 >= argc) { printUsage(argv[0]); return 1; }
      outputPath = argv[++i];
    } else if (std::strcmp(argv[i], "--force") == 0) {
      force = true;
    } else if (std::strcmp(argv[i], "--help") == 0 ||
               std::strcmp(argv[i], "-h") == 0) {
      printUsage(argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "Unknown argument: %s\n", argv[i]);
      printUsage(argv[0]);
      return 1;
    }
  }

  if (dictionaries.empty()) {
    std::fprintf(stderr, "Error: at least one --dictionary is required.\n");
    return 1;
  }
  if (!outputPath) {
    std::fprintf(stderr, "Error: --output is required.\n");
    return 1;
  }

  // Check output file — do not overwrite without --force
  {
    struct stat st;
    if (stat(outputPath, &st) == 0 && !force) {
      std::fprintf(stderr,
        "Error: output file already exists. Use --force to overwrite.\n");
      return 1;
    }
  }

  // Collect metrics
  std::vector<DictMetrics> results;
  for (const auto &ad : dictionaries) {
    results.push_back(collectMetrics(ad.id.c_str(), ad.path.c_str()));
  }

  // Build JSON
  JSONWriter w;
  w.openObject();
  w.fieldI32("schemaVersion", 1);
  w.fieldStr("generatedBy", "MDictResourceMetricsProbe-D1b-3A-1");
  w.key("dictionaries");
  w.openArray();
  for (size_t i = 0; i < results.size(); ++i) {
    if (i > 0) { w.comma(); w.first_field = false; }
    writeDictJSON(w, results[i]);
  }
  w.closeArray();
  w.closeObject();

  // Write output
  {
    std::ofstream out(outputPath, std::ios::binary | std::ios::trunc);
    if (!out) {
      std::fprintf(stderr, "Error: cannot write to %s\n", outputPath);
      return 1;
    }
    out << w.buf;
    if (!out.good()) {
      std::fprintf(stderr, "Error: write failed for %s\n", outputPath);
      return 1;
    }
    out.close();
  }

  // Set permissions 0600
  if (chmod(outputPath, S_IRUSR | S_IWUSR) != 0) {
    std::fprintf(stderr, "Warning: could not set 0600 permissions on %s\n",
                 outputPath);
  }

  return 0;
}
