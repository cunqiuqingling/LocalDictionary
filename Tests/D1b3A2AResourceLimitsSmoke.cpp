// D1b-3A-2A-R2 security smoke.
//
// All fixtures are generated from synthetic data at runtime.  The suite does
// not read private dictionaries, Application Support, Keychain, or network.

#include "mdict.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <optional>
#include <string>
#include <sys/types.h>
#include <unistd.h>
#include <utility>
#include <vector>

#include "miniz/miniz.h"

#ifndef MDICT_RESOURCE_TEST_OBSERVER
#error "R2 smoke requires MDICT_RESOURCE_TEST_OBSERVER"
#endif

namespace {

using mdict::ResourceErrorCode;
using mdict::ResourceException;

int g_checks = 0;

void require(bool condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
  ++g_checks;
}

template <typename Work>
void expectCode(ResourceErrorCode expected, const char *message, Work work) {
  try {
    work();
  } catch (const ResourceException &error) {
    if (error.code() != expected) {
      std::fprintf(stderr, "FAIL: %s (expected %d, got %d: %s)\n", message,
                   static_cast<int>(expected), static_cast<int>(error.code()),
                   error.what());
      std::exit(1);
    }
    ++g_checks;
    return;
  }
  std::fprintf(stderr, "FAIL: %s (no exception)\n", message);
  std::exit(1);
}

void writeBE16(std::vector<uint8_t> &buffer, uint16_t value) {
  buffer.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
  buffer.push_back(static_cast<uint8_t>(value & 0xff));
}

void writeBE32(std::vector<uint8_t> &buffer, uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) {
    buffer.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void writeBE64(std::vector<uint8_t> &buffer, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    buffer.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

uint32_t readBE32(const uint8_t *bytes) {
  return (static_cast<uint32_t>(bytes[0]) << 24) |
         (static_cast<uint32_t>(bytes[1]) << 16) |
         (static_cast<uint32_t>(bytes[2]) << 8) |
         static_cast<uint32_t>(bytes[3]);
}

uint32_t adler32Bytes(const void *bytes, size_t length) {
  return static_cast<uint32_t>(mz_adler32(
      MZ_ADLER32_INIT, static_cast<const unsigned char *>(bytes), length));
}

std::vector<uint8_t> zlibCompress(const std::vector<uint8_t> &input) {
  mz_ulong capacity = mz_compressBound(input.size());
  std::vector<uint8_t> output(capacity);
  mz_ulong length = capacity;
  const int status = mz_compress(output.data(), &length, input.data(),
                                 static_cast<mz_ulong>(input.size()));
  require(status == MZ_OK, "synthetic zlib compression");
  output.resize(length);
  return output;
}

enum class FixtureEncoding { utf8, utf16 };

struct KeySpec {
  std::string text;
  bool hasDelimiter = true;
  bool trailingSingleUTF16Byte = false;
  uint64_t recordStart = 0;
};

struct BlockSpec {
  std::vector<KeySpec> keys;
  uint64_t declaredEntries = 0;
  std::array<uint8_t, 4> compressionPrefix{2, 0, 0, 0};
  bool wrongAdler = false;
  std::optional<uint64_t> metadataCompressedSize;
  std::optional<uint64_t> metadataDecompressedSize;
};

struct FixtureSpec {
  FixtureEncoding encoding = FixtureEncoding::utf8;
  std::vector<BlockSpec> blocks;
  std::optional<uint64_t> headerBlockCount;
  std::optional<uint64_t> headerEntryCount;
  std::optional<uint64_t> headerKeyBlockSize;
};

struct BuiltFixture {
  std::vector<uint8_t> bytes;
  size_t keyBodyOffset = 0;
  std::vector<uint64_t> actualCompressedSizes;
  std::vector<uint64_t> actualDecompressedSizes;
};

void appendEncodedText(std::vector<uint8_t> &output, const std::string &text,
                       FixtureEncoding encoding) {
  for (unsigned char character : text) {
    output.push_back(character);
    if (encoding == FixtureEncoding::utf16) output.push_back(0);
  }
}

void appendTerminator(std::vector<uint8_t> &output,
                      FixtureEncoding encoding) {
  output.push_back(0);
  if (encoding == FixtureEncoding::utf16) output.push_back(0);
}

void appendMetadataKey(std::vector<uint8_t> &output, const std::string &text,
                       FixtureEncoding encoding) {
  writeBE16(output, static_cast<uint16_t>(text.size()));
  appendEncodedText(output, text, encoding);
  appendTerminator(output, encoding);
}

std::vector<uint8_t> encodeKeyBlock(const BlockSpec &block,
                                    FixtureEncoding encoding) {
  std::vector<uint8_t> raw;
  for (const KeySpec &key : block.keys) {
    writeBE64(raw, key.recordStart);
    if (key.trailingSingleUTF16Byte) {
      raw.push_back('x');
      continue;
    }
    appendEncodedText(raw, key.text, encoding);
    if (key.hasDelimiter) appendTerminator(raw, encoding);
  }
  return raw;
}

BuiltFixture buildFixture(const FixtureSpec &spec) {
  require(!spec.blocks.empty(), "fixture has at least one block");

  const char *encodingName =
      spec.encoding == FixtureEncoding::utf16 ? "UTF-16" : "UTF-8";
  const std::string headerXML =
      std::string("<Dictionary GeneratedByEngineVersion=\"2.0\" ") +
      "RequiredEngineVersion=\"2.0\" Encrypted=\"No\" Encoding=\"" +
      encodingName + "\"/>";
  std::vector<uint8_t> headerUTF16;
  appendEncodedText(headerUTF16, headerXML, FixtureEncoding::utf16);

  std::vector<std::vector<uint8_t>> fullBlocks;
  BuiltFixture result;
  uint64_t declaredTotal = 0;
  uint64_t actualBlockBytes = 0;

  for (const BlockSpec &block : spec.blocks) {
    require(block.declaredEntries > 0, "block declared entries nonzero");
    declaredTotal += block.declaredEntries;
    std::vector<uint8_t> raw = encodeKeyBlock(block, spec.encoding);
    std::vector<uint8_t> payload =
        block.compressionPrefix[0] == 0 ? raw : zlibCompress(raw);
    std::vector<uint8_t> full(block.compressionPrefix.begin(),
                              block.compressionPrefix.end());
    uint32_t checksum = adler32Bytes(raw.data(), raw.size());
    if (block.wrongAdler) checksum ^= UINT32_C(0x01000000);
    writeBE32(full, checksum);
    full.insert(full.end(), payload.begin(), payload.end());
    result.actualCompressedSizes.push_back(full.size());
    result.actualDecompressedSizes.push_back(raw.size());
    actualBlockBytes += full.size();
    fullBlocks.push_back(std::move(full));
  }

  std::vector<uint8_t> metadata;
  for (size_t index = 0; index < spec.blocks.size(); ++index) {
    const BlockSpec &block = spec.blocks[index];
    writeBE64(metadata, block.declaredEntries);
    const std::string first = block.keys.empty() ? "a" : block.keys.front().text;
    const std::string last = block.keys.empty() ? "z" : block.keys.back().text;
    appendMetadataKey(metadata, first.empty() ? "a" : first, spec.encoding);
    appendMetadataKey(metadata, last.empty() ? "z" : last, spec.encoding);
    writeBE64(metadata, block.metadataCompressedSize.value_or(
                            result.actualCompressedSizes[index]));
    writeBE64(metadata, block.metadataDecompressedSize.value_or(
                            result.actualDecompressedSizes[index]));
  }

  std::vector<uint8_t> compressedMetadata = zlibCompress(metadata);
  std::vector<uint8_t> metadataBlock{2, 0, 0, 0};
  writeBE32(metadataBlock, adler32Bytes(metadata.data(), metadata.size()));
  metadataBlock.insert(metadataBlock.end(), compressedMetadata.begin(),
                       compressedMetadata.end());

  const uint64_t headerBlocks =
      spec.headerBlockCount.value_or(spec.blocks.size());
  const uint64_t headerEntries =
      spec.headerEntryCount.value_or(declaredTotal);
  const uint64_t headerKeyBytes =
      spec.headerKeyBlockSize.value_or(actualBlockBytes);

  std::vector<uint8_t> keyHeader;
  writeBE64(keyHeader, headerBlocks);
  writeBE64(keyHeader, headerEntries);
  writeBE64(keyHeader, metadata.size());
  writeBE64(keyHeader, metadataBlock.size());
  writeBE64(keyHeader, headerKeyBytes);

  std::vector<uint8_t> recordRaw{'r', 0};
  std::vector<uint8_t> recordPayload = zlibCompress(recordRaw);
  std::vector<uint8_t> recordBlock{2, 0, 0, 0};
  writeBE32(recordBlock, adler32Bytes(recordRaw.data(), recordRaw.size()));
  recordBlock.insert(recordBlock.end(), recordPayload.begin(), recordPayload.end());
  std::vector<uint8_t> recordInfo;
  writeBE64(recordInfo, recordBlock.size());
  writeBE64(recordInfo, recordRaw.size());

  writeBE32(result.bytes, static_cast<uint32_t>(headerUTF16.size()));
  result.bytes.insert(result.bytes.end(), headerUTF16.begin(), headerUTF16.end());
  writeBE32(result.bytes,
            adler32Bytes(headerUTF16.data(), headerUTF16.size()));
  result.bytes.insert(result.bytes.end(), keyHeader.begin(), keyHeader.end());
  writeBE32(result.bytes, adler32Bytes(keyHeader.data(), keyHeader.size()));
  result.bytes.insert(result.bytes.end(), metadataBlock.begin(), metadataBlock.end());
  result.keyBodyOffset = result.bytes.size();
  for (const auto &block : fullBlocks) {
    result.bytes.insert(result.bytes.end(), block.begin(), block.end());
  }
  writeBE64(result.bytes, 1);
  writeBE64(result.bytes, headerEntries);
  writeBE64(result.bytes, recordInfo.size());
  writeBE64(result.bytes, recordBlock.size());
  result.bytes.insert(result.bytes.end(), recordInfo.begin(), recordInfo.end());
  result.bytes.insert(result.bytes.end(), recordBlock.begin(), recordBlock.end());
  return result;
}

void writeFixture(const std::string &path, const BuiltFixture &fixture) {
  std::ofstream output(path, std::ios::binary);
  require(output.good(), "open synthetic fixture");
  output.write(reinterpret_cast<const char *>(fixture.bytes.data()),
               static_cast<std::streamsize>(fixture.bytes.size()));
  require(output.good(), "write synthetic fixture");
}

BlockSpec oneBlock(std::vector<KeySpec> keys, uint64_t declared,
                   uint8_t compression = 2) {
  BlockSpec block;
  block.keys = std::move(keys);
  block.declaredEntries = declared;
  block.compressionPrefix = {compression, 0, 0, 0};
  return block;
}

mdict::ResourceLimits smallLimits() {
  auto limits = mdict::ResourceLimits::productionDefaults();
  limits.maximumFileBytes = UINT64_C(1048576);
  limits.maximumKeyBlockInfoCompressedBytes = UINT64_C(65536);
  limits.maximumKeyBlockInfoDecompressedBytes = UINT64_C(262144);
  limits.maximumKeyBlockCount = 16;
  limits.maximumEntryCount = 64;
  limits.maximumSingleKeyBlockCompressedBytes = UINT64_C(65536);
  limits.maximumSingleKeyBlockDecompressedBytes = UINT64_C(262144);
  limits.maximumTotalKeyBlockCompressedBytes = UINT64_C(262144);
  limits.maximumTotalKeyBlockDecompressedBytes = UINT64_C(1048576);
  limits.maximumRecordBlockInfoBytes = UINT64_C(65536);
  limits.maximumRecordBlockCount = 16;
  limits.maximumSingleRecordBlockCompressedBytes = UINT64_C(65536);
  limits.maximumSingleRecordBlockDecompressedBytes = UINT64_C(262144);
  limits.maximumTotalRecordBlockCompressedBytes = UINT64_C(262144);
  limits.maximumTotalRecordBlockDecompressedBytes = UINT64_C(1048576);
  limits.maximumRecordRangeBytes = UINT64_C(65536);
  limits.maximumReturnedRecordBytes = UINT64_C(65536);
  limits.validate();
  return limits;
}

std::string storeFixture(const std::string &directory, const char *name,
                         const FixtureSpec &spec) {
  const std::string path = directory + "/" + name;
  writeFixture(path, buildFixture(spec));
  return path;
}

void testProductionDefaults() {
  const auto l = mdict::ResourceLimits::productionDefaults();
  require(l.maximumFileBytes == UINT64_C(2147483648), "default file bytes");
  require(l.maximumHeaderBytes == UINT64_C(65536), "default header bytes");
  require(l.maximumKeyBlockInfoCompressedBytes == UINT64_C(1048576), "default key-info compressed");
  require(l.maximumKeyBlockInfoDecompressedBytes == UINT64_C(4194304), "default key-info decompressed");
  require(l.maximumKeyBlockCount == UINT64_C(8192), "default key block count");
  require(l.maximumEntryCount == UINT64_C(2000000), "default entry count");
  require(l.maximumSingleKeyBlockCompressedBytes == UINT64_C(4194304), "default single key compressed");
  require(l.maximumSingleKeyBlockDecompressedBytes == UINT64_C(8388608), "default single key decompressed");
  require(l.maximumTotalKeyBlockCompressedBytes == UINT64_C(67108864), "default total key compressed");
  require(l.maximumTotalKeyBlockDecompressedBytes == UINT64_C(134217728), "default total key decompressed");
  require(l.maximumSingleKeyBytes == UINT64_C(10240), "default single key bytes");
  require(l.maximumRecordBlockInfoBytes == UINT64_C(4194304), "default record info bytes");
  require(l.maximumRecordBlockCount == UINT64_C(32768), "default record block count");
  require(l.maximumSingleRecordBlockCompressedBytes == UINT64_C(16777216), "default single record compressed");
  require(l.maximumSingleRecordBlockDecompressedBytes == UINT64_C(33554432), "default single record decompressed");
  require(l.maximumTotalRecordBlockCompressedBytes == UINT64_C(2147483648), "default total record compressed");
  require(l.maximumTotalRecordBlockDecompressedBytes == UINT64_C(8589934592), "default total record decompressed");
  require(l.maximumRecordRangeBytes == UINT64_C(8388608), "default record range");
  require(l.maximumReturnedRecordBytes == UINT64_C(8388608), "default returned record");
  require(l.indexingCancellationInterval == UINT32_C(256), "default cancellation interval");
  l.validate();
  require(true, "all production defaults validate");
  std::fprintf(stderr, "  production defaults (all 20 fields): PASS\n");
}

void testCheckedArithmetic() {
  using namespace mdict;
  require(checkedAddUInt64(4, 5) == 9, "add normal");
  require(checkedAddUInt64(UINT64_MAX, 0) == UINT64_MAX, "add boundary");
  expectCode(ResourceErrorCode::arithmeticOverflow, "add overflow", [] { (void)checkedAddUInt64(UINT64_MAX, 1); });
  require(checkedSubtractUInt64(9, 4) == 5, "subtract normal");
  require(checkedSubtractUInt64(0, 0) == 0, "subtract boundary");
  expectCode(ResourceErrorCode::arithmeticOverflow, "subtract underflow", [] { (void)checkedSubtractUInt64(0, 1); });
  require(checkedMultiplyUInt64(6, 7) == 42, "multiply normal");
  require(checkedMultiplyUInt64(UINT64_MAX, 1) == UINT64_MAX, "multiply boundary");
  expectCode(ResourceErrorCode::arithmeticOverflow, "multiply overflow", [] { (void)checkedMultiplyUInt64(UINT64_MAX, 2); });

  require(checkedUInt64ToSizeT(7) == 7, "size_t normal");
  require(checkedUInt64ToSizeT(static_cast<uint64_t>(std::numeric_limits<size_t>::max())) ==
              std::numeric_limits<size_t>::max(), "size_t boundary");
  if (std::numeric_limits<size_t>::max() < UINT64_MAX) {
    expectCode(ResourceErrorCode::numericConversionOverflow, "size_t overflow", [] {
      (void)checkedUInt64ToSizeT(static_cast<uint64_t>(std::numeric_limits<size_t>::max()) + 1);
    });
  } else {
    require(sizeof(size_t) == sizeof(uint64_t), "size_t has no representable uint64 over-limit on arm64");
  }

  const auto offMax = static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max());
  require(checkedUInt64ToStreamoff(7) == 7, "streamoff normal");
  require(checkedUInt64ToStreamoff(offMax) == std::numeric_limits<std::streamoff>::max(), "streamoff boundary");
  expectCode(ResourceErrorCode::numericConversionOverflow, "streamoff overflow", [] {
    (void)checkedUInt64ToStreamoff(
        static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max()) + 1);
  });
  const auto sizeMax = static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max());
  require(checkedUInt64ToStreamSize(7) == 7, "streamsize normal");
  require(checkedUInt64ToStreamSize(sizeMax) == std::numeric_limits<std::streamsize>::max(), "streamsize boundary");
  expectCode(ResourceErrorCode::numericConversionOverflow, "streamsize overflow", [] {
    (void)checkedUInt64ToStreamSize(
        static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max()) + 1);
  });
  const auto intMax = static_cast<uint64_t>(std::numeric_limits<int>::max());
  require(checkedUInt64ToInt(7) == 7, "int normal");
  require(checkedUInt64ToInt(intMax) == std::numeric_limits<int>::max(), "int boundary");
  expectCode(ResourceErrorCode::numericConversionOverflow, "int overflow", [] {
    (void)checkedUInt64ToInt(
        static_cast<uint64_t>(std::numeric_limits<int>::max()) + 1);
  });
  std::fprintf(stderr, "  checked arithmetic (all 7 helpers): PASS\n");
}

