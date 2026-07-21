// MDictResourceMetricsProbe – anonymous aggregate resource metrics.
//
// Test-only command-line utility. It is not part of the App target and is
// never shipped. Inputs are read only when explicitly supplied with --mdx or
// --sqlite; the tool neither discovers dictionaries nor reads app state.

#include "mdict.h"

#include <cerrno>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sqlite3.h>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace {

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
  sqliteUnavailable,
  sqliteSchemaInvalid,
  invalidRecordRange,
  internalFailure,
};

const char *errorCodeString(ProbeError error) {
  switch (error) {
    case ProbeError::none: return "none";
    case ProbeError::fileUnavailable: return "fileUnavailable";
    case ProbeError::invalidHeader: return "invalidHeader";
    case ProbeError::unsupportedVersion: return "unsupportedVersion";
    case ProbeError::encryptedMetadataUnsupported: return "encryptedMetadataUnsupported";
    case ProbeError::arithmeticOverflow: return "arithmeticOverflow";
    case ProbeError::offsetOutOfBounds: return "offsetOutOfBounds";
    case ProbeError::malformedMetadata: return "malformedMetadata";
    case ProbeError::unsupportedCompression: return "unsupportedCompression";
    case ProbeError::sqliteUnavailable: return "sqliteUnavailable";
    case ProbeError::sqliteSchemaInvalid: return "sqliteSchemaInvalid";
    case ProbeError::invalidRecordRange: return "invalidRecordRange";
    case ProbeError::internalFailure: return "internalFailure";
  }
  return "internalFailure";
}

struct SafeU64 {
  uint64_t value = 0;
  bool overflow = false;
};

SafeU64 safeAdd(uint64_t lhs, uint64_t rhs) {
  return {lhs > UINT64_MAX - rhs ? 0 : lhs + rhs, lhs > UINT64_MAX - rhs};
}

SafeU64 safeSubtract(uint64_t lhs, uint64_t rhs) {
  return {lhs < rhs ? 0 : lhs - rhs, lhs < rhs};
}

