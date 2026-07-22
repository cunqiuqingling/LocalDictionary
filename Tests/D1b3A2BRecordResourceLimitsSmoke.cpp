// D1b-3A-2B synthetic Record metadata and bounded decoder smoke.
// It uses no private dictionaries, configuration, Application Support, network,
// or Keychain state.

#include "mdict.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "miniz/miniz.h"

#ifndef MDICT_RESOURCE_TEST_OBSERVER
#error "Record smoke requires MDICT_RESOURCE_TEST_OBSERVER"
#endif

namespace {
using mdict::ResourceErrorCode;
using mdict::ResourceException;

int g_checks = 0;
void require(bool value, const char *message) {
  if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
  ++g_checks;
}
template <typename Work>
void expectCode(ResourceErrorCode expected, const char *message, Work work) {
  try { work(); }
  catch (const ResourceException &error) {
    require(error.code() == expected, message);
    return;
  }
  std::fprintf(stderr, "FAIL: %s (no exception)\n", message); std::exit(1);
}
void be32(std::vector<uint8_t> &out, uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) out.push_back((value >> shift) & 0xff);
}
void le32(std::vector<uint8_t> &out, uint32_t value) {
  for (int shift = 0; shift <= 24; shift += 8) out.push_back((value >> shift) & 0xff);
}
void be64(std::vector<uint8_t> &out, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) out.push_back((value >> shift) & 0xff);
}
uint32_t adler(const std::vector<uint8_t> &data) {
  return static_cast<uint32_t>(mz_adler32(MZ_ADLER32_INIT, data.data(), data.size()));
}
void overwrite64(std::vector<uint8_t> &out, size_t offset, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) out[offset++] = (value >> shift) & 0xff;
}
std::vector<uint8_t> zlibCompress(const std::vector<uint8_t> &input) {
  mz_ulong capacity = mz_compressBound(input.size());
  std::vector<uint8_t> output(capacity);
  mz_ulong length = capacity;
  require(mz_compress(output.data(), &length, input.data(), input.size()) == MZ_OK,
          "synthetic zlib compression");
  output.resize(length);
  return output;
}
void appendUTF16LE(std::vector<uint8_t> &out, const std::string &text) {
  for (unsigned char c : text) { out.push_back(c); out.push_back(0); }
}
struct Fixture {
  std::vector<uint8_t> bytes;
  size_t recordSummaryOffset = 0;
  size_t recordInfoOffset = 0;
};
Fixture fixture(std::vector<std::vector<uint8_t>> records, bool zlib = false) {
  const std::string xml = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"No\" Encoding=\"UTF-8\"/>";
  std::vector<uint8_t> header; appendUTF16LE(header, xml);
  std::vector<uint8_t> keyraw; be64(keyraw, 0); keyraw.push_back('a'); keyraw.push_back(0);
  std::vector<uint8_t> keyblock{0,0,0,0}; be32(keyblock, adler(keyraw)); keyblock.insert(keyblock.end(), keyraw.begin(), keyraw.end());
  std::vector<uint8_t> keyinfo; be64(keyinfo, 1); keyinfo.push_back(0); keyinfo.push_back(1); keyinfo.push_back('a'); keyinfo.push_back(0); keyinfo.push_back(0); keyinfo.push_back(1); keyinfo.push_back('a'); keyinfo.push_back(0); be64(keyinfo, keyblock.size()); be64(keyinfo, keyraw.size());
  auto keyinfoPayload = zlibCompress(keyinfo);
  std::vector<uint8_t> keyinfoBlock{2,0,0,0}; be32(keyinfoBlock, adler(keyinfo)); keyinfoBlock.insert(keyinfoBlock.end(), keyinfoPayload.begin(), keyinfoPayload.end());
  std::vector<std::vector<uint8_t>> blocks;
  uint64_t totalCompressed = 0;
  for (const auto &raw : records) {
    std::vector<uint8_t> payload = zlib ? zlibCompress(raw) : raw;
    std::vector<uint8_t> block{static_cast<uint8_t>(zlib ? 2 : 0),0,0,0};
    be32(block, adler(raw)); block.insert(block.end(), payload.begin(), payload.end());
    totalCompressed += block.size(); blocks.push_back(std::move(block));
  }
  std::vector<uint8_t> out; be32(out, header.size()); out.insert(out.end(), header.begin(), header.end()); le32(out, adler(header));
  std::vector<uint8_t> keyHeader;
  be64(keyHeader, 1); be64(keyHeader, 1); be64(keyHeader, keyinfo.size());
  be64(keyHeader, keyinfoBlock.size()); be64(keyHeader, keyblock.size());
  out.insert(out.end(), keyHeader.begin(), keyHeader.end()); be32(out, adler(keyHeader));
  out.insert(out.end(), keyinfoBlock.begin(), keyinfoBlock.end()); out.insert(out.end(), keyblock.begin(), keyblock.end());
  Fixture result; result.recordSummaryOffset = out.size();
  be64(out, blocks.size()); be64(out, 1); be64(out, blocks.size() * 16); be64(out, totalCompressed);
  result.recordInfoOffset = out.size();
  for (size_t index = 0; index < blocks.size(); ++index) {
    be64(out, blocks[index].size());
    be64(out, records[index].size());
  }
  for (const auto &block : blocks) out.insert(out.end(), block.begin(), block.end());
  result.bytes = std::move(out);
  return result;
}
std::string writeFixture(const Fixture &f) {
  char path[] = "/tmp/LocalDictionary-D1b3A2B-XXXXXX"; int fd = mkstemp(path);
  require(fd >= 0, "create synthetic fixture"); close(fd);
  std::ofstream stream(path, std::ios::binary);
  require(stream.good(), "open synthetic fixture");
  stream.write(reinterpret_cast<const char *>(f.bytes.data()), f.bytes.size());
  require(stream.good(), "write synthetic fixture");
  stream.close(); return path;
}
void runMetadata(const Fixture &f, mdict::ResourceLimits limits) {
  const std::string path = writeFixture(f); mdict::Mdict dictionary(path, limits); dictionary.initMetadataOnly(); std::filesystem::remove(path);
}
void runRead(const Fixture &f, mdict::ResourceLimits limits) {
  const std::string path = writeFixture(f); mdict::Mdict dictionary(path, limits);
  dictionary.initMetadataOnly(); (void)dictionary.readRecordAt(0, dictionary.recordStreamSize());
  std::filesystem::remove(path);
}
}  // namespace

