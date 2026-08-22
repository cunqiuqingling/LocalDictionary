// D1b-3A-2B-R1 synthetic Record metadata and bounded decoder smoke.
// It uses no private dictionaries, configuration, Application Support, network,
// or Keychain state.

#include "mdict.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

#include "miniz/miniz.h"

#ifndef MDICT_RESOURCE_TEST_OBSERVER
#error "Record smoke requires MDICT_RESOURCE_TEST_OBSERVER"
#endif

namespace {
using mdict::ResourceErrorCode;
using mdict::ResourceException;
using mdict::ResourceTestAllocationFailPoint;

int g_checks = 0;

void require(bool value, const char *message) {
  if (!value) {
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
    require(error.code() == expected, message);
    return;
  }
  std::fprintf(stderr, "FAIL: %s (no exception)\n", message);
  std::exit(1);
}

void be32(std::vector<uint8_t> &out, uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) {
    out.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void le32(std::vector<uint8_t> &out, uint32_t value) {
  for (int shift = 0; shift <= 24; shift += 8) {
    out.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void be64(std::vector<uint8_t> &out, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    out.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void overwrite64(std::vector<uint8_t> &out, size_t offset, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    out[offset++] = static_cast<uint8_t>((value >> shift) & 0xff);
  }
}

uint32_t adler(const std::vector<uint8_t> &data) {
  return static_cast<uint32_t>(
      mz_adler32(MZ_ADLER32_INIT, data.data(), data.size()));
}

std::vector<uint8_t> zlibCompress(const std::vector<uint8_t> &input) {
  const mz_ulong capacity = mz_compressBound(input.size());
  std::vector<uint8_t> output(capacity);
  mz_ulong length = capacity;
  require(mz_compress(output.data(), &length, input.data(), input.size()) ==
              MZ_OK,
          "synthetic zlib compression");
  output.resize(length);
  return output;
}

void appendUTF16LE(std::vector<uint8_t> &out, const std::string &text) {
  for (unsigned char c : text) {
    out.push_back(c);
    out.push_back(0);
  }
}

struct Fixture {
  std::vector<uint8_t> bytes;
  size_t recordSummaryOffset = 0;
  size_t recordInfoOffset = 0;
  std::vector<size_t> recordPairOffsets;
  std::vector<size_t> recordBlockOffsets;
  std::vector<uint64_t> compressedSizes;
  std::vector<uint64_t> decompressedSizes;
};

Fixture fixture(const std::vector<std::vector<uint8_t>> &records,
                bool zlib = false) {
  const std::string xml =
      "<Dictionary GeneratedByEngineVersion=\"2.0\" "
      "RequiredEngineVersion=\"2.0\" Encrypted=\"No\" "
      "Encoding=\"UTF-8\"/>";
  std::vector<uint8_t> header;
  appendUTF16LE(header, xml);

  std::vector<uint8_t> keyraw;
  be64(keyraw, 0);
  keyraw.push_back('a');
  keyraw.push_back(0);
  std::vector<uint8_t> keyblock{0, 0, 0, 0};
  be32(keyblock, adler(keyraw));
  keyblock.insert(keyblock.end(), keyraw.begin(), keyraw.end());

  std::vector<uint8_t> keyinfo;
  be64(keyinfo, 1);
  keyinfo.push_back(0);
  keyinfo.push_back(1);
  keyinfo.push_back('a');
  keyinfo.push_back(0);
  keyinfo.push_back(0);
  keyinfo.push_back(1);
  keyinfo.push_back('a');
  keyinfo.push_back(0);
  be64(keyinfo, keyblock.size());
  be64(keyinfo, keyraw.size());
  const auto keyinfoPayload = zlibCompress(keyinfo);
  std::vector<uint8_t> keyinfoBlock{2, 0, 0, 0};
  be32(keyinfoBlock, adler(keyinfo));
  keyinfoBlock.insert(keyinfoBlock.end(), keyinfoPayload.begin(),
                      keyinfoPayload.end());

  std::vector<std::vector<uint8_t>> blocks;
  uint64_t totalCompressed = 0;
  for (const auto &raw : records) {
    const auto payload = zlib ? zlibCompress(raw) : raw;
    std::vector<uint8_t> block{static_cast<uint8_t>(zlib ? 2 : 0), 0, 0, 0};
    be32(block, adler(raw));
    block.insert(block.end(), payload.begin(), payload.end());
    totalCompressed += block.size();
    blocks.push_back(std::move(block));
  }

  std::vector<uint8_t> out;
  be32(out, header.size());
  out.insert(out.end(), header.begin(), header.end());
  le32(out, adler(header));
  std::vector<uint8_t> keyHeader;
  be64(keyHeader, 1);
  be64(keyHeader, 1);
  be64(keyHeader, keyinfo.size());
  be64(keyHeader, keyinfoBlock.size());
  be64(keyHeader, keyblock.size());
  out.insert(out.end(), keyHeader.begin(), keyHeader.end());
  be32(out, adler(keyHeader));
  out.insert(out.end(), keyinfoBlock.begin(), keyinfoBlock.end());
  out.insert(out.end(), keyblock.begin(), keyblock.end());

  Fixture result;
  result.recordSummaryOffset = out.size();
  be64(out, blocks.size());
  be64(out, 1);  // Key metadata has one synthetic entry.
  be64(out, blocks.size() * UINT64_C(16));
  be64(out, totalCompressed);
  result.recordInfoOffset = out.size();
  for (size_t index = 0; index < blocks.size(); ++index) {
    result.recordPairOffsets.push_back(out.size());
    result.compressedSizes.push_back(blocks[index].size());
    result.decompressedSizes.push_back(records[index].size());
    be64(out, blocks[index].size());
    be64(out, records[index].size());
  }
  for (const auto &block : blocks) {
    result.recordBlockOffsets.push_back(out.size());
    out.insert(out.end(), block.begin(), block.end());
  }
  result.bytes = std::move(out);
  return result;
}

uint64_t sum(const std::vector<uint64_t> &values) {
  uint64_t total = 0;
  for (uint64_t value : values) total += value;
  return total;
}

uint64_t maximum(const std::vector<uint64_t> &values) {
  return *std::max_element(values.begin(), values.end());
}

void setSummaryEntryCount(Fixture &value, uint64_t count) {
  overwrite64(value.bytes, value.recordSummaryOffset + 8, count);
}

void setSummaryInfoSize(Fixture &value, uint64_t size) {
  overwrite64(value.bytes, value.recordSummaryOffset + 16, size);
}

void setSummaryTotalCompressed(Fixture &value, uint64_t size) {
  overwrite64(value.bytes, value.recordSummaryOffset + 24, size);
}

void setPairCompressed(Fixture &value, size_t index, uint64_t size) {
  overwrite64(value.bytes, value.recordPairOffsets.at(index), size);
}

void setPairDecompressed(Fixture &value, size_t index, uint64_t size) {
  overwrite64(value.bytes, value.recordPairOffsets.at(index) + 8, size);
}

class TempFixture final {
 public:
  explicit TempFixture(const Fixture &fixture) {
    char templatePath[] = "/tmp/LocalDictionary-D1b3A2B-XXXXXX";
    const int descriptor = mkstemp(templatePath);
    require(descriptor >= 0, "create synthetic fixture");
    close(descriptor);
    path_ = templatePath;
    std::ofstream stream(path_, std::ios::binary);
    require(stream.good(), "open synthetic fixture");
    stream.write(reinterpret_cast<const char *>(fixture.bytes.data()),
                 static_cast<std::streamsize>(fixture.bytes.size()));
    require(stream.good(), "write synthetic fixture");
  }

  ~TempFixture() { std::remove(path_.c_str()); }

  TempFixture(const TempFixture &) = delete;
  TempFixture &operator=(const TempFixture &) = delete;

  const std::string &path() const { return path_; }

 private:
  std::string path_;
};

void runMetadata(const Fixture &value, const mdict::ResourceLimits &limits) {
  TempFixture temporary(value);
  mdict::Mdict dictionary(temporary.path(), limits);
  dictionary.initMetadataOnly();
}

void runRead(const Fixture &value, const mdict::ResourceLimits &limits,
             uint64_t start, uint64_t end) {
  TempFixture temporary(value);
  mdict::Mdict dictionary(temporary.path(), limits);
  dictionary.initMetadataOnly();
  (void)dictionary.readRecordAt(start, end);
}

mdict::ResourceLimits recordExactLimits(const Fixture &value) {
  auto limits = mdict::ResourceLimits::productionDefaults();
  limits.maximumRecordBlockInfoBytes = value.recordPairOffsets.size() * 16;
  limits.maximumRecordBlockCount = value.recordPairOffsets.size();
  limits.maximumSingleRecordBlockCompressedBytes =
      maximum(value.compressedSizes);
  limits.maximumSingleRecordBlockDecompressedBytes =
      maximum(value.decompressedSizes);
  limits.maximumTotalRecordBlockCompressedBytes = sum(value.compressedSizes);
  limits.maximumTotalRecordBlockDecompressedBytes =
      sum(value.decompressedSizes);
  limits.maximumRecordRangeBytes = sum(value.decompressedSizes);
  limits.maximumReturnedRecordBytes = sum(value.decompressedSizes);
  return limits;
}

void testDefaults() {
  const auto defaults = mdict::ResourceLimits::productionDefaults();
  require(defaults.maximumRecordBlockInfoBytes == UINT64_C(524288),
          "record info default");
  require(defaults.maximumRecordBlockCount == UINT64_C(16384),
          "record count default");
  require(defaults.maximumSingleRecordBlockCompressedBytes == UINT64_C(1048576),
          "record compressed default");
  require(defaults.maximumSingleRecordBlockDecompressedBytes == UINT64_C(8388608),
          "record decompressed default");
  require(defaults.maximumTotalRecordBlockCompressedBytes == UINT64_C(268435456),
          "record total compressed default");
  require(defaults.maximumTotalRecordBlockDecompressedBytes == UINT64_C(1073741824),
          "record total decompressed default");
  require(defaults.maximumRecordRangeBytes == UINT64_C(524288),
          "record range default");
  require(defaults.maximumReturnedRecordBytes == UINT64_C(524288),
          "returned default");
}

void testSummaryLimitFirstAndMetadata() {
  const auto defaults = mdict::ResourceLimits::productionDefaults();
  const Fixture one = fixture({{'a', 'b', 'c'}});
  const Fixture two = fixture({{'a', 'b'}, {'c', 'd'}});

  auto infoExact = defaults;
  infoExact.maximumRecordBlockInfoBytes = 16;
  runMetadata(one, infoExact);
  auto infoOver = infoExact;
  infoOver.maximumRecordBlockInfoBytes = 15;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::recordBlockInfoTooLarge,
             "record info limit plus one", [&] { runMetadata(one, infoOver); });
  require(mdict::resourceTestObserverSnapshot()
              .recordBlockInfoInputBufferAllocationCount == 0,
          "record info rejection precedes info-table allocation");
  Fixture infoWithEntryMismatch = one;
  setSummaryEntryCount(infoWithEntryMismatch, 2);
  expectCode(ResourceErrorCode::recordBlockInfoTooLarge,
             "info limit wins over entry mismatch", [&] {
               runMetadata(infoWithEntryMismatch, infoOver);
             });

  auto countExact = defaults;
  countExact.maximumRecordBlockCount = 2;
  runMetadata(two, countExact);
  auto countOver = countExact;
  countOver.maximumRecordBlockCount = 1;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::recordBlockCountTooLarge,
             "record count limit plus one", [&] { runMetadata(two, countOver); });
  require(mdict::resourceTestObserverSnapshot()
              .recordBlockInfoInputBufferAllocationCount == 0,
          "record count rejection precedes info-table allocation");
  Fixture countWithEntryMismatch = two;
  setSummaryEntryCount(countWithEntryMismatch, 2);
  expectCode(ResourceErrorCode::recordBlockCountTooLarge,
             "count limit wins over entry mismatch", [&] {
               runMetadata(countWithEntryMismatch, countOver);
             });

  auto totalExact = recordExactLimits(two);
  runMetadata(two, totalExact);
  auto totalOver = totalExact;
  totalOver.maximumTotalRecordBlockCompressedBytes =
      sum(two.compressedSizes) - 1;
  expectCode(ResourceErrorCode::totalRecordBlockCompressedTooLarge,
             "total compressed limit plus one", [&] {
               runMetadata(two, totalOver);
             });
  Fixture totalWithEntryMismatch = two;
  setSummaryEntryCount(totalWithEntryMismatch, 2);
  setSummaryTotalCompressed(totalWithEntryMismatch,
                            sum(two.compressedSizes) + 1);
  expectCode(ResourceErrorCode::totalRecordBlockCompressedTooLarge,
             "total limit wins over entry mismatch", [&] {
               runMetadata(totalWithEntryMismatch, totalExact);
             });

  Fixture badShape = one;
  setSummaryInfoSize(badShape, 17);
  expectCode(ResourceErrorCode::malformedRecordBlockMetadata,
             "record pair-table shape is exact", [&] {
               runMetadata(badShape, defaults);
             });
  Fixture badTotal = one;
  setSummaryTotalCompressed(badTotal, 99);
  expectCode(ResourceErrorCode::malformedRecordBlockMetadata,
             "declared record total matches pairs", [&] {
               runMetadata(badTotal, defaults);
             });
}

void testBlockLimitsAndAccumulators() {
  const auto defaults = mdict::ResourceLimits::productionDefaults();
  const Fixture one = fixture({{'a', 'b', 'c'}});
  const Fixture two = fixture({{'a', 'b'}, {'c', 'd'}});

  auto singleCompressedExact = defaults;
  singleCompressedExact.maximumSingleRecordBlockCompressedBytes =
      one.compressedSizes[0];
  runMetadata(one, singleCompressedExact);
  auto singleCompressedOver = singleCompressedExact;
  singleCompressedOver.maximumSingleRecordBlockCompressedBytes =
      one.compressedSizes[0] - 1;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::singleRecordBlockCompressedTooLarge,
             "single compressed limit plus one", [&] {
               runMetadata(one, singleCompressedOver);
             });
  require(mdict::resourceTestObserverSnapshot().inputBufferAllocationCount == 0,
          "single compressed rejection precedes block input allocation");

  auto singleDecompressedExact = defaults;
  singleDecompressedExact.maximumSingleRecordBlockDecompressedBytes =
      one.decompressedSizes[0];
  runMetadata(one, singleDecompressedExact);
  auto singleDecompressedOver = singleDecompressedExact;
  singleDecompressedOver.maximumSingleRecordBlockDecompressedBytes =
      one.decompressedSizes[0] - 1;
  mdict::resetResourceTestObserver();
  runMetadata(one, defaults);
  const auto metadataBaseline = mdict::resourceTestObserverSnapshot();
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::singleRecordBlockDecompressedTooLarge,
             "single decompressed limit plus one", [&] {
               runMetadata(one, singleDecompressedOver);
             });
  auto snapshot = mdict::resourceTestObserverSnapshot();
  require(snapshot.outputBufferAllocationCount ==
              metadataBaseline.outputBufferAllocationCount,
          "single decompressed rejection adds no record output allocation");
  require(snapshot.uncompressCallCount == metadataBaseline.uncompressCallCount,
          "single decompressed rejection adds no record uncompress");