bool isRegularFile(const char *path, uint64_t *size = nullptr) {
  struct stat status {};
  if (stat(path, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < 0) {
    return false;
  }
  if (size) *size = static_cast<uint64_t>(status.st_size);
  return true;
}

int engineVersionMajor(float version) { return static_cast<int>(version); }
int engineVersionMinor(float version) {
  return static_cast<int>((version - static_cast<float>(static_cast<int>(version))) *
                          10.0f + 0.5f);
}

struct JSONWriter {
  std::string buffer;
  bool firstField = true;

  void openObject() { buffer += '{'; firstField = true; }
  void closeObject() { buffer += '}'; }
  void comma() { if (!firstField) buffer += ','; firstField = false; }
  void key(const char *name) { comma(); buffer += '"'; buffer += name; buffer += "\":"; }
  void string(const char *value) { buffer += '"'; buffer += value; buffer += '"'; }
  void u64(uint64_t value) { buffer += std::to_string(value); }
  void i32(int value) { buffer += std::to_string(value); }
  void null() { buffer += "null"; }
  void fieldU64(const char *name, uint64_t value) { key(name); u64(value); }
  void fieldI32(const char *name, int value) { key(name); i32(value); }
  void fieldString(const char *name, const char *value) { key(name); string(value); }
};

struct MdxMetrics {
  uint64_t actualFileBytes = 0;
  uint64_t headerBytes = 0;
  uint64_t keyBlockInfoCompressedBytes = 0;
  uint64_t keyBlockInfoDecompressedBytes = 0;
  uint64_t keyBlockCount = 0;
  uint64_t entryCount = 0;
  uint64_t maximumSingleKeyBlockCompressedBytes = 0;
  uint64_t maximumSingleKeyBlockDecompressedBytes = 0;
  uint64_t totalKeyBlockCompressedBytes = 0;
  uint64_t totalKeyBlockDecompressedBytes = 0;
  uint64_t recordBlockInfoBytes = 0;
  uint64_t recordBlockCount = 0;
  uint64_t maximumSingleRecordBlockCompressedBytes = 0;
  uint64_t maximumSingleRecordBlockDecompressedBytes = 0;
  uint64_t totalRecordBlockCompressedBytes = 0;
  uint64_t totalRecordBlockDecompressedBytes = 0;
  int encryptedMode = 0;
  int engineVersionMajor = 0;
  int engineVersionMinor = 0;
};

struct AggregateMetrics {
  MdxMetrics mdx;
  uint64_t maximumRecordRangeBytes = 0;
};

void maxAssign(uint64_t &destination, uint64_t value) {
  if (value > destination) destination = value;
}

void mergeMdxMetrics(AggregateMetrics &aggregate, const MdxMetrics &input) {
  maxAssign(aggregate.mdx.actualFileBytes, input.actualFileBytes);
  maxAssign(aggregate.mdx.headerBytes, input.headerBytes);
  maxAssign(aggregate.mdx.keyBlockInfoCompressedBytes, input.keyBlockInfoCompressedBytes);
  maxAssign(aggregate.mdx.keyBlockInfoDecompressedBytes, input.keyBlockInfoDecompressedBytes);
  maxAssign(aggregate.mdx.keyBlockCount, input.keyBlockCount);
  maxAssign(aggregate.mdx.entryCount, input.entryCount);
  maxAssign(aggregate.mdx.maximumSingleKeyBlockCompressedBytes, input.maximumSingleKeyBlockCompressedBytes);
  maxAssign(aggregate.mdx.maximumSingleKeyBlockDecompressedBytes, input.maximumSingleKeyBlockDecompressedBytes);
  // Totals keep their pre-M1 meaning: the maximum total within one input,
  // never a sum across separately supplied dictionaries.
  maxAssign(aggregate.mdx.totalKeyBlockCompressedBytes, input.totalKeyBlockCompressedBytes);
  maxAssign(aggregate.mdx.totalKeyBlockDecompressedBytes, input.totalKeyBlockDecompressedBytes);
  maxAssign(aggregate.mdx.recordBlockInfoBytes, input.recordBlockInfoBytes);
  maxAssign(aggregate.mdx.recordBlockCount, input.recordBlockCount);
  maxAssign(aggregate.mdx.maximumSingleRecordBlockCompressedBytes, input.maximumSingleRecordBlockCompressedBytes);
  maxAssign(aggregate.mdx.maximumSingleRecordBlockDecompressedBytes, input.maximumSingleRecordBlockDecompressedBytes);
  maxAssign(aggregate.mdx.totalRecordBlockCompressedBytes, input.totalRecordBlockCompressedBytes);
  maxAssign(aggregate.mdx.totalRecordBlockDecompressedBytes, input.totalRecordBlockDecompressedBytes);
  if (input.encryptedMode > aggregate.mdx.encryptedMode)
    aggregate.mdx.encryptedMode = input.encryptedMode;
  if (input.engineVersionMajor > aggregate.mdx.engineVersionMajor)
    aggregate.mdx.engineVersionMajor = input.engineVersionMajor;
  if (input.engineVersionMinor > aggregate.mdx.engineVersionMinor)
    aggregate.mdx.engineVersionMinor = input.engineVersionMinor;
}

ProbeError collectMdxMetrics(const char *path, MdxMetrics &metrics) {
  if (!isRegularFile(path, &metrics.actualFileBytes)) return ProbeError::fileUnavailable;
  if (metrics.actualFileBytes < 12) return ProbeError::malformedMetadata;

  {
    std::ifstream precheck(path, std::ios::binary);
    if (!precheck) return ProbeError::fileUnavailable;
    unsigned char sizeBytes[4];
    precheck.read(reinterpret_cast<char *>(sizeBytes), 4);
    if (!precheck || precheck.gcount() != 4) return ProbeError::malformedMetadata;
    const uint32_t declared = (uint32_t(sizeBytes[0]) << 24) |
                              (uint32_t(sizeBytes[1]) << 16) |
                              (uint32_t(sizeBytes[2]) << 8) |
                              uint32_t(sizeBytes[3]);
    const SafeU64 headerEnd = safeAdd(static_cast<uint64_t>(declared), 8);
    if (headerEnd.overflow || headerEnd.value > metrics.actualFileBytes) {
      return ProbeError::offsetOutOfBounds;
    }
  }

  mdict::Mdict dictionary(path);
  try {
    dictionary.initMetadataOnly();
  } catch (const std::exception &) {
    return dictionary.engineVersion() < 2.0f ? ProbeError::unsupportedVersion
                                             : ProbeError::invalidHeader;
  }

  metrics.headerBytes = dictionary.headerBytesSize();
  metrics.keyBlockInfoCompressedBytes = dictionary.keyBlockInfoCompressedSize();
  metrics.keyBlockInfoDecompressedBytes = dictionary.keyBlockInfoDecompressedSize();
  metrics.keyBlockCount = dictionary.keyBlockCount();
  metrics.entryCount = dictionary.entryCount();
  metrics.totalKeyBlockCompressedBytes = dictionary.keyBlockCompressedSize();
  metrics.recordBlockInfoBytes = dictionary.recordBlockHeaderSizeValue();
  metrics.recordBlockCount = dictionary.recordBlockCount();
  metrics.totalRecordBlockCompressedBytes = dictionary.recordBlockCompressedSize();
  metrics.encryptedMode = dictionary.encryptionMode();
  metrics.engineVersionMajor = engineVersionMajor(dictionary.engineVersion());
  metrics.engineVersionMinor = engineVersionMinor(dictionary.engineVersion());

  for (const auto *block : dictionary.keyBlockInfoList()) {
    const SafeU64 total = safeAdd(metrics.totalKeyBlockDecompressedBytes,
                                  block->key_block_decomp_size);
    if (total.overflow) return ProbeError::arithmeticOverflow;
    metrics.totalKeyBlockDecompressedBytes = total.value;
    maxAssign(metrics.maximumSingleKeyBlockCompressedBytes, block->key_block_comp_size);
    maxAssign(metrics.maximumSingleKeyBlockDecompressedBytes, block->key_block_decomp_size);
  }
  for (const auto *block : dictionary.recordHeaderList()) {
    const SafeU64 total = safeAdd(metrics.totalRecordBlockDecompressedBytes,
                                  block->decompressed_size);
    if (total.overflow) return ProbeError::arithmeticOverflow;
    metrics.totalRecordBlockDecompressedBytes = total.value;
    maxAssign(metrics.maximumSingleRecordBlockCompressedBytes, block->compressed_size);
    maxAssign(metrics.maximumSingleRecordBlockDecompressedBytes, block->decompressed_size);
  }
  return ProbeError::none;
}

ProbeError collectMaximumRecordRange(const char *path, uint64_t &maximumRange) {
  if (!isRegularFile(path)) return ProbeError::fileUnavailable;

  sqlite3 *database = nullptr;
  if (sqlite3_open_v2(path, &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                      nullptr) != SQLITE_OK) {
    if (database) sqlite3_close(database);
    return ProbeError::sqliteUnavailable;
  }

  auto closeDatabase = [&database]() { sqlite3_close(database); };
  char *message = nullptr;
  if (sqlite3_exec(database, "PRAGMA query_only=ON", nullptr, nullptr, &message) != SQLITE_OK) {
    sqlite3_free(message);
    closeDatabase();
    return ProbeError::sqliteUnavailable;
  }
  sqlite3_free(message);

  sqlite3_stmt *schema = nullptr;
  if (sqlite3_prepare_v2(database,
                         "SELECT 1 FROM sqlite_schema WHERE type='table' AND name='entries'",
                         -1, &schema, nullptr) != SQLITE_OK) {
    closeDatabase();
    return ProbeError::sqliteSchemaInvalid;
  }
  const bool hasEntriesTable = sqlite3_step(schema) == SQLITE_ROW;
  sqlite3_finalize(schema);
  if (!hasEntriesTable) {
    closeDatabase();
    return ProbeError::sqliteSchemaInvalid;
  }

  sqlite3_stmt *statement = nullptr;
  if (sqlite3_prepare_v2(database,
                         "SELECT record_start, record_end FROM entries",
                         -1, &statement, nullptr) != SQLITE_OK) {
    closeDatabase();
    return ProbeError::sqliteSchemaInvalid;
  }

  ProbeError outcome = ProbeError::none;
  for (;;) {
    const int step = sqlite3_step(statement);
    if (step == SQLITE_DONE) break;
    if (step != SQLITE_ROW) {
      outcome = ProbeError::sqliteUnavailable;
      break;
    }
    if (sqlite3_column_type(statement, 0) != SQLITE_INTEGER ||
        sqlite3_column_type(statement, 1) != SQLITE_INTEGER) {
      outcome = ProbeError::invalidRecordRange;
      break;
    }
    const sqlite3_int64 startSigned = sqlite3_column_int64(statement, 0);
    const sqlite3_int64 endSigned = sqlite3_column_int64(statement, 1);
    if (startSigned < 0 || endSigned < 0) {
      outcome = ProbeError::invalidRecordRange;
      break;
    }
    const uint64_t start = static_cast<uint64_t>(startSigned);
    const uint64_t end = static_cast<uint64_t>(endSigned);
    const SafeU64 range = safeSubtract(end, start);
    if (range.overflow) {
      outcome = ProbeError::invalidRecordRange;
      break;
    }
    maxAssign(maximumRange, range.value);
  }
  sqlite3_finalize(statement);
  closeDatabase();
  return outcome;
}

void writeAggregateJSON(JSONWriter &writer, const AggregateMetrics &aggregate) {
  writer.openObject();
  writer.fieldI32("schemaVersion", 2);
  writer.fieldString("generatedBy", "MDictResourceMetricsProbe-D1b-3A-2B-M1");
  writer.fieldU64("actualFileBytes", aggregate.mdx.actualFileBytes);
  writer.fieldU64("headerBytes", aggregate.mdx.headerBytes);
  writer.fieldU64("keyBlockInfoCompressedBytes", aggregate.mdx.keyBlockInfoCompressedBytes);
  writer.fieldU64("keyBlockInfoDecompressedBytes", aggregate.mdx.keyBlockInfoDecompressedBytes);
  writer.fieldU64("keyBlockCount", aggregate.mdx.keyBlockCount);
  writer.fieldU64("entryCount", aggregate.mdx.entryCount);
  writer.fieldU64("maximumSingleKeyBlockCompressedBytes", aggregate.mdx.maximumSingleKeyBlockCompressedBytes);
  writer.fieldU64("maximumSingleKeyBlockDecompressedBytes", aggregate.mdx.maximumSingleKeyBlockDecompressedBytes);
  writer.fieldU64("totalKeyBlockCompressedBytes", aggregate.mdx.totalKeyBlockCompressedBytes);
  writer.fieldU64("totalKeyBlockDecompressedBytes", aggregate.mdx.totalKeyBlockDecompressedBytes);
  // The legacy metadata-only field remains unavailable. The new field below is
  // derived only from explicitly supplied SQLite entries ranges.
  writer.key("maximumSingleKeyBytes"); writer.null();
  writer.key("maximumObservedRecordRangeBytes"); writer.null();
  writer.fieldU64("recordBlockInfoBytes", aggregate.mdx.recordBlockInfoBytes);
  writer.fieldU64("recordBlockCount", aggregate.mdx.recordBlockCount);
  writer.fieldU64("maximumSingleRecordBlockCompressedBytes", aggregate.mdx.maximumSingleRecordBlockCompressedBytes);
  writer.fieldU64("maximumSingleRecordBlockDecompressedBytes", aggregate.mdx.maximumSingleRecordBlockDecompressedBytes);
  writer.fieldU64("totalRecordBlockCompressedBytes", aggregate.mdx.totalRecordBlockCompressedBytes);
  writer.fieldU64("totalRecordBlockDecompressedBytes", aggregate.mdx.totalRecordBlockDecompressedBytes);
  writer.fieldU64("maximumRecordRangeBytes", aggregate.maximumRecordRangeBytes);
  writer.fieldI32("encryptedMode", aggregate.mdx.encryptedMode);
  writer.fieldI32("engineVersionMajor", aggregate.mdx.engineVersionMajor);
  writer.fieldI32("engineVersionMinor", aggregate.mdx.engineVersionMinor);
  writer.key("unavailable");
  writer.buffer += "[\"maximumSingleKeyBytes\",\"maximumObservedRecordRangeBytes\"]";
  writer.closeObject();
}

void printUsage(const char *program) {
  std::fprintf(stderr,
      "Usage: %s (--mdx <path> | --sqlite <path>)... --output <output.json> [--force]\n"
      "\n"
      "  --mdx path       Explicit MDX metadata input; may be repeated.\n"
      "  --sqlite path    Explicit read-only SQLite range input; may be repeated.\n"
      "  --output path    Write anonymous aggregate JSON (0600).\n"
      "  --force          Overwrite an existing output file.\n"
      "\n"
      "The tool never scans for dictionaries, reads application state, or emits\n"
      "input paths, names, headwords, record content, hashes, or row values.\n",
      program);
}

enum class InputKind { mdx, sqlite };
struct Input {
  InputKind kind;
  std::string path;
  size_t ordinal = 0;
};

void printInputFailure(InputKind kind, size_t ordinal, ProbeError error) {
  std::fprintf(stderr, "Error: %s input #%zu failed: %s\n",
               kind == InputKind::mdx ? "MDX" : "SQLite", ordinal,
               errorCodeString(error));
}

}  // namespace

