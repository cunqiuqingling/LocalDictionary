/*
 * Copyright (c) 2025-Present
 * All rights reserved.
 *
 * This code is licensed under the BSD 3-Clause License.
 * See the LICENSE file for details.
 *
 * Test-only resource observations for LocalDictionary's bounded MDict parser.
 * The production App is compiled without MDICT_RESOURCE_TEST_OBSERVER, so this
 * header contributes no declarations, calls, state, or exported symbols there.
 */

#pragma once

#ifdef MDICT_RESOURCE_TEST_OBSERVER

#include <cstdint>

namespace mdict {

struct ResourceTestObserverSnapshot {
  uint64_t inputBufferAllocationCount;
  uint64_t outputBufferAllocationCount;
  uint64_t uncompressCallCount;
  uint64_t keyItemLiveCount;
};

void resetResourceTestObserver() noexcept;
ResourceTestObserverSnapshot resourceTestObserverSnapshot() noexcept;

void observeInputBufferAllocation() noexcept;
void observeOutputBufferAllocation() noexcept;
void observeUncompressCall() noexcept;
void observeKeyItemCreated() noexcept;
void observeKeyItemDestroyed() noexcept;

}  // namespace mdict

#endif  // MDICT_RESOURCE_TEST_OBSERVER