  auto totalCompressedExact = recordExactLimits(two);
  runMetadata(two, totalCompressedExact);
  auto totalCompressedOver = totalCompressedExact;
  totalCompressedOver.maximumTotalRecordBlockCompressedBytes =
      sum(two.compressedSizes) - 1;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::totalRecordBlockCompressedTooLarge,
             "total compressed limit plus one", [&] {
               runMetadata(two, totalCompressedOver);
             });
  require(mdict::resourceTestObserverSnapshot().inputBufferAllocationCount == 0,
          "cumulative compressed rejection precedes next block input allocation");

  auto totalDecompressedExact = recordExactLimits(two);
  runMetadata(two, totalDecompressedExact);
  auto totalDecompressedOver = totalDecompressedExact;
  totalDecompressedOver.maximumTotalRecordBlockDecompressedBytes =
      sum(two.decompressedSizes) - 1;
  mdict::resetResourceTestObserver();
  runMetadata(two, defaults);
  const auto twoBlockMetadataBaseline = mdict::resourceTestObserverSnapshot();
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::totalRecordBlockDecompressedTooLarge,
             "total decompressed limit plus one", [&] {
               runMetadata(two, totalDecompressedOver);
             });
  snapshot = mdict::resourceTestObserverSnapshot();
  require(snapshot.outputBufferAllocationCount ==
              twoBlockMetadataBaseline.outputBufferAllocationCount,
          "cumulative decompressed rejection adds no record output allocation");
  require(snapshot.uncompressCallCount ==
              twoBlockMetadataBaseline.uncompressCallCount,
          "cumulative decompressed rejection adds no record uncompress");

  Fixture compressedOverflow = two;
  setPairCompressed(compressedOverflow, 0,
                    std::numeric_limits<uint64_t>::max());
  setPairCompressed(compressedOverflow, 1, 8);
  setSummaryTotalCompressed(compressedOverflow,
                            std::numeric_limits<uint64_t>::max());
  auto overflowLimits = defaults;
  overflowLimits.maximumFileBytes = std::numeric_limits<uint64_t>::max();
  overflowLimits.maximumSingleRecordBlockCompressedBytes =
      std::numeric_limits<uint64_t>::max();
  overflowLimits.maximumTotalRecordBlockCompressedBytes =
      std::numeric_limits<uint64_t>::max();
  expectCode(ResourceErrorCode::arithmeticOverflow,
             "record compressed accumulator overflow", [&] {
               runMetadata(compressedOverflow, overflowLimits);
             });

  Fixture decompressedOverflow = two;
  setPairDecompressed(decompressedOverflow, 0,
                      std::numeric_limits<uint64_t>::max());
  setPairDecompressed(decompressedOverflow, 1, 1);
  auto decompOverflowLimits = overflowLimits;
  decompOverflowLimits.maximumSingleRecordBlockDecompressedBytes =
      std::numeric_limits<uint64_t>::max();
  decompOverflowLimits.maximumTotalRecordBlockDecompressedBytes =
      std::numeric_limits<uint64_t>::max();
  expectCode(ResourceErrorCode::arithmeticOverflow,
             "record decompressed accumulator overflow", [&] {
               runMetadata(decompressedOverflow, decompOverflowLimits);
             });
}