int main(int argc, char **argv) {
  std::vector<Input> inputs;
  const char *outputPath = nullptr;
  bool force = false;
  size_t mdxOrdinal = 0;
  size_t sqliteOrdinal = 0;

  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--mdx") == 0 ||
        std::strcmp(argv[index], "--sqlite") == 0) {
      if (index + 1 >= argc) { printUsage(argv[0]); return 2; }
      const InputKind kind = std::strcmp(argv[index], "--mdx") == 0
          ? InputKind::mdx : InputKind::sqlite;
      inputs.push_back({kind, argv[++index],
                        kind == InputKind::mdx ? ++mdxOrdinal : ++sqliteOrdinal});
    } else if (std::strcmp(argv[index], "--output") == 0) {
      if (index + 1 >= argc) { printUsage(argv[0]); return 2; }
      outputPath = argv[++index];
    } else if (std::strcmp(argv[index], "--force") == 0) {
      force = true;
    } else if (std::strcmp(argv[index], "--help") == 0 ||
               std::strcmp(argv[index], "-h") == 0) {
      printUsage(argv[0]);
      return 0;
    } else {
      std::fprintf(stderr, "Error: invalid command-line arguments.\n");
      return 2;
    }
  }

  if (inputs.empty() || !outputPath) {
    std::fprintf(stderr, "Error: explicit input and output are required.\n");
    return 2;
  }
  struct stat existingOutput {};
  if (stat(outputPath, &existingOutput) == 0 && !force) {
    std::fprintf(stderr, "Error: output already exists; use --force to replace it.\n");
    return 1;
  }

  AggregateMetrics aggregate;
  for (const Input &input : inputs) {
    if (input.kind == InputKind::mdx) {
      MdxMetrics metrics;
      const ProbeError error = collectMdxMetrics(input.path.c_str(), metrics);
      if (error != ProbeError::none) {
        printInputFailure(input.kind, input.ordinal, error);
        return 1;
      }
      mergeMdxMetrics(aggregate, metrics);
    } else {
      uint64_t maximumRange = 0;
      const ProbeError error = collectMaximumRecordRange(input.path.c_str(), maximumRange);
      if (error != ProbeError::none) {
        printInputFailure(input.kind, input.ordinal, error);
        return 1;
      }
      maxAssign(aggregate.maximumRecordRangeBytes, maximumRange);
    }
  }

  JSONWriter writer;
  writeAggregateJSON(writer, aggregate);
  std::ofstream output(outputPath, std::ios::binary | std::ios::trunc);
  if (!output) {
    std::fprintf(stderr, "Error: cannot open output.\n");
    return 1;
  }
  output << writer.buffer;
  if (!output.good()) {
    std::fprintf(stderr, "Error: output write failed.\n");
    return 1;
  }
  output.close();
  if (chmod(outputPath, S_IRUSR | S_IWUSR) != 0) {
    std::fprintf(stderr, "Error: could not set output permissions.\n");
    return 1;
  }
  return 0;
}
