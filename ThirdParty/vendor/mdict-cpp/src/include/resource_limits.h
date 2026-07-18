/*
 * Copyright (c) 2025-Present
 * All rights reserved.
 *
 * This code is licensed under the BSD 3-Clause License.
 * See the LICENSE file for details.
 *
 * LocalDictionary D1b-3A-2A: ResourceLimits model for MDX/MDD resource
 * bounding.  Production defaults prevent unbounded allocations, zlib bomb
 * expansion, and integer-wrapping attacks on malformed or truncated files.
 */

#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>

namespace mdict {

// ---------------------------------------------------------------------------
// Closed error codes — never leak paths, keys, record content or header XML.
// ---------------------------------------------------------------------------
enum class ResourceErrorCode {
  invalidResourceLimits,
  fileTooLarge,
  truncatedFile,
  arithmeticOverflow,
  numericConversionOverflow,
  headerTooLarge,
  keyBlockInfoCompressedTooLarge,
  keyBlockInfoDecompressedTooLarge,
  keyBlockCountTooLarge,
  entryCountTooLarge,
  singleKeyBlockCompressedTooLarge,
  singleKeyBlockDecompressedTooLarge,
  totalKeyBlockCompressedTooLarge,
  totalKeyBlockDecompressedTooLarge,
  malformedKeyBlockMetadata,
  checksumMismatch,
  decompressedSizeMismatch,
  offsetOutOfBounds,
  allocationFailed,
  invalidCompressionType,
};

inline const char *resourceErrorCodeString(ResourceErrorCode code) {
  switch (code) {
    case ResourceErrorCode::invalidResourceLimits:          return "invalid resource limits";
    case ResourceErrorCode::fileTooLarge:                   return "file exceeds maximum supported size";
    case ResourceErrorCode::truncatedFile:                  return "file truncated or offset out of bounds";
    case ResourceErrorCode::arithmeticOverflow:             return "arithmetic overflow in size computation";
    case ResourceErrorCode::numericConversionOverflow:      return "numeric conversion would truncate";
    case ResourceErrorCode::headerTooLarge:                 return "dictionary header exceeds limit";
    case ResourceErrorCode::keyBlockInfoCompressedTooLarge: return "key-block info compressed size exceeds limit";
    case ResourceErrorCode::keyBlockInfoDecompressedTooLarge: return "key-block info decompressed size exceeds limit";
    case ResourceErrorCode::keyBlockCountTooLarge:          return "key block count exceeds limit";
    case ResourceErrorCode::entryCountTooLarge:             return "entry count exceeds limit";
    case ResourceErrorCode::singleKeyBlockCompressedTooLarge:  return "single key block compressed size exceeds limit";
    case ResourceErrorCode::singleKeyBlockDecompressedTooLarge: return "single key block decompressed size exceeds limit";
    case ResourceErrorCode::totalKeyBlockCompressedTooLarge:   return "total key block compressed size exceeds limit";
    case ResourceErrorCode::totalKeyBlockDecompressedTooLarge: return "total key block decompressed size exceeds limit";
    case ResourceErrorCode::malformedKeyBlockMetadata:      return "malformed key-block metadata";
    case ResourceErrorCode::checksumMismatch:               return "block checksum mismatch";
    case ResourceErrorCode::decompressedSizeMismatch:       return "decompressed size mismatch";
    case ResourceErrorCode::offsetOutOfBounds:              return "offset out of bounds";
    case ResourceErrorCode::allocationFailed:               return "memory allocation failed";
    case ResourceErrorCode::invalidCompressionType:         return "invalid or unsupported compression type";
  }
  return "internal error";
}

// ---------------------------------------------------------------------------
// ResourceException — closed std::exception subclass.
// what() returns the sanitized code string; never includes paths or content.
// ---------------------------------------------------------------------------
class ResourceException : public std::runtime_error {
 public:
  explicit ResourceException(ResourceErrorCode code)
      : std::runtime_error(resourceErrorCodeString(code)), code_(code) {}

  ResourceErrorCode code() const noexcept { return code_; }

 private:
  ResourceErrorCode code_;
};

// ---------------------------------------------------------------------------
// ResourceLimits — immutable limits for a single MDX/MDD parse session.
//
// All byte/count fields are uint64_t.  0 means "unset" and is rejected by
// validate().  There is no unlimited mode.
// ---------------------------------------------------------------------------
struct ResourceLimits {
  // --- File ---
  uint64_t maximumFileBytes = 0;

  // --- Header ---
  uint64_t maximumHeaderBytes = 0;

  // --- Key-block info ---
  uint64_t maximumKeyBlockInfoCompressedBytes = 0;
  uint64_t maximumKeyBlockInfoDecompressedBytes = 0;

  // --- Key blocks ---
  uint64_t maximumKeyBlockCount = 0;
  uint64_t maximumEntryCount = 0;
  uint64_t maximumSingleKeyBlockCompressedBytes = 0;
  uint64_t maximumSingleKeyBlockDecompressedBytes = 0;
  uint64_t maximumTotalKeyBlockCompressedBytes = 0;
  uint64_t maximumTotalKeyBlockDecompressedBytes = 0;

  // --- Single key (not enforced in D1b-3A-2A; deferred to entry materialization) ---
  uint64_t maximumSingleKeyBytes = 0;