void testPrefixesChecksumsAndDecoders() {
  const auto defaults = mdict::ResourceLimits::productionDefaults();
  const Fixture type0 = fixture({{'a', 'b', 'c'}});
  const Fixture zlib = fixture({{'z', 'l', 'i', 'b'}}, true);

  for (uint64_t size : {UINT64_C(0), UINT64_C(1), UINT64_C(3), UINT64_C(4),
                        UINT64_C(7)}) {
    Fixture shortPrefix = type0;
    setPairCompressed(shortPrefix, 0, size);
    expectCode(ResourceErrorCode::malformedRecordBlockMetadata,
               "short record prefix rejected by metadata", [&] {
                 runMetadata(shortPrefix, defaults);
               });
  }

  Fixture emptyPayload = type0;
  setPairCompressed(emptyPayload, 0, 8);
  setSummaryTotalCompressed(emptyPayload, 8);
  expectCode(ResourceErrorCode::decompressedSizeMismatch,
             "eight-byte type-0 prefix with empty payload", [&] {
               runRead(emptyPayload, defaults, 0, 3);
             });

  runRead(type0, defaults, 0, 3);
  mdict::resetResourceTestObserver();
  runMetadata(zlib, defaults);
  const auto zlibMetadataOnly = mdict::resourceTestObserverSnapshot();
  mdict::resetResourceTestObserver();
  runRead(zlib, defaults, 0, 4);
  require(mdict::resourceTestObserverSnapshot().uncompressCallCount ==
              zlibMetadataOnly.uncompressCallCount + 1,
          "canonical zlib record adds one bounded uncompress");

  Fixture nonCanonical = type0;
  const size_t nonCanonicalOffset = nonCanonical.recordBlockOffsets[0];
  nonCanonical.bytes[nonCanonicalOffset + 0] = 0;
  nonCanonical.bytes[nonCanonicalOffset + 1] = 0;
  nonCanonical.bytes[nonCanonicalOffset + 2] = 0;
  nonCanonical.bytes[nonCanonicalOffset + 3] = 1;
  expectCode(ResourceErrorCode::invalidCompressionType,
             "non-canonical four-byte record prefix", [&] {
               runRead(nonCanonical, defaults, 0, 3);
             });

  Fixture typeOne = type0;
  typeOne.bytes[typeOne.recordBlockOffsets[0]] = 1;
  expectCode(ResourceErrorCode::invalidCompressionType,
             "unsupported record type one", [&] {
               runRead(typeOne, defaults, 0, 3);
             });

  Fixture type0SizeMismatch = type0;
  setPairDecompressed(type0SizeMismatch, 0, 4);
  expectCode(ResourceErrorCode::decompressedSizeMismatch,
             "type-0 payload size mismatch", [&] {
               runRead(type0SizeMismatch, defaults, 0, 4);
             });

  Fixture type0Checksum = type0;
  type0Checksum.bytes[type0Checksum.recordBlockOffsets[0] + 7] ^= 0x01;
  expectCode(ResourceErrorCode::checksumMismatch, "type-0 checksum mismatch",
             [&] { runRead(type0Checksum, defaults, 0, 3); });

  Fixture type0Truncated = type0;
  type0Truncated.bytes.pop_back();
  expectCode(ResourceErrorCode::truncatedFile, "type-0 EOF minus one byte",
             [&] { runRead(type0Truncated, defaults, 0, 3); });

  Fixture zlibMalformed = zlib;
  zlibMalformed.bytes[zlibMalformed.recordBlockOffsets[0] + 8] = 0;
  expectCode(ResourceErrorCode::malformedCompressedData,
             "malformed zlib record payload", [&] {
               runRead(zlibMalformed, defaults, 0, 4);
             });

  Fixture zlibSizeMismatch = zlib;
  setPairDecompressed(zlibSizeMismatch, 0, 5);
  expectCode(ResourceErrorCode::decompressedSizeMismatch,
             "zlib expected size mismatch", [&] {
               runRead(zlibSizeMismatch, defaults, 0, 5);
             });

  Fixture zlibChecksum = zlib;
  zlibChecksum.bytes[zlibChecksum.recordBlockOffsets[0] + 7] ^= 0x01;
  expectCode(ResourceErrorCode::checksumMismatch, "zlib checksum mismatch",
             [&] { runRead(zlibChecksum, defaults, 0, 4); });

  auto zlibTooSmall = defaults;
  zlibTooSmall.maximumSingleRecordBlockDecompressedBytes = 3;
  mdict::resetResourceTestObserver();
  runMetadata(zlib, defaults);
  const auto zlibMetadataBaseline = mdict::resourceTestObserverSnapshot();
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::singleRecordBlockDecompressedTooLarge,
             "zlib decompressed limit before uncompress", [&] {
               runMetadata(zlib, zlibTooSmall);
             });
  const auto snapshot = mdict::resourceTestObserverSnapshot();
  require(snapshot.outputBufferAllocationCount ==
              zlibMetadataBaseline.outputBufferAllocationCount,
          "zlib limit has no record output allocation");
  require(snapshot.uncompressCallCount == zlibMetadataBaseline.uncompressCallCount,
          "zlib limit has no record uncompress retry");
}