void testBaselineIntegrity(const std::string &directory) {
  FixtureSpec spec;
  spec.blocks = {oneBlock({{"alpha"}, {"omega"}}, 2)};
  const std::string validPath = storeFixture(directory, "baseline.mdx", spec);
  mdict::Mdict valid(validPath, smallLimits());
  valid.init();
  require(valid.keyList().size() == 2, "baseline full parser key count");

  BuiltFixture badHeader = buildFixture(spec);
  const uint32_t headerSize = readBE32(badHeader.bytes.data());
  badHeader.bytes[4 + headerSize] ^= 0x01;
  const std::string badHeaderPath = directory + "/bad-header-checksum.mdx";
  writeFixture(badHeaderPath, badHeader);
  expectCode(ResourceErrorCode::checksumMismatch, "header checksum exact code", [&] {
    mdict::Mdict dictionary(badHeaderPath, smallLimits());
    dictionary.initMetadataOnly();
  });

  BlockSpec badBlock = oneBlock({{"alpha"}}, 1);
  badBlock.wrongAdler = true;
  FixtureSpec badBlockSpec;
  badBlockSpec.blocks = {badBlock};
  const std::string badBlockPath = storeFixture(
      directory, "bad-zlib-block-adler.mdx", badBlockSpec);
  expectCode(ResourceErrorCode::checksumMismatch, "type-2 external Adler exact code", [&] {
    mdict::Mdict dictionary(badBlockPath, smallLimits());
    dictionary.init();
  });
  std::fprintf(stderr, "  baseline header and block integrity: PASS\n");
}