  // --- Record blocks (model only; not enforced in D1b-3A-2A) ---
  uint64_t maximumRecordBlockInfoBytes = 0;
  uint64_t maximumRecordBlockCount = 0;
  uint64_t maximumSingleRecordBlockCompressedBytes = 0;
  uint64_t maximumSingleRecordBlockDecompressedBytes = 0;
  uint64_t maximumTotalRecordBlockCompressedBytes = 0;
  uint64_t maximumTotalRecordBlockDecompressedBytes = 0;

  // --- Record read (model only; not enforced in D1b-3A-2A) ---
  uint64_t maximumRecordRangeBytes = 0;
  uint64_t maximumReturnedRecordBytes = 0;

  // --- Indexing ---
  uint32_t indexingCancellationInterval = 0;

  // -----------------------------------------------------------------------
  // Production defaults — generous enough for legitimate dictionaries,
  // bounded enough to prevent resource-exhaustion attacks.
  // -----------------------------------------------------------------------
  static ResourceLimits productionDefaults() {
    ResourceLimits l;
    l.maximumFileBytes                          = UINT64_C(2147483648);   // 2 GiB
    l.maximumHeaderBytes                        = UINT64_C(65536);        // 64 KiB
    l.maximumKeyBlockInfoCompressedBytes        = UINT64_C(1048576);      // 1 MiB
    l.maximumKeyBlockInfoDecompressedBytes      = UINT64_C(4194304);      // 4 MiB
    l.maximumKeyBlockCount                      = UINT64_C(8192);
    l.maximumEntryCount                         = UINT64_C(2000000);
    l.maximumSingleKeyBlockCompressedBytes      = UINT64_C(4194304);      // 4 MiB
    l.maximumSingleKeyBlockDecompressedBytes    = UINT64_C(8388608);      // 8 MiB
    l.maximumTotalKeyBlockCompressedBytes       = UINT64_C(67108864);     // 64 MiB
    l.maximumTotalKeyBlockDecompressedBytes     = UINT64_C(134217728);    // 128 MiB
    l.maximumSingleKeyBytes                     = UINT64_C(10240);        // 10 KiB
    l.maximumRecordBlockInfoBytes               = UINT64_C(4194304);
    l.maximumRecordBlockCount                   = UINT64_C(32768);
    l.maximumSingleRecordBlockCompressedBytes   = UINT64_C(16777216);
    l.maximumSingleRecordBlockDecompressedBytes = UINT64_C(33554432);
    l.maximumTotalRecordBlockCompressedBytes    = UINT64_C(2147483648);
    l.maximumTotalRecordBlockDecompressedBytes  = UINT64_C(8589934592);
    l.maximumRecordRangeBytes                   = UINT64_C(8388608);
    l.maximumReturnedRecordBytes                = UINT64_C(8388608);
    l.indexingCancellationInterval              = UINT32_C(256);
    return l;
  }

  // -----------------------------------------------------------------------
  // Validate — throws ResourceException(invalidResourceLimits) if any field
  // is zero or if cross-relations are violated.
  // -----------------------------------------------------------------------
  void validate() const {
    // No field may be zero
    if (maximumFileBytes == 0)                     throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumHeaderBytes == 0)                   throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumKeyBlockInfoCompressedBytes == 0)   throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumKeyBlockInfoDecompressedBytes == 0) throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumKeyBlockCount == 0)                 throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumEntryCount == 0)                    throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleKeyBlockCompressedBytes == 0) throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleKeyBlockDecompressedBytes == 0) throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalKeyBlockCompressedBytes == 0)  throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalKeyBlockDecompressedBytes == 0) throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleKeyBytes == 0)                throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumRecordBlockInfoBytes == 0)          throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumRecordBlockCount == 0)              throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleRecordBlockCompressedBytes == 0)  throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleRecordBlockDecompressedBytes == 0) throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalRecordBlockCompressedBytes == 0)   throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalRecordBlockDecompressedBytes == 0) throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumRecordRangeBytes == 0)              throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumReturnedRecordBytes == 0)           throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (indexingCancellationInterval == 0)         throw ResourceException(ResourceErrorCode::invalidResourceLimits);

    // Cross-relations
    if (maximumHeaderBytes > maximumFileBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);

    if (maximumSingleKeyBlockCompressedBytes > maximumTotalKeyBlockCompressedBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleKeyBlockDecompressedBytes > maximumTotalKeyBlockDecompressedBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumKeyBlockInfoCompressedBytes > maximumFileBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumKeyBlockInfoDecompressedBytes > maximumTotalKeyBlockDecompressedBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalKeyBlockCompressedBytes > maximumFileBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);

    if (maximumSingleRecordBlockCompressedBytes > maximumTotalRecordBlockCompressedBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumSingleRecordBlockDecompressedBytes > maximumTotalRecordBlockDecompressedBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalRecordBlockCompressedBytes > maximumFileBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
    if (maximumTotalRecordBlockDecompressedBytes < maximumTotalRecordBlockCompressedBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);

    if (maximumReturnedRecordBytes > maximumRecordRangeBytes)
      throw ResourceException(ResourceErrorCode::invalidResourceLimits);
  }
};

}  // namespace mdict