void testMetadataAtomicityAndAllocationFailures() {
  const auto defaults = mdict::ResourceLimits::productionDefaults();
  const Fixture valid = fixture({{'a', 'b', 'c'}});
  TempFixture temporary(valid);
  mdict::Mdict dictionary(temporary.path(), defaults);
  dictionary.initMetadataOnly();
  const auto *original = dictionary.recordHeaderList().front();
  require(dictionary.recordHeaderList().size() == 1,
          "metadata initial destination has one item");

  mdict::setResourceTestAllocationFailPoint(
      ResourceTestAllocationFailPoint::recordMetadataItem);
  expectCode(ResourceErrorCode::allocationFailed,
             "metadata item allocation maps bad_alloc", [&] {
               dictionary.read_record_block_header();
             });
  require(dictionary.recordHeaderList().size() == 1,
          "item allocation failure keeps destination size");
  require(dictionary.recordHeaderList().front() == original,
          "item allocation failure keeps destination pointer");

  mdict::setResourceTestAllocationFailPoint(
      ResourceTestAllocationFailPoint::recordMetadataCommit);
  expectCode(ResourceErrorCode::allocationFailed,
             "metadata commit allocation maps bad_alloc", [&] {
               dictionary.read_record_block_header();
             });
  require(dictionary.recordHeaderList().size() == 1,
          "commit allocation failure keeps destination size");
  require(dictionary.recordHeaderList().front() == original,
          "commit allocation failure keeps destination pointer");

  dictionary.read_record_block_header();
  require(dictionary.recordHeaderList().size() == 1,
          "successful retry replaces rather than appends metadata");
  dictionary.initMetadataOnly();
  require(dictionary.recordHeaderList().size() == 1,
          "repeat metadata initialization does not append");

  mdict::setResourceTestAllocationFailPoint(
      ResourceTestAllocationFailPoint::recordType0Output);
  expectCode(ResourceErrorCode::allocationFailed,
             "type-0 output allocation maps bad_alloc", [&] {
               (void)dictionary.readRecordAt(0, 3);
             });
  mdict::setResourceTestAllocationFailPoint(
      ResourceTestAllocationFailPoint::recordTrimCopy);
  expectCode(ResourceErrorCode::allocationFailed,
             "record trim copy maps bad_alloc", [&] {
               (void)dictionary.readRecordAt(0, 3);
             });

  std::string cleanedPath;
  {
    TempFixture cleanupFixture(valid);
    cleanedPath = cleanupFixture.path();
    expectCode(ResourceErrorCode::recordBlockInfoTooLarge,
               "expected failure still uses RAII temp cleanup", [&] {
                 auto tooSmall = defaults;
                 tooSmall.maximumRecordBlockInfoBytes = 15;
                 mdict::Mdict rejected(cleanupFixture.path(), tooSmall);
                 rejected.initMetadataOnly();
               });
  }
  require(!std::filesystem::exists(cleanedPath),
          "RAII temporary fixture removes expected-failure file");
}