void testRealKeyBlockCount(const std::string &directory) {
  FixtureSpec spec;
  spec.blocks = {oneBlock({{"alpha"}}, 1), oneBlock({{"beta"}}, 1)};
  const std::string path = storeFixture(directory, "two-real-blocks.mdx", spec);

  auto atLimit = smallLimits();
  atLimit.maximumKeyBlockCount = 2;
  mdict::Mdict accepted(path, atLimit);
  accepted.init();
  require(accepted.keyBlockCount() == 2, "two physical key blocks at limit");
  require(accepted.keyList().size() == 2, "two physical key blocks decoded");

  auto overLimit = atLimit;
  overLimit.maximumKeyBlockCount = 1;
  expectCode(ResourceErrorCode::keyBlockCountTooLarge,
             "two physical blocks exceed block-count limit", [&] {
    mdict::Mdict rejected(path, overLimit);
    rejected.initMetadataOnly();
  });
  std::fprintf(stderr, "  real two-block count limit: PASS\n");
}

void testEntryCounts(const std::string &directory) {
  FixtureSpec twoEntries;
  twoEntries.blocks = {oneBlock({{"alpha"}, {"beta"}}, 2)};
  const std::string atPath = storeFixture(directory, "entry-at-limit.mdx", twoEntries);
  auto limitTwo = smallLimits();
  limitTwo.maximumEntryCount = 2;
  {
    mdict::Mdict accepted(atPath, limitTwo);
    accepted.init();
    require(accepted.keyList().size() == 2,
            "declared and actual entry count at limit");
    require(accepted.keyBlockInfoList().front()->declared_entry_count == 2,
            "per-block declared entry count retained in metadata");
  }

  auto limitOne = smallLimits();
  limitOne.maximumEntryCount = 1;
  expectCode(ResourceErrorCode::entryCountTooLarge,
             "header declared entry count above limit", [&] {
    mdict::Mdict rejected(atPath, limitOne);
    rejected.initMetadataOnly();
  });

  FixtureSpec actualMore;
  actualMore.blocks = {oneBlock({{"alpha"}, {"beta"}}, 1)};
  actualMore.headerEntryCount = 1;
  const std::string actualMorePath =
      storeFixture(directory, "actual-more-than-declared.mdx", actualMore);
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "actual block count exceeds per-block declaration", [&] {
    mdict::Mdict rejected(actualMorePath, smallLimits());
    rejected.init();
  });
  mdict::Mdict actualMoreQuery(actualMorePath, smallLimits());
  actualMoreQuery.initMetadataOnly();
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "query path checks actual count against block declaration", [&] {
    (void)actualMoreQuery.decode_key_block_by_block_id(0);
  });

  FixtureSpec actualLess;
  actualLess.blocks = {oneBlock({{"alpha"}}, 2)};
  actualLess.headerEntryCount = 2;
  const std::string actualLessPath =
      storeFixture(directory, "actual-less-than-declared.mdx", actualLess);
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "actual block count below per-block declaration", [&] {
    mdict::Mdict rejected(actualLessPath, smallLimits());
    rejected.init();
  });

  FixtureSpec exactAcrossBlocks;
  exactAcrossBlocks.blocks = {oneBlock({{"alpha"}}, 1),
                              oneBlock({{"beta"}}, 1)};
  const std::string exactAcrossPath =
      storeFixture(directory, "actual-global-at-limit.mdx", exactAcrossBlocks);
  {
    mdict::Mdict exactAcross(exactAcrossPath, limitTwo);
    exactAcross.init();
    require(exactAcross.keyList().size() == 2,
            "actual accumulator exactly maximumEntryCount");
  }

  FixtureSpec actualOverGlobal;
  actualOverGlobal.blocks = {
      oneBlock({{"alpha"}, {"beta"}, {"gamma"}}, 2)};
  actualOverGlobal.headerEntryCount = 2;
  const std::string actualOverPath =
      storeFixture(directory, "actual-global-over-limit.mdx", actualOverGlobal);
  expectCode(ResourceErrorCode::entryCountTooLarge,
             "actual maximumEntryCount plus one rejected before object commit", [&] {
    mdict::Mdict rejected(actualOverPath, limitTwo);
    rejected.init();
  });

  FixtureSpec mismatchSecondBlock;
  mismatchSecondBlock.blocks = {oneBlock({{"alpha"}}, 1),
                                oneBlock({{"beta"}}, 2)};
  mismatchSecondBlock.headerEntryCount = 3;
  const std::string mismatchSecondPath =
      storeFixture(directory, "second-block-declared-mismatch.mdx", mismatchSecondBlock);
  mdict::resetResourceTestObserver();
  mdict::Mdict mismatchSecond(mismatchSecondPath, smallLimits());
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "second block actual count differs from declaration", [&] {
    mismatchSecond.init();
  });
  require(mismatchSecond.keyList().empty(), "failed full decode commits no member keys");
  require(mdict::resourceTestObserverSnapshot().keyItemLiveCount == 0,
          "failed full decode releases prior-block key items");
  std::fprintf(stderr, "  actual and declared entry counts: PASS\n");
}

