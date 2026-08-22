/*
 * Copyright (c) 2025-Present
 * All rights reserved.
 *
 * This code is licensed under the BSD 3-Clause License.
 * See the LICENSE file for details.
 *
 * LocalDictionary D1b-3A-2A-R1: Bounded exact zlib decompression.
 *
 * This is the ONLY decompression helper used by Key-block paths after
 * D1b-3A-2A.  It:
 *   - receives the PAYLOAD only (caller has already stripped the 8-byte
 *     prefix: 4 bytes compression type + 4 bytes Adler-32);
 *   - verifies all type-boundary conversions before allocation;
 *   - allocates exactly expectedDecompressedSize;
 *   - calls uncompress() exactly once;
 *   - rejects output that does not match expected size exactly;
 *   - has no unbounded fallback, no sourceLen << 3, no <<=2 retry.
 *
 * D1b-3A-2A-R1 changes:
 *   - sourceLen == 0 is rejected;
 *   - source == nullptr is always rejected;
 *   - std::bad_alloc is caught and converted to allocationFailed;
 *   - zlib errors return malformedCompressedData, not checksumMismatch;
 *   - size mismatch returns decompressedSizeMismatch.
 *
 * The existing zlib_mem_uncompress() in zlib_wrapper.h continues to serve
 * Record-block paths (not modified in D1b-3A-2A or R1).
 */

#pragma once

#include "checked_arithmetic.h"
#include "miniz/miniz.h"
#include "resource_test_observer.h"

#include <cstddef>
#include <cstdint>
#include <new>
#include <vector>

namespace mdict {

// ---------------------------------------------------------------------------
// boundedExactZlibDecompress
//
// source       — pointer to the zlib-compressed PAYLOAD (after 8-byte prefix)
// sourceLen    — payload length in bytes (must be > 0)
// expectedSize — exact expected decompressed size (must be > 0)
//
// Returns a vector of exactly expectedSize bytes on success.
// Throws ResourceException on any failure (allocation, decompression,
// size mismatch).  Never retries or expands.
// ---------------------------------------------------------------------------
inline std::vector<uint8_t> boundedExactZlibDecompress(
    const void *source, size_t sourceLen, size_t expectedSize) {

  // --- validate inputs ---
  if (source == nullptr)
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  if (sourceLen == 0)
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  if (expectedSize == 0)
    throw ResourceException(ResourceErrorCode::decompressedSizeMismatch);

  // --- type-boundary checks: sourceLen → uLong (miniz) ---
  // uLong is at least 32-bit; check it can hold sourceLen.
  if (sourceLen > static_cast<size_t>(std::numeric_limits<uLong>::max()))
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);

  // --- type-boundary checks: expectedSize → uLongf (miniz) ---
  if (expectedSize > static_cast<size_t>(std::numeric_limits<uLongf>::max()))
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);

  // --- allocate output AFTER all checks pass ---
  std::vector<uint8_t> buffer;
  try {
#ifdef MDICT_RESOURCE_TEST_OBSERVER
    observeOutputBufferAllocation();
#endif
    buffer.resize(expectedSize);
  } catch (const std::bad_alloc &) {
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }

  uLongf destLen = static_cast<uLongf>(expectedSize);

  // --- single uncompress call; no retry ---
#ifdef MDICT_RESOURCE_TEST_OBSERVER
  observeUncompressCall();
#endif
  int err = uncompress(
      buffer.data(), &destLen,
      reinterpret_cast<const Bytef *>(source),
      static_cast<uLong>(sourceLen));

  if (err != Z_OK)
    throw ResourceException(ResourceErrorCode::malformedCompressedData);

  // --- exact size match ---
  if (static_cast<size_t>(destLen) != expectedSize) {
    throw ResourceException(ResourceErrorCode::decompressedSizeMismatch);
  }

  return buffer;
}

}  // namespace mdict
