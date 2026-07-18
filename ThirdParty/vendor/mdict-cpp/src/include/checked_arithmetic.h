/*
 * Copyright (c) 2025-Present
 * All rights reserved.
 *
 * This code is licensed under the BSD 3-Clause License.
 * See the LICENSE file for details.
 *
 * LocalDictionary D1b-3A-2A: Checked arithmetic helpers for safe integer
 * conversion and arithmetic on MDX/MDD offset, length and size values.
 *
 * Every function throws ResourceException before overflow or truncation
 * would occur.  No platform-specific width assumptions (unsigned long,
 * std::streamoff, std::streamsize) are relied upon.
 */

#pragma once

#include "resource_limits.h"

#include <cstdint>
#include <istream>
#include <limits>

namespace mdict {

// ---------------------------------------------------------------------------
// Checked addition — throws on overflow.
// ---------------------------------------------------------------------------
inline uint64_t checkedAddUInt64(uint64_t a, uint64_t b) {
  if (a > UINT64_MAX - b)
    throw ResourceException(ResourceErrorCode::arithmeticOverflow);
  return a + b;
}

// ---------------------------------------------------------------------------
// Checked subtraction — throws on underflow.
// ---------------------------------------------------------------------------
inline uint64_t checkedSubtractUInt64(uint64_t a, uint64_t b) {
  if (a < b)
    throw ResourceException(ResourceErrorCode::arithmeticOverflow);
  return a - b;
}

// ---------------------------------------------------------------------------
// Checked multiplication — throws on overflow.
// ---------------------------------------------------------------------------
inline uint64_t checkedMultiplyUInt64(uint64_t a, uint64_t b) {
  if (a != 0 && b > UINT64_MAX / a)
    throw ResourceException(ResourceErrorCode::arithmeticOverflow);
  return a * b;
}

// ---------------------------------------------------------------------------
// Checked uint64_t → size_t
// ---------------------------------------------------------------------------
inline size_t checkedUInt64ToSizeT(uint64_t v) {
  if (v > static_cast<uint64_t>(std::numeric_limits<size_t>::max()))
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);
  return static_cast<size_t>(v);
}

// ---------------------------------------------------------------------------
// Checked uint64_t → std::streamoff (for seekg / position).
// streamoff is a signed type; reject values that don't fit.
// ---------------------------------------------------------------------------
inline std::streamoff checkedUInt64ToStreamoff(uint64_t v) {
  if (v > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max()))
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);
  return static_cast<std::streamoff>(v);
}

// ---------------------------------------------------------------------------
// Checked uint64_t → std::streamsize (for read / write length).
// streamsize is a signed type; reject values that don't fit.
// ---------------------------------------------------------------------------
inline std::streamsize checkedUInt64ToStreamSize(uint64_t v) {
  if (v > static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max()))
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);
  return static_cast<std::streamsize>(v);
}

// ---------------------------------------------------------------------------
// Checked uint64_t → int — only for unavoidably-int APIs.
// In D1b-3A-2A the Key path no longer uses this; available if needed.
// ---------------------------------------------------------------------------
inline int checkedUInt64ToInt(uint64_t v) {
  if (v > static_cast<uint64_t>(std::numeric_limits<int>::max()))
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);
  return static_cast<int>(v);
}

}  // namespace mdict