int main() {
  auto defaults = mdict::ResourceLimits::productionDefaults();
  require(defaults.maximumRecordBlockInfoBytes == UINT64_C(524288), "record info default");
  require(defaults.maximumRecordBlockCount == UINT64_C(16384), "record count default");
  require(defaults.maximumSingleRecordBlockCompressedBytes == UINT64_C(1048576), "record compressed default");
  require(defaults.maximumSingleRecordBlockDecompressedBytes == UINT64_C(8388608), "record decompressed default");
  require(defaults.maximumTotalRecordBlockCompressedBytes == UINT64_C(268435456), "record total compressed default");
  require(defaults.maximumTotalRecordBlockDecompressedBytes == UINT64_C(1073741824), "record total decompressed default");
  require(defaults.maximumRecordRangeBytes == UINT64_C(524288), "record range default");
  require(defaults.maximumReturnedRecordBytes == UINT64_C(524288), "returned default");

  const Fixture valid = fixture({{'a','b','c'}});
  runMetadata(valid, defaults);
  mdict::resetResourceTestObserver();
  const std::string validPath = writeFixture(valid);
  mdict::Mdict validDictionary(validPath, defaults); validDictionary.initMetadataOnly();
  require(validDictionary.recordBlockCount() == 1, "single record block parsed");
  require(validDictionary.recordStreamSize() == 3, "record stream parsed");
  require(validDictionary.readRecordAt(0, 3) == "abc", "type-0 record range");
  require(mdict::resourceTestObserverSnapshot().recordBlockInfoInputBufferAllocationCount == 1,
          "record info table allocation observed");
  std::filesystem::remove(validPath);

  auto infoOver = defaults; infoOver.maximumRecordBlockInfoBytes = 15;
  expectCode(ResourceErrorCode::recordBlockInfoTooLarge, "info limit before allocation", [&] { runMetadata(valid, infoOver); });
  auto countOver = defaults; countOver.maximumRecordBlockCount = 0; // invalid limits have priority
  expectCode(ResourceErrorCode::invalidResourceLimits, "zero record count limit rejected", [&] { runMetadata(valid, countOver); });
  Fixture malformedShape = valid; overwrite64(malformedShape.bytes, malformedShape.recordSummaryOffset + 16, 17);
  expectCode(ResourceErrorCode::malformedRecordBlockMetadata, "pair table exact shape", [&] { runMetadata(malformedShape, defaults); });
  Fixture wrongTotal = valid; overwrite64(wrongTotal.bytes, wrongTotal.recordSummaryOffset + 24, 99);
  expectCode(ResourceErrorCode::malformedRecordBlockMetadata, "declared record total exact", [&] { runMetadata(wrongTotal, defaults); });
  Fixture prefix = valid; prefix.bytes.resize(prefix.bytes.size() - 1);
  expectCode(ResourceErrorCode::truncatedFile, "record block EOF before input allocation", [&] { runRead(prefix, defaults); });
  Fixture compressed = fixture({{'z','l','i','b'}}, true); const std::string compressedPath = writeFixture(compressed);
  mdict::Mdict zlibDictionary(compressedPath, defaults); zlibDictionary.initMetadataOnly();
  require(zlibDictionary.readRecordAt(0, 4) == "zlib", "bounded exact zlib record block");
  require(mdict::resourceTestObserverSnapshot().uncompressCallCount >= 1, "record zlib uses bounded helper");
  std::filesystem::remove(compressedPath);

  const Fixture multiple = fixture({{'a','b'}, {'c','d'}});
  const std::string multiplePath = writeFixture(multiple);
  mdict::Mdict multipleDictionary(multiplePath, defaults); multipleDictionary.initMetadataOnly();
  require(multipleDictionary.readRecordAt(1, 3) == "bc", "two-block bounded range");
  require(multipleDictionary.readRecordAt(2, 2).empty(), "empty record range");
  expectCode(ResourceErrorCode::offsetOutOfBounds, "inverted range rejected", [&] { (void)multipleDictionary.readRecordAt(3, 2); });
  expectCode(ResourceErrorCode::offsetOutOfBounds, "end beyond stream rejected", [&] { (void)multipleDictionary.readRecordAt(0, 5); });
  auto exactRange = defaults; exactRange.maximumRecordRangeBytes = 4; exactRange.maximumReturnedRecordBytes = 4;
  mdict::Mdict exactRangeDictionary(multiplePath, exactRange); exactRangeDictionary.initMetadataOnly();
  require(exactRangeDictionary.readRecordAt(0, 4) == "abcd", "range exact limit accepted");
  auto rangeTooSmall = exactRange; rangeTooSmall.maximumRecordRangeBytes = 3; rangeTooSmall.maximumReturnedRecordBytes = 3;
  mdict::Mdict rangeTooSmallDictionary(multiplePath, rangeTooSmall); rangeTooSmallDictionary.initMetadataOnly();
  expectCode(ResourceErrorCode::recordRangeTooLarge, "range over limit rejected", [&] { (void)rangeTooSmallDictionary.readRecordAt(0, 4); });
  auto returnedTooSmall = exactRange; returnedTooSmall.maximumReturnedRecordBytes = 3;
  mdict::Mdict returnedTooSmallDictionary(multiplePath, returnedTooSmall); returnedTooSmallDictionary.initMetadataOnly();
  expectCode(ResourceErrorCode::returnedRecordTooLarge, "append over returned limit rejected", [&] { (void)returnedTooSmallDictionary.readRecordAt(0, 4); });
  std::filesystem::remove(multiplePath);
  std::printf("D1b3A2BRecordResourceLimitsSmoke: %d total runtime assertions PASSED\n", g_checks);
}