void deleteReturnedKeys(std::vector<mdict::key_list_item *> &items) {
  for (auto *item : items) delete item;
  items.clear();
}

void testTypeZero(const std::string &directory) {
  BlockSpec block = oneBlock({{"assemble"}}, 1, 0);
  FixtureSpec spec;
  spec.blocks = {block};
  const std::string path = storeFixture(directory, "real-type-zero.mdx", spec);

  {
    mdict::Mdict full(path, smallLimits());
    full.init();
    require(full.keyList().size() == 1, "type-0 full decode count");
    require(full.keyList().front()->key_word == "assemble",
            "type-0 full decode key");
  }

  mdict::Mdict queried(path, smallLimits());
  queried.initMetadataOnly();
  auto keys = queried.decode_key_block_by_block_id(0);
  require(keys.size() == 1, "type-0 by-block query count");
  require(keys.front()->key_word == "assemble", "type-0 by-block query key");
  deleteReturnedKeys(keys);

  BlockSpec bad = block;
  bad.wrongAdler = true;
  FixtureSpec badSpec;
  badSpec.blocks = {bad};
  const std::string badPath = storeFixture(directory, "real-type-zero-bad-adler.mdx", badSpec);
  expectCode(ResourceErrorCode::checksumMismatch, "type-0 full Adler", [&] {
    mdict::Mdict dictionary(badPath, smallLimits());
    dictionary.init();
  });
  mdict::Mdict badQuery(badPath, smallLimits());
  badQuery.initMetadataOnly();
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::checksumMismatch, "type-0 query Adler", [&] {
    (void)badQuery.decode_key_block_by_block_id(0);
  });
  require(mdict::resourceTestObserverSnapshot().keyItemLiveCount == 0,
          "type-0 returned ownership released");
  std::fprintf(stderr, "  real type-0 full/query and Adler: PASS\n");
}