void testRangesAndReturnedLimit() {
  const auto defaults = mdict::ResourceLimits::productionDefaults();
  const Fixture one = fixture({{'a', 'b', 'c'}});
  const Fixture two = fixture({{'a', 'b'}, {'c', 'd'}});
  const Fixture three = fixture({{'a', 'b'}, {'c', 'd'}, {'e', 'f'}});

  {
    TempFixture temporary(one);
    mdict::Mdict dictionary(temporary.path(), defaults);
    dictionary.initMetadataOnly();
    require(dictionary.readRecordAt(0, 3) == "abc", "single-block range");
    require(dictionary.readRecordAt(3, 3).empty(), "empty range at stream EOF");
  }
  {
    TempFixture temporary(two);
    mdict::Mdict dictionary(temporary.path(), defaults);
    dictionary.initMetadataOnly();
    require(dictionary.readRecordAt(1, 3) == "bc", "two-block range");
  }
  {
    auto exact = recordExactLimits(three);
    TempFixture temporary(three);
    mdict::Mdict dictionary(temporary.path(), exact);
    dictionary.initMetadataOnly();
    require(dictionary.readRecordAt(0, 6) == "abcdef",
            "three-block range exact limit and stream EOF");
    require(dictionary.readRecordAt(6, 6).empty(),
            "empty range at exact stream end");
    expectCode(ResourceErrorCode::offsetOutOfBounds, "range end before start",
               [&] { (void)dictionary.readRecordAt(4, 3); });
    expectCode(ResourceErrorCode::offsetOutOfBounds, "range start beyond stream",
               [&] { (void)dictionary.readRecordAt(7, 7); });
    expectCode(ResourceErrorCode::offsetOutOfBounds, "range end beyond stream",
               [&] { (void)dictionary.readRecordAt(0, 7); });
  }

  auto rangeOver = recordExactLimits(three);
  rangeOver.maximumRecordRangeBytes = 5;
  rangeOver.maximumReturnedRecordBytes = 5;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::recordRangeTooLarge,
             "range plus one rejected before reserve", [&] {
               runRead(three, rangeOver, 0, 6);
             });
  require(mdict::resourceTestObserverSnapshot().recordRangeReserveCount == 0,
          "range rejection performs no reserve");

  auto returnedOver = recordExactLimits(three);
  returnedOver.maximumReturnedRecordBytes = 5;
  mdict::resetResourceTestObserver();
  expectCode(ResourceErrorCode::returnedRecordTooLarge,
             "returned plus one rejected before third append", [&] {
               runRead(three, returnedOver, 0, 6);
             });
  require(mdict::resourceTestObserverSnapshot().recordAppendCount == 2,
          "returned limit stops before third append");
}

}  // namespace

int main() {
  testDefaults();
  testSummaryLimitFirstAndMetadata();
  testBlockLimitsAndAccumulators();
  testPrefixesChecksumsAndDecoders();
  testMetadataAtomicityAndAllocationFailures();
  testRangesAndReturnedLimit();
  std::printf("D1b3A2BRecordResourceLimitsSmoke: %d total runtime assertions "
              "PASSED\n",
              g_checks);
}
