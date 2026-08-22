// MDictResourceMetricsProbe – anonymous aggregate resource metrics.
//
// Test-only command-line utility. It is not part of the App target and is
// never shipped. Inputs are read only when explicitly supplied with --mdx or
// --sqlite; the tool neither discovers dictionaries nor reads app state.

#include "mdict.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <sqlite3.h>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "miniz.h"

namespace {

constexpr uint64_t kMaximumHeaderBytes = UINT64_C(16) * 1024 * 1024;
constexpr uint64_t kMaximumRecordMetadataBytes = UINT64_C(64) * 1024 * 1024;

enum class ProbeError {
  none = 0,
  fileUnavailable,
  invalidHeader,
  checksumMismatch,
  malformedVersion,
  malformedEncryptedMode,
  headerTooLarge,
  recordMetadataTooLarge,
  arithmeticOverflow,
  truncatedFile,
  malformedRecordMetadata,
  sqliteUnavailable,
  sqliteSchemaInvalid,
  invalidRecordRange,
  internalFailure,
};

// Fixed, anonymous checksum diagnostics. These values describe only which
// bounded verification path stopped; they intentionally carry no checksum,
// path, Header, or input identity data.
enum class ChecksumFailureStage { none, header, keyInfo, keyBlock, recordBlock };
enum class ChecksumStatus { valid, mismatch, notReached, notChecked, notApplicable };
enum class HeaderChecksumEncodingMatch {
  canonicalLittleEndian,
  byteReversedBigEndian,
  neither,
  notChecked,
};

const char *checksumFailureStageString(ChecksumFailureStage value) {
  switch (value) {
    case ChecksumFailureStage::none: return "none";
    case ChecksumFailureStage::header: return "header";
    case ChecksumFailureStage::keyInfo: return "keyInfo";
    case ChecksumFailureStage::keyBlock: return "keyBlock";
    case ChecksumFailureStage::recordBlock: return "recordBlock";
  }
  return "none";
}

const char *checksumStatusString(ChecksumStatus value) {
  switch (value) {
    case ChecksumStatus::valid: return "valid";
    case ChecksumStatus::mismatch: return "mismatch";
    case ChecksumStatus::notReached: return "notReached";
    case ChecksumStatus::notChecked: return "notChecked";
    case ChecksumStatus::notApplicable: return "notApplicable";
  }
  return "notChecked";
}

const char *headerChecksumEncodingMatchString(HeaderChecksumEncodingMatch value) {
  switch (value) {
    case HeaderChecksumEncodingMatch::canonicalLittleEndian: return "canonicalLittleEndian";
    case HeaderChecksumEncodingMatch::byteReversedBigEndian: return "byteReversedBigEndian";
    case HeaderChecksumEncodingMatch::neither: return "neither";
    case HeaderChecksumEncodingMatch::notChecked: return "notChecked";
  }
  return "notChecked";
}

struct ChecksumDiagnostics {
  ChecksumFailureStage failureStage = ChecksumFailureStage::none;
  ChecksumStatus header = ChecksumStatus::notChecked;
  ChecksumStatus keyInfo = ChecksumStatus::notChecked;
  ChecksumStatus keyBlock = ChecksumStatus::notChecked;
  ChecksumStatus recordBlock = ChecksumStatus::notChecked;
  HeaderChecksumEncodingMatch headerEncoding = HeaderChecksumEncodingMatch::notChecked;
};

const char *errorCodeString(ProbeError error) {
  switch (error) {
    case ProbeError::none: return "none";
    case ProbeError::fileUnavailable: return "fileUnavailable";
    case ProbeError::invalidHeader: return "invalidHeader";
    case ProbeError::checksumMismatch: return "checksumMismatch";
    case ProbeError::malformedVersion: return "malformedVersion";
    case ProbeError::malformedEncryptedMode: return "malformedEncryptedMode";
    case ProbeError::headerTooLarge: return "headerTooLarge";
    case ProbeError::recordMetadataTooLarge: return "recordMetadataTooLarge";
    case ProbeError::arithmeticOverflow: return "arithmeticOverflow";
    case ProbeError::truncatedFile: return "truncatedFile";
    case ProbeError::malformedRecordMetadata: return "malformedRecordMetadata";
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

SafeU64 safeMultiply(uint64_t lhs, uint64_t rhs) {
  return {lhs != 0 && rhs > UINT64_MAX / lhs ? 0 : lhs * rhs,
          lhs != 0 && rhs > UINT64_MAX / lhs};
}

bool isRegularFile(const char *path, uint64_t *size = nullptr) {
  struct stat status {};
  if (stat(path, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < 0) {
    return false;
  }
  if (size) *size = static_cast<uint64_t>(status.st_size);
  return true;
}

uint32_t readBE32(const uint8_t *bytes) {
  return (uint32_t(bytes[0]) << 24) | (uint32_t(bytes[1]) << 16) |
         (uint32_t(bytes[2]) << 8) | uint32_t(bytes[3]);
}

uint32_t readLE32(const uint8_t *bytes) {
  return uint32_t(bytes[0]) | (uint32_t(bytes[1]) << 8) |
         (uint32_t(bytes[2]) << 16) | (uint32_t(bytes[3]) << 24);
}

uint32_t byteReverse32(uint32_t value) {
  return ((value & UINT32_C(0x000000ff)) << 24) |
         ((value & UINT32_C(0x0000ff00)) << 8) |
         ((value & UINT32_C(0x00ff0000)) >> 8) |
         ((value & UINT32_C(0xff000000)) >> 24);
}

uint64_t readBE64(const uint8_t *bytes) {
  uint64_t value = 0;
  for (size_t index = 0; index < 8; ++index) value = (value << 8) | bytes[index];
  return value;
}

uint64_t readNumber(const uint8_t *bytes, uint64_t width) {
  return width == 4 ? readBE32(bytes) : readBE64(bytes);
}

bool readExact(std::ifstream &input, uint64_t fileBytes, uint64_t offset,
               uint8_t *destination, size_t count) {
  const SafeU64 end = safeAdd(offset, static_cast<uint64_t>(count));
  if (end.overflow || end.value > fileBytes ||
      offset > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())) {
    return false;
  }
  input.clear();
  input.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
  if (!input) return false;
  input.read(reinterpret_cast<char *>(destination), static_cast<std::streamsize>(count));
  return input.good() && static_cast<size_t>(input.gcount()) == count;
}

bool decodeHeaderASCII(const std::vector<uint8_t> &bytes, std::string &output) {
  if (bytes.size() < 2 || bytes.size() % 2 != 0) return false;
  size_t offset = 0;
  bool littleEndian = false;
  if (bytes[0] == 0xff && bytes[1] == 0xfe) {
    littleEndian = true;
    offset = 2;
  } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
    littleEndian = false;
    offset = 2;
  } else if (bytes[1] == 0) {
    littleEndian = true;
  } else if (bytes[0] == 0) {
    littleEndian = false;
  } else {
    return false;
  }
  output.clear();
  output.reserve((bytes.size() - offset) / 2);
  for (; offset < bytes.size(); offset += 2) {
    const uint8_t low = littleEndian ? bytes[offset] : bytes[offset + 1];
    const uint8_t high = littleEndian ? bytes[offset + 1] : bytes[offset];
    // Only ASCII Header attribute names and values are needed. Preserve those
    // byte-for-byte while making unrelated non-ASCII text non-matchable rather
    // than rejecting a valid Header that merely has a localized title.
    if (high == 0 && (low >= 0x20 || low == '\t' || low == '\n' || low == '\r')) {
      output.push_back(static_cast<char>(low));
    } else {
      output.push_back('\x01');
    }
  }
  return true;
}

bool findHeaderAttribute(const std::string &header, const char *name, std::string &value) {
  const std::string needle = std::string(name) + "=";
  const size_t start = header.find(needle);
  if (start == std::string::npos) return false;
  const size_t quoteAt = start + needle.size();
  if (quoteAt >= header.size() ||
      (header[quoteAt] != '\'' && header[quoteAt] != '\"')) return false;
  const size_t end = header.find(header[quoteAt], quoteAt + 1);
  if (end == std::string::npos || end == quoteAt + 1) return false;
  value = header.substr(quoteAt + 1, end - quoteAt - 1);
  return true;
}

struct EngineVersion {
  int major = 0;
  int minor = 0;
};

bool parseEngineVersion(const std::string &value, EngineVersion &version) {
  const size_t dot = value.find('.');
  if (dot == std::string::npos || dot == 0 || dot + 1 == value.size() ||
      value.find('.', dot + 1) != std::string::npos) return false;
  auto parseComponent = [](const std::string &component, int &result) {
    uint64_t parsed = 0;
    for (char character : component) {
      if (character < '0' || character > '9') return false;
      const SafeU64 shifted = safeMultiply(parsed, 10);
      const SafeU64 next = safeAdd(shifted.value, static_cast<uint64_t>(character - '0'));
      if (shifted.overflow || next.overflow ||
          next.value > static_cast<uint64_t>(INT_MAX)) return false;
      parsed = next.value;
    }
    result = static_cast<int>(parsed);
    return true;
  };
  return parseComponent(value.substr(0, dot), version.major) &&
         parseComponent(value.substr(dot + 1), version.minor);
}

bool parseEncryptedMode(const std::string &header, int &encryptedMode) {
  std::string value;
  if (!findHeaderAttribute(header, "Encrypted", value) || value == "No" || value == "0") {
    encryptedMode = 0;
    return true;
  }
  if (value == "Yes" || value == "1") {
    encryptedMode = 1;
    return true;
  }
  if (value == "2") {
    encryptedMode = 2;
    return true;
  }
  return false;
}

bool versionLess(const EngineVersion &lhs, const EngineVersion &rhs) {
  return lhs.major != rhs.major ? lhs.major < rhs.major : lhs.minor < rhs.minor;
}

bool isSupportedRecordVersion(const EngineVersion &version) {
  return version.major == 1 || version.major == 2;
}

struct JSONWriter {
  std::string buffer;
  bool firstField = true;

  void openObject() { buffer += '{'; firstField = true; }
  void closeObject() { buffer += '}'; }
  void comma() { if (!firstField) buffer += ','; firstField = false; }
  void key(const char *name) { comma(); buffer += '\"'; buffer += name; buffer += "\":"; }
  void string(const char *value) { buffer += '\"'; buffer += value; buffer += '\"'; }
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
  EngineVersion engineVersion;
  bool recordMetricsSupported = false;
  bool keyDetailUnavailable = false;
  ChecksumDiagnostics checksum;
};

struct AggregateMetrics {
  MdxMetrics mdx;
  uint64_t maximumRecordRangeBytes = 0;
  bool hasMdx = false;
  bool hasUnsupportedVersion = false;
  bool hasUnsupportedEncryption = false;
  bool hasMixedVersions = false;
  EngineVersion minimumVersion;
  EngineVersion maximumVersion;
};

void maxAssign(uint64_t &destination, uint64_t value) {
  if (value > destination) destination = value;
}

ProbeError collectV2KeyMetrics(const char *path, MdxMetrics &metrics) {
  mdict::Mdict dictionary(path);
  try {
    dictionary.initMetadataOnly();
  } catch (const mdict::ResourceException &error) {
    if (error.code() == mdict::ResourceErrorCode::checksumMismatch) {
      metrics.checksum.failureStage = ChecksumFailureStage::keyInfo;
      metrics.checksum.keyInfo = ChecksumStatus::mismatch;
      return ProbeError::checksumMismatch;
    }
    return ProbeError::malformedRecordMetadata;
  } catch (const std::exception &) {
    return ProbeError::malformedRecordMetadata;
  }
  metrics.keyBlockInfoCompressedBytes = dictionary.keyBlockInfoCompressedSize();
  metrics.keyBlockInfoDecompressedBytes = dictionary.keyBlockInfoDecompressedSize();
  metrics.keyBlockCount = dictionary.keyBlockCount();
  metrics.entryCount = dictionary.entryCount();
  metrics.totalKeyBlockCompressedBytes = dictionary.keyBlockCompressedSize();
  for (const auto *block : dictionary.keyBlockInfoList()) {
    const SafeU64 total = safeAdd(metrics.totalKeyBlockDecompressedBytes,
                                  block->key_block_decomp_size);
    if (total.overflow) return ProbeError::arithmeticOverflow;
    metrics.totalKeyBlockDecompressedBytes = total.value;
    maxAssign(metrics.maximumSingleKeyBlockCompressedBytes, block->key_block_comp_size);
    maxAssign(metrics.maximumSingleKeyBlockDecompressedBytes, block->key_block_decomp_size);
  }
  metrics.checksum.keyInfo = ChecksumStatus::valid;
  return ProbeError::none;
}

ProbeError collectMdxMetrics(const char *path, MdxMetrics &metrics) {
  if (!isRegularFile(path, &metrics.actualFileBytes)) return ProbeError::fileUnavailable;
  if (metrics.actualFileBytes < 8) return ProbeError::truncatedFile;
  std::ifstream input(path, std::ios::binary);
  if (!input) return ProbeError::fileUnavailable;

  uint8_t headerLengthBytes[4] {};
  if (!readExact(input, metrics.actualFileBytes, 0, headerLengthBytes, sizeof(headerLengthBytes)))
    return ProbeError::truncatedFile;
  metrics.headerBytes = readBE32(headerLengthBytes);
  if (metrics.headerBytes > kMaximumHeaderBytes) return ProbeError::headerTooLarge;
  const SafeU64 headerChecksumOffset = safeAdd(4, metrics.headerBytes);
  const SafeU64 headerEnd = safeAdd(headerChecksumOffset.value, 4);
  if (headerChecksumOffset.overflow || headerEnd.overflow) return ProbeError::arithmeticOverflow;
  if (headerEnd.value > metrics.actualFileBytes) return ProbeError::truncatedFile;

  std::vector<uint8_t> header(static_cast<size_t>(metrics.headerBytes));
  if (!readExact(input, metrics.actualFileBytes, 4, header.data(), header.size()))
    return ProbeError::truncatedFile;
  uint8_t checksumBytes[4] {};
  if (!readExact(input, metrics.actualFileBytes, headerChecksumOffset.value,
                 checksumBytes, sizeof(checksumBytes))) return ProbeError::truncatedFile;
  const uint32_t expectedChecksum = readLE32(checksumBytes);
  const uint32_t actualChecksum = static_cast<uint32_t>(
      mz_adler32(MZ_ADLER32_INIT, header.data(), header.size()));
  if (actualChecksum != expectedChecksum) {
    metrics.checksum.failureStage = ChecksumFailureStage::header;
    metrics.checksum.header = ChecksumStatus::mismatch;
    metrics.checksum.keyInfo = ChecksumStatus::notReached;
    metrics.checksum.keyBlock = ChecksumStatus::notReached;
    metrics.checksum.recordBlock = ChecksumStatus::notReached;
    metrics.checksum.headerEncoding = byteReverse32(expectedChecksum) == actualChecksum
        ? HeaderChecksumEncodingMatch::byteReversedBigEndian
        : HeaderChecksumEncodingMatch::neither;
    return ProbeError::checksumMismatch;
  }
  metrics.checksum.header = ChecksumStatus::valid;
  metrics.checksum.headerEncoding = HeaderChecksumEncodingMatch::canonicalLittleEndian;

  std::string headerText;
  if (!decodeHeaderASCII(header, headerText)) return ProbeError::invalidHeader;
  std::string versionText;
  if (!findHeaderAttribute(headerText, "GeneratedByEngineVersion", versionText) ||
      !parseEngineVersion(versionText, metrics.engineVersion)) return ProbeError::malformedVersion;
  if (!parseEncryptedMode(headerText, metrics.encryptedMode)) return ProbeError::malformedEncryptedMode;

  if (!isSupportedRecordVersion(metrics.engineVersion)) return ProbeError::none;
  metrics.recordMetricsSupported = true;
  const uint64_t numberWidth = metrics.engineVersion.major >= 2 ? 8 : 4;
  const uint64_t keyHeaderBytes = metrics.engineVersion.major >= 2 ? 40 : 16;
  const uint64_t recordSummaryBytes = 4 * numberWidth;
  const uint64_t keyHeaderOffset = headerEnd.value;
  uint8_t keyHeader[40] {};
  if (!readExact(input, metrics.actualFileBytes, keyHeaderOffset, keyHeader,
                 static_cast<size_t>(keyHeaderBytes))) return ProbeError::truncatedFile;

  metrics.keyBlockCount = readNumber(keyHeader, numberWidth);
  metrics.entryCount = readNumber(keyHeader + numberWidth, numberWidth);
  if (metrics.engineVersion.major >= 2) {
    metrics.keyBlockInfoDecompressedBytes = readNumber(keyHeader + 2 * numberWidth, numberWidth);
    metrics.keyBlockInfoCompressedBytes = readNumber(keyHeader + 3 * numberWidth, numberWidth);
    metrics.totalKeyBlockCompressedBytes = readNumber(keyHeader + 4 * numberWidth, numberWidth);
  } else {
    metrics.keyBlockInfoCompressedBytes = readNumber(keyHeader + 2 * numberWidth, numberWidth);
    metrics.totalKeyBlockCompressedBytes = readNumber(keyHeader + 3 * numberWidth, numberWidth);
    metrics.keyDetailUnavailable = true;
  }

  const SafeU64 afterKeyHeader = safeAdd(
      keyHeaderOffset, keyHeaderBytes + (metrics.engineVersion.major >= 2 ? 4 : 0));
  const SafeU64 afterKeyInfo = safeAdd(afterKeyHeader.value,
                                        metrics.keyBlockInfoCompressedBytes);
  const SafeU64 recordSummaryOffset = safeAdd(afterKeyInfo.value,
                                               metrics.totalKeyBlockCompressedBytes);
  if (afterKeyHeader.overflow || afterKeyInfo.overflow || recordSummaryOffset.overflow)
    return ProbeError::arithmeticOverflow;
  if (recordSummaryOffset.value > metrics.actualFileBytes) return ProbeError::truncatedFile;
  uint8_t recordSummary[32] {};
  if (!readExact(input, metrics.actualFileBytes, recordSummaryOffset.value, recordSummary,
                 static_cast<size_t>(recordSummaryBytes))) return ProbeError::truncatedFile;
  const uint64_t recordEntryCount = readNumber(recordSummary + numberWidth, numberWidth);
  metrics.recordBlockCount = readNumber(recordSummary, numberWidth);
  metrics.recordBlockInfoBytes = readNumber(recordSummary + 2 * numberWidth, numberWidth);
  metrics.totalRecordBlockCompressedBytes = readNumber(recordSummary + 3 * numberWidth, numberWidth);
  if (recordEntryCount != metrics.entryCount) return ProbeError::malformedRecordMetadata;

  const uint64_t pairStride = 2 * numberWidth;
  const SafeU64 expectedPairs = safeMultiply(metrics.recordBlockCount, pairStride);
  if (expectedPairs.overflow || expectedPairs.value != metrics.recordBlockInfoBytes)
    return ProbeError::malformedRecordMetadata;
  if (metrics.recordBlockInfoBytes > kMaximumRecordMetadataBytes)
    return ProbeError::recordMetadataTooLarge;
  const SafeU64 pairOffset = safeAdd(recordSummaryOffset.value, recordSummaryBytes);
  const SafeU64 recordDataOffset = safeAdd(pairOffset.value, metrics.recordBlockInfoBytes);
  const SafeU64 recordDataEnd = safeAdd(recordDataOffset.value,
                                        metrics.totalRecordBlockCompressedBytes);
  if (pairOffset.overflow || recordDataOffset.overflow || recordDataEnd.overflow)
    return ProbeError::arithmeticOverflow;
  if (recordDataEnd.value > metrics.actualFileBytes) return ProbeError::truncatedFile;

  std::vector<uint8_t> pairs(static_cast<size_t>(metrics.recordBlockInfoBytes));
  if (!readExact(input, metrics.actualFileBytes, pairOffset.value, pairs.data(), pairs.size()))
    return ProbeError::truncatedFile;
  uint64_t compressedTotal = 0;
  for (uint64_t index = 0; index < metrics.recordBlockCount; ++index) {
    const SafeU64 pairOffsetBytes = safeMultiply(index, pairStride);
    if (pairOffsetBytes.overflow) return ProbeError::arithmeticOverflow;
    const uint64_t compressed = readNumber(pairs.data() + pairOffsetBytes.value, numberWidth);
    const uint64_t decompressed = readNumber(pairs.data() + pairOffsetBytes.value + numberWidth,
                                             numberWidth);
    const SafeU64 nextCompressed = safeAdd(compressedTotal, compressed);
    const SafeU64 nextDecompressed = safeAdd(metrics.totalRecordBlockDecompressedBytes,
                                              decompressed);
    if (nextCompressed.overflow || nextDecompressed.overflow) return ProbeError::arithmeticOverflow;
    compressedTotal = nextCompressed.value;
    metrics.totalRecordBlockDecompressedBytes = nextDecompressed.value;
    maxAssign(metrics.maximumSingleRecordBlockCompressedBytes, compressed);
    maxAssign(metrics.maximumSingleRecordBlockDecompressedBytes, decompressed);
  }
  if (compressedTotal != metrics.totalRecordBlockCompressedBytes)
    return ProbeError::malformedRecordMetadata;

  // The vendored metadata-only path supplies the existing detailed Key metrics
  // for unencrypted v2 files. It never decodes headwords or Record payloads.
  if (metrics.engineVersion.major >= 2 && metrics.encryptedMode == 0) {
    const ProbeError keyError = collectV2KeyMetrics(path, metrics);
    if (keyError != ProbeError::none) return keyError;
  } else {
    metrics.keyDetailUnavailable = true;
    metrics.checksum.keyInfo = metrics.engineVersion.major < 2
        ? ChecksumStatus::notApplicable
        : ChecksumStatus::notChecked;
  }
  return ProbeError::none;
}

ChecksumStatus mergeChecksumStatus(ChecksumStatus lhs, ChecksumStatus rhs) {
  if (lhs == rhs) return lhs;
  if (lhs == ChecksumStatus::mismatch || rhs == ChecksumStatus::mismatch)
    return ChecksumStatus::mismatch;
  if (lhs == ChecksumStatus::notReached || rhs == ChecksumStatus::notReached)
    return ChecksumStatus::notReached;
  if (lhs == ChecksumStatus::notChecked || rhs == ChecksumStatus::notChecked)
    return ChecksumStatus::notChecked;
  // A mixed supported/not-applicable aggregate must not claim universal
  // validation of an unavailable stage.
  if (lhs == ChecksumStatus::notApplicable || rhs == ChecksumStatus::notApplicable)
    return ChecksumStatus::notChecked;
  return ChecksumStatus::valid;
}

HeaderChecksumEncodingMatch mergeHeaderEncoding(
    HeaderChecksumEncodingMatch lhs, HeaderChecksumEncodingMatch rhs) {
  return lhs == rhs ? lhs : HeaderChecksumEncodingMatch::notChecked;
}

void mergeMdxMetrics(AggregateMetrics &aggregate, const MdxMetrics &input) {
  if (!aggregate.hasMdx) {
    aggregate.hasMdx = true;
    aggregate.minimumVersion = input.engineVersion;
    aggregate.maximumVersion = input.engineVersion;
    aggregate.mdx.checksum = input.checksum;
  } else {
    if (versionLess(input.engineVersion, aggregate.minimumVersion))
      aggregate.minimumVersion = input.engineVersion;
    if (versionLess(aggregate.maximumVersion, input.engineVersion))
      aggregate.maximumVersion = input.engineVersion;
    if (input.engineVersion.major != aggregate.minimumVersion.major ||
        input.engineVersion.minor != aggregate.minimumVersion.minor)
      aggregate.hasMixedVersions = true;
    aggregate.mdx.checksum.header = mergeChecksumStatus(
        aggregate.mdx.checksum.header, input.checksum.header);
    aggregate.mdx.checksum.keyInfo = mergeChecksumStatus(
        aggregate.mdx.checksum.keyInfo, input.checksum.keyInfo);
    aggregate.mdx.checksum.keyBlock = mergeChecksumStatus(
        aggregate.mdx.checksum.keyBlock, input.checksum.keyBlock);
    aggregate.mdx.checksum.recordBlock = mergeChecksumStatus(
        aggregate.mdx.checksum.recordBlock, input.checksum.recordBlock);
    aggregate.mdx.checksum.headerEncoding = mergeHeaderEncoding(
        aggregate.mdx.checksum.headerEncoding, input.checksum.headerEncoding);
  }
  maxAssign(aggregate.mdx.actualFileBytes, input.actualFileBytes);
  maxAssign(aggregate.mdx.headerBytes, input.headerBytes);
  maxAssign(aggregate.mdx.keyBlockInfoCompressedBytes, input.keyBlockInfoCompressedBytes);
  maxAssign(aggregate.mdx.keyBlockInfoDecompressedBytes, input.keyBlockInfoDecompressedBytes);
  maxAssign(aggregate.mdx.keyBlockCount, input.keyBlockCount);
  maxAssign(aggregate.mdx.entryCount, input.entryCount);
  maxAssign(aggregate.mdx.maximumSingleKeyBlockCompressedBytes, input.maximumSingleKeyBlockCompressedBytes);
  maxAssign(aggregate.mdx.maximumSingleKeyBlockDecompressedBytes, input.maximumSingleKeyBlockDecompressedBytes);
  maxAssign(aggregate.mdx.totalKeyBlockCompressedBytes, input.totalKeyBlockCompressedBytes);
  maxAssign(aggregate.mdx.totalKeyBlockDecompressedBytes, input.totalKeyBlockDecompressedBytes);
  maxAssign(aggregate.mdx.recordBlockInfoBytes, input.recordBlockInfoBytes);
  maxAssign(aggregate.mdx.recordBlockCount, input.recordBlockCount);
  maxAssign(aggregate.mdx.maximumSingleRecordBlockCompressedBytes, input.maximumSingleRecordBlockCompressedBytes);
  maxAssign(aggregate.mdx.maximumSingleRecordBlockDecompressedBytes, input.maximumSingleRecordBlockDecompressedBytes);
  maxAssign(aggregate.mdx.totalRecordBlockCompressedBytes, input.totalRecordBlockCompressedBytes);
  maxAssign(aggregate.mdx.totalRecordBlockDecompressedBytes, input.totalRecordBlockDecompressedBytes);
  if (input.encryptedMode > aggregate.mdx.encryptedMode) aggregate.mdx.encryptedMode = input.encryptedMode;
  aggregate.mdx.engineVersion = aggregate.maximumVersion;
  aggregate.hasUnsupportedVersion = aggregate.hasUnsupportedVersion || !input.recordMetricsSupported;
  aggregate.hasUnsupportedEncryption = aggregate.hasUnsupportedEncryption || input.encryptedMode != 0;
  aggregate.mdx.keyDetailUnavailable = aggregate.mdx.keyDetailUnavailable || input.keyDetailUnavailable;
}

const char *metricsSupportStatus(const AggregateMetrics &aggregate) {
  if (!aggregate.hasMdx) return "noMDXInput";
  if (aggregate.hasUnsupportedVersion) return "identifiedButUnsupportedVersion";
  if (aggregate.hasUnsupportedEncryption) return "identifiedButUnsupportedEncryption";
  if (aggregate.hasMixedVersions) return "mixedVersions";
  return "supported";
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
    const SafeU64 range = safeSubtract(static_cast<uint64_t>(endSigned),
                                       static_cast<uint64_t>(startSigned));
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
  writer.fieldString("generatedBy", "MDictResourceMetricsProbe-D1b-3A-2B-M1.1");
  writer.fieldU64("actualFileBytes", aggregate.mdx.actualFileBytes);
  writer.fieldU64("headerBytes", aggregate.mdx.headerBytes);
  writer.fieldU64("keyBlockInfoCompressedBytes", aggregate.mdx.keyBlockInfoCompressedBytes);
  writer.fieldU64("keyBlockInfoDecompressedBytes", aggregate.mdx.keyBlockInfoDecompressedBytes);
  writer.fieldU64("keyBlockCount", aggregate.mdx.keyBlockCount);
  writer.fieldU64("entryCount", aggregate.mdx.entryCount);
  if (aggregate.mdx.keyDetailUnavailable) {
    writer.key("maximumSingleKeyBlockCompressedBytes"); writer.null();
    writer.key("maximumSingleKeyBlockDecompressedBytes"); writer.null();
    writer.key("totalKeyBlockDecompressedBytes"); writer.null();
  } else {
    writer.fieldU64("maximumSingleKeyBlockCompressedBytes", aggregate.mdx.maximumSingleKeyBlockCompressedBytes);
    writer.fieldU64("maximumSingleKeyBlockDecompressedBytes", aggregate.mdx.maximumSingleKeyBlockDecompressedBytes);
    writer.fieldU64("totalKeyBlockDecompressedBytes", aggregate.mdx.totalKeyBlockDecompressedBytes);
  }
  writer.fieldU64("totalKeyBlockCompressedBytes", aggregate.mdx.totalKeyBlockCompressedBytes);
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
  writer.fieldI32("engineVersionMajor", aggregate.maximumVersion.major);
  writer.fieldI32("engineVersionMinor", aggregate.maximumVersion.minor);
  writer.fieldI32("minimumEngineVersionMajor", aggregate.minimumVersion.major);
  writer.fieldI32("minimumEngineVersionMinor", aggregate.minimumVersion.minor);
  writer.fieldString("metricsSupportStatus", metricsSupportStatus(aggregate));
  writer.fieldString("checksumFailureStage",
                     checksumFailureStageString(aggregate.mdx.checksum.failureStage));
  writer.fieldString("headerChecksumStatus", checksumStatusString(aggregate.mdx.checksum.header));
  writer.fieldString("keyInfoChecksumStatus", checksumStatusString(aggregate.mdx.checksum.keyInfo));
  writer.fieldString("keyBlockChecksumStatus", checksumStatusString(aggregate.mdx.checksum.keyBlock));
  writer.fieldString("recordBlockChecksumStatus", checksumStatusString(aggregate.mdx.checksum.recordBlock));
  writer.fieldString("headerChecksumEncodingMatch",
                     headerChecksumEncodingMatchString(aggregate.mdx.checksum.headerEncoding));
  writer.key("unavailable");
  writer.buffer += "[\"maximumSingleKeyBytes\",\"maximumObservedRecordRangeBytes\"";
  if (aggregate.mdx.keyDetailUnavailable) {
    writer.buffer += ",\"maximumSingleKeyBlockCompressedBytes\",\"maximumSingleKeyBlockDecompressedBytes\",\"totalKeyBlockDecompressedBytes\"";
  }
  writer.buffer += "]";
  writer.closeObject();
}

void writeChecksumDiagnosticJSON(JSONWriter &writer, const ChecksumDiagnostics &diagnostics) {
  writer.openObject();
  writer.fieldI32("schemaVersion", 2);
  writer.fieldString("checksumFailureStage", checksumFailureStageString(diagnostics.failureStage));
  writer.fieldString("headerChecksumStatus", checksumStatusString(diagnostics.header));
  writer.fieldString("keyInfoChecksumStatus", checksumStatusString(diagnostics.keyInfo));
  writer.fieldString("keyBlockChecksumStatus", checksumStatusString(diagnostics.keyBlock));
  writer.fieldString("recordBlockChecksumStatus", checksumStatusString(diagnostics.recordBlock));
  writer.fieldString("headerChecksumEncodingMatch",
                     headerChecksumEncodingMatchString(diagnostics.headerEncoding));
  writer.closeObject();
}

void printUsage(const char *program) {
  std::fprintf(stderr,
      "Usage: %s (--mdx <path> | --sqlite <path>)... --output <output.json> [--force] [--diagnose-checksum]\n"
      "\n"
      "  --mdx path       Explicit MDX metadata input; may be repeated.\n"
      "  --sqlite path    Explicit read-only SQLite range input; may be repeated.\n"
      "  --output path    Write anonymous aggregate JSON (0600).\n"
      "  --force          Overwrite an existing output file.\n"
      "  --diagnose-checksum  Emit fixed anonymous JSON to stdout on checksum failure.\n"
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
  bool diagnoseChecksum = false;
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
    } else if (std::strcmp(argv[index], "--diagnose-checksum") == 0) {
      diagnoseChecksum = true;
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
        if (diagnoseChecksum && error == ProbeError::checksumMismatch) {
          JSONWriter diagnostic;
          writeChecksumDiagnosticJSON(diagnostic, metrics.checksum);
          std::fputs(diagnostic.buffer.c_str(), stdout);
          std::fputc('\n', stdout);
          std::fputs("Error: checksum verification failed; anonymous diagnostic emitted.\n", stderr);
          return 1;
        }
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