void testCompressionPrefixes(const std::string &directory) {
  const std::array<std::array<uint8_t, 4>, 4> invalidPrefixes{{
      {{0, 1, 0, 0}}, {{0, 0, 1, 0}}, {{2, 1, 0, 0}}, {{2, 0, 1, 0}}}};
  for (size_t index = 0; index < invalidPrefixes.size(); ++index) {
    BlockSpec block = oneBlock({{"alpha"}}, 1);
    block.compressionPrefix = invalidPrefixes[index];
    FixtureSpec spec;
    spec.blocks = {block};
    const std::string name = "invalid-prefix-" + std::to_string(index) + ".mdx";
    const std::string path = storeFixture(directory, name.c_str(), spec);
    expectCode(ResourceErrorCode::invalidCompressionType,
               "full decoder rejects noncanonical four-byte prefix", [&] {
      mdict::Mdict dictionary(path, smallLimits());
      dictionary.init();
    });
    mdict::Mdict query(path, smallLimits());
    query.initMetadataOnly();
    expectCode(ResourceErrorCode::invalidCompressionType,
               "query decoder rejects noncanonical four-byte prefix", [&] {
      (void)query.decode_key_block_by_block_id(0);
    });
  }

  BlockSpec emptyPayload = oneBlock({{"alpha"}}, 1, 0);
  emptyPayload.metadataCompressedSize = 8;
  FixtureSpec emptySpec;
  emptySpec.blocks = {emptyPayload};
  emptySpec.headerKeyBlockSize = 8;
  const std::string emptyPath = storeFixture(directory, "empty-key-payload.mdx", emptySpec);
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "comp_size 8 rejected by full path", [&] {
    mdict::Mdict dictionary(emptyPath, smallLimits());
    dictionary.init();
  });

  FixtureSpec querySpec;
  querySpec.blocks = {oneBlock({{"alpha"}}, 1, 0)};
  const std::string queryPath =
      storeFixture(directory, "empty-query-payload.mdx", querySpec);
  mdict::Mdict query(queryPath, smallLimits());
  query.initMetadataOnly();
  query.keyBlockInfoList().front()->key_block_comp_size = 8;
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "comp_size 8 rejected by query path", [&] {
    (void)query.decode_key_block_by_block_id(0);
  });
  std::fprintf(stderr, "  canonical four-byte compression prefixes: PASS\n");
}

void testSingleBlockCompressedSizes(const std::string &directory) {
  for (uint64_t size : {UINT64_C(0), UINT64_C(1), UINT64_C(7), UINT64_C(8)}) {
    BlockSpec block = oneBlock({{"alpha"}}, 1, 0);
    block.metadataCompressedSize = size;
    FixtureSpec spec;
    spec.blocks = {block};
    spec.headerKeyBlockSize = size == 0 ? 1 : size;
    const std::string name = "metadata-comp-size-" + std::to_string(size) + ".mdx";
    const std::string path = storeFixture(directory, name.c_str(), spec);
    expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
               "per-block comp_size 0/1/7/8 exact rejection", [&] {
      mdict::Mdict dictionary(path, smallLimits());
      dictionary.initMetadataOnly();
    });
  }

  FixtureSpec normalSpec;
  normalSpec.blocks = {oneBlock({{"alpha"}}, 1, 0)};
  BuiltFixture normal = buildFixture(normalSpec);
  const std::string normalPath = directory + "/metadata-comp-size-normal.mdx";
  writeFixture(normalPath, normal);
  auto atLimit = smallLimits();
  atLimit.maximumSingleKeyBlockCompressedBytes = normal.actualCompressedSizes[0];
  atLimit.maximumTotalKeyBlockCompressedBytes = normal.actualCompressedSizes[0];
  atLimit.validate();
  mdict::Mdict accepted(normalPath, atLimit);
  accepted.init();
  require(accepted.keyList().size() == 1, "normal comp_size at exact upper limit");

  auto overLimit = atLimit;
  overLimit.maximumSingleKeyBlockCompressedBytes =
      normal.actualCompressedSizes[0] - 1;
  overLimit.validate();
  expectCode(ResourceErrorCode::singleKeyBlockCompressedTooLarge,
             "per-block comp_size upper limit plus one", [&] {
    mdict::Mdict rejected(normalPath, overLimit);
    rejected.initMetadataOnly();
  });
  std::fprintf(stderr, "  real per-block compressed-size matrix: PASS\n");
}

mdict::ResourceLimits maximalKeyLimits() {
  auto limits = mdict::ResourceLimits::productionDefaults();
  limits.maximumFileBytes = UINT64_MAX;
  limits.maximumKeyBlockInfoCompressedBytes = UINT64_C(1048576);
  limits.maximumKeyBlockInfoDecompressedBytes = UINT64_C(4194304);
  limits.maximumSingleKeyBlockCompressedBytes = UINT64_MAX;
  limits.maximumSingleKeyBlockDecompressedBytes = UINT64_MAX;
  limits.maximumTotalKeyBlockCompressedBytes = UINT64_MAX;
  limits.maximumTotalKeyBlockDecompressedBytes = UINT64_MAX;
  limits.validate();
  return limits;
}

void testCumulativeMetadata(const std::string &directory) {
  {
    BlockSpec first = oneBlock({{"a"}}, 1);
    BlockSpec second = oneBlock({{"b"}}, 1);
    first.metadataCompressedSize = UINT64_MAX - 8;
    second.metadataCompressedSize = 16;
    first.metadataDecompressedSize = 16;
    second.metadataDecompressedSize = 16;
    FixtureSpec spec;
    spec.blocks = {first, second};
    spec.headerKeyBlockSize = 16;
    const std::string path = storeFixture(directory, "cumulative-comp-overflow.mdx", spec);
    expectCode(ResourceErrorCode::arithmeticOverflow,
               "cumulative compressed checked-add overflow", [&] {
      mdict::Mdict dictionary(path, maximalKeyLimits());
      dictionary.initMetadataOnly();
    });
  }
  {
    BlockSpec first = oneBlock({{"a"}}, 1);
    BlockSpec second = oneBlock({{"b"}}, 1);
    first.metadataCompressedSize = 9;
    second.metadataCompressedSize = 9;
    first.metadataDecompressedSize = UINT64_MAX - 8;
    second.metadataDecompressedSize = 16;
    FixtureSpec spec;
    spec.blocks = {first, second};
    spec.headerKeyBlockSize = 18;
    const std::string path = storeFixture(directory, "cumulative-decomp-overflow.mdx", spec);
    expectCode(ResourceErrorCode::arithmeticOverflow,
               "cumulative decompressed checked-add overflow", [&] {
      mdict::Mdict dictionary(path, maximalKeyLimits());
      dictionary.initMetadataOnly();
    });
  }
  {
    BlockSpec first = oneBlock({{"a"}}, 1);
    BlockSpec second = oneBlock({{"b"}}, 1);
    first.metadataCompressedSize = 12;
    second.metadataCompressedSize = 12;
    first.metadataDecompressedSize = 12;
    second.metadataDecompressedSize = 12;
    FixtureSpec spec;
    spec.blocks = {first, second};
    spec.headerKeyBlockSize = 20;
    const std::string path = storeFixture(directory, "cumulative-comp-limit.mdx", spec);
    auto limits = smallLimits();
    limits.maximumSingleKeyBlockCompressedBytes = 20;
    limits.maximumTotalKeyBlockCompressedBytes = 20;
    limits.validate();
    expectCode(ResourceErrorCode::totalKeyBlockCompressedTooLarge,
               "cumulative compressed total cap", [&] {
      mdict::Mdict dictionary(path, limits);
      dictionary.initMetadataOnly();
    });
  }
  {
    BlockSpec first = oneBlock({{"a"}}, 1);
    BlockSpec second = oneBlock({{"b"}}, 1);
    first.metadataCompressedSize = 9;
    second.metadataCompressedSize = 9;
    first.metadataDecompressedSize = 130;
    second.metadataDecompressedSize = 130;
    FixtureSpec spec;
    spec.blocks = {first, second};
    spec.headerKeyBlockSize = 18;
    const std::string path = storeFixture(directory, "cumulative-decomp-limit.mdx", spec);
    auto limits = smallLimits();
    limits.maximumKeyBlockInfoDecompressedBytes = 256;
    limits.maximumSingleKeyBlockDecompressedBytes = 256;
    limits.maximumTotalKeyBlockDecompressedBytes = 256;
    limits.validate();
    expectCode(ResourceErrorCode::totalKeyBlockDecompressedTooLarge,
               "cumulative decompressed total cap", [&] {
      mdict::Mdict dictionary(path, limits);
      dictionary.initMetadataOnly();
    });
  }
  {
    BlockSpec first = oneBlock({{"a"}}, 1);
    BlockSpec second = oneBlock({{"b"}}, 1);
    first.metadataCompressedSize = 9;
    second.metadataCompressedSize = 9;
    first.metadataDecompressedSize = 12;
    second.metadataDecompressedSize = 12;
    FixtureSpec spec;
    spec.blocks = {first, second};
    spec.headerKeyBlockSize = 19;
    const std::string path = storeFixture(directory, "cumulative-header-mismatch.mdx", spec);
    expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
               "cumulative compressed size differs from header", [&] {
      mdict::Mdict dictionary(path, smallLimits());
      dictionary.initMetadataOnly();
    });
  }
  std::fprintf(stderr, "  real cumulative metadata arithmetic: PASS\n");
}

void assertMalformedOwnership(const std::string &path,
                              mdict::ResourceLimits limits,
                              const char *message) {
  mdict::resetResourceTestObserver();
  mdict::Mdict dictionary(path, limits);
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata, message, [&] {
    dictionary.init();
  });
  require(dictionary.keyList().empty(), "malformed block commits no member key");
  require(mdict::resourceTestObserverSnapshot().keyItemLiveCount == 0,
          "malformed block releases every temporary key item");
}

void testMalformedOwnership(const std::string &directory) {
  FixtureSpec missingDelimiter;
  missingDelimiter.blocks = {
      oneBlock({{"first"}, {"second", false}}, 2, 0)};
  assertMalformedOwnership(
      storeFixture(directory, "second-missing-delimiter.mdx", missingDelimiter),
      smallLimits(), "second key missing delimiter");

  FixtureSpec oversizedSecond;
  oversizedSecond.blocks = {
      oneBlock({{"one"}, {"second-is-too-long"}}, 2, 0)};
  auto tinyKeyLimit = smallLimits();
  tinyKeyLimit.maximumSingleKeyBytes = 3;
  assertMalformedOwnership(
      storeFixture(directory, "second-key-over-limit.mdx", oversizedSecond),
      tinyKeyLimit, "second key exceeds maximumSingleKeyBytes");

  FixtureSpec trailingUTF16;
  trailingUTF16.encoding = FixtureEncoding::utf16;
  trailingUTF16.blocks = {
      oneBlock({{"one"}, {"", false, true}}, 2, 0)};
  assertMalformedOwnership(
      storeFixture(directory, "second-utf16-single-byte.mdx", trailingUTF16),
      smallLimits(), "second UTF-16 key ends with one byte");

  FixtureSpec malformedLast;
  malformedLast.blocks = {
      oneBlock({{"one"}, {"two"}, {"three"}, {"last", false}}, 4, 0)};
  assertMalformedOwnership(
      storeFixture(directory, "last-key-malformed.mdx", malformedLast),
      smallLimits(), "last key malformed after several valid keys");
  std::fprintf(stderr, "  malformed key ownership rollback: PASS\n");
}

void testUTF16(const std::string &directory) {
  FixtureSpec valid;
  valid.encoding = FixtureEncoding::utf16;
  valid.blocks = {oneBlock({{"ab"}}, 1, 0)};
  const std::string validPath = storeFixture(directory, "utf16-valid.mdx", valid);
  auto exact = smallLimits();
  exact.maximumSingleKeyBytes = 4;
  {
    mdict::Mdict accepted(validPath, exact);
    accepted.init();
    require(accepted.keyList().size() == 1,
            "UTF-16 double-zero delimiter accepted");
    require(!accepted.keyList().front()->key_word.empty(),
            "UTF-16 decoded key nonempty");
  }

  auto below = exact;
  below.maximumSingleKeyBytes = 3;
  expectCode(ResourceErrorCode::malformedKeyBlockMetadata,
             "UTF-16 key above maximum bytes", [&] {
    mdict::Mdict rejected(validPath, below);
    rejected.init();
  });

  FixtureSpec noDelimiter;
  noDelimiter.encoding = FixtureEncoding::utf16;
  noDelimiter.blocks = {oneBlock({{"ab", false}}, 1, 0)};
  assertMalformedOwnership(
      storeFixture(directory, "utf16-no-delimiter.mdx", noDelimiter),
      smallLimits(), "UTF-16 key has no double-zero delimiter");

  FixtureSpec singleByte;
  singleByte.encoding = FixtureEncoding::utf16;
  singleByte.blocks = {oneBlock({{"", false, true}}, 1, 0)};
  assertMalformedOwnership(
      storeFixture(directory, "utf16-trailing-byte.mdx", singleByte),
      smallLimits(), "UTF-16 key has final single byte");
  std::fprintf(stderr, "  real UTF-16 key matrix: PASS\n");
}

void testObservers(const std::string &directory) {
  FixtureSpec spec;
  spec.blocks = {oneBlock({{"alpha"}}, 1)};
  BuiltFixture truncated = buildFixture(spec);
  truncated.bytes.resize(truncated.keyBodyOffset);
  const std::string truncatedPath = directory + "/truncated-before-key-buffer.mdx";
  writeFixture(truncatedPath, truncated);
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::truncatedFile,
             "truncated EOF rejected before key input allocation", [&] {
    mdict::Mdict dictionary(truncatedPath, smallLimits());
    dictionary.init();
  });
  require(mdict::resourceTestObserverSnapshot().inputBufferAllocationCount == 0,
          "truncated key body allocated no input buffer");

  BuiltFixture valid = buildFixture(spec);
  const std::string validPath = directory + "/observer-valid.mdx";
  writeFixture(validPath, valid);
  mdict::Mdict decompQuery(validPath, smallLimits());
  decompQuery.initMetadataOnly();
  auto &decompLimits = const_cast<mdict::ResourceLimits &>(decompQuery.resourceLimits());
  decompLimits.maximumSingleKeyBlockDecompressedBytes =
      valid.actualDecompressedSizes[0] - 1;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::singleKeyBlockDecompressedTooLarge,
             "decompressed cap precedes output allocation", [&] {
    (void)decompQuery.decode_key_block_by_block_id(0);
  });
  auto snapshot = mdict::resourceTestObserverSnapshot();
  require(snapshot.inputBufferAllocationCount == 0,
          "decompressed cap precedes input allocation");
  require(snapshot.outputBufferAllocationCount == 0,
          "decompressed cap precedes output allocation");
  require(snapshot.uncompressCallCount == 0,
          "decompressed cap precedes uncompress");

  mdict::Mdict compQuery(validPath, smallLimits());
  compQuery.initMetadataOnly();
  auto &compLimits = const_cast<mdict::ResourceLimits &>(compQuery.resourceLimits());
  compLimits.maximumSingleKeyBlockCompressedBytes =
      valid.actualCompressedSizes[0] - 1;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::singleKeyBlockCompressedTooLarge,
             "compressed cap precedes uncompress", [&] {
    (void)compQuery.decode_key_block_by_block_id(0);
  });
  snapshot = mdict::resourceTestObserverSnapshot();
  require(snapshot.inputBufferAllocationCount == 0,
          "compressed cap precedes input allocation");
  require(snapshot.outputBufferAllocationCount == 0,
          "compressed cap precedes output allocation");
  require(snapshot.uncompressCallCount == 0,
          "compressed cap precedes uncompress call");
  std::fprintf(stderr, "  allocation/uncompress/live-item observers: PASS\n");
}

void testBoundedZlibAndErrors() {
  const uint8_t byte = 0;
  expectCode(ResourceErrorCode::invalidCompressionType,
             "bounded zlib rejects null source", [] {
    (void)mdict::boundedExactZlibDecompress(nullptr, 1, 1);
  });
  expectCode(ResourceErrorCode::invalidCompressionType,
             "bounded zlib rejects zero source length", [&] {
    (void)mdict::boundedExactZlibDecompress(&byte, 0, 1);
  });
  expectCode(ResourceErrorCode::malformedCompressedData,
             "bounded zlib maps malformed bytes exactly", [&] {
    (void)mdict::boundedExactZlibDecompress(&byte, 1, 1);
  });
  const ResourceException sanitized(ResourceErrorCode::entryCountTooLarge);
  const std::string message = sanitized.what();
  require(message.find('/') == std::string::npos, "resource errors contain no path");
  require(message.find("alpha") == std::string::npos,
          "resource errors contain no key text");
  std::fprintf(stderr, "  bounded zlib and sanitized errors: PASS\n");
}

void testResourceLimitValidation() {
  auto limits = mdict::ResourceLimits::productionDefaults();
  limits.maximumEntryCount = 0;
  expectCode(ResourceErrorCode::invalidResourceLimits,
             "zero ResourceLimits field rejected", [&] { limits.validate(); });
  limits = mdict::ResourceLimits::productionDefaults();
  limits.maximumSingleKeyBlockCompressedBytes =
      limits.maximumTotalKeyBlockCompressedBytes + 1;
  expectCode(ResourceErrorCode::invalidResourceLimits,
             "invalid ResourceLimits cross-relation rejected", [&] {
    limits.validate();
  });
  std::fprintf(stderr, "  ResourceLimits validation: PASS\n");
}

}  // namespace

int main() {
  char directoryTemplate[] = "/tmp/localdictionary-d1b3a2a-r2.XXXXXX";
  char *created = mkdtemp(directoryTemplate);
  require(created != nullptr, "create isolated synthetic test directory");
  const std::string directory(created);

  std::fprintf(stderr, "D1b3A2AResourceLimitsSmoke-R2\n");
  testProductionDefaults();
  testResourceLimitValidation();
  testCheckedArithmetic();
  testBaselineIntegrity(directory);
  testRealKeyBlockCount(directory);
  testEntryCounts(directory);
  testTypeZero(directory);
  testCompressionPrefixes(directory);
  testSingleBlockCompressedSizes(directory);
  testCumulativeMetadata(directory);
  testMalformedOwnership(directory);
  testUTF16(directory);
  testObservers(directory);
  testBoundedZlibAndErrors();

  std::filesystem::remove_all(directory);
  std::fprintf(stderr,
               "\nD1b3A2AResourceLimitsSmoke-R2: %d checks PASSED\n",
               g_checks);
  return 0;
}
