// MDictResourceMetricsProbeSmoke – synthetic tests for anonymous metrics.
//
// Every input is created below a temporary directory. No private dictionary,
// index, Application Support data, network, or Keychain is used.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <sqlite3.h>
#include <string>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <utility>
#include <vector>

#include "miniz.h"

namespace {

int gAssertions = 0;

void require(bool condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
  ++gAssertions;
}

std::string quote(const std::string &value) { return "\"" + value + "\""; }

std::string readFile(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  require(input.good(), "read input");
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

uint64_t fingerprint(const std::string &path) {
  const std::string bytes = readFile(path);
  uint64_t hash = UINT64_C(1469598103934665603);
  for (unsigned char byte : bytes) {
    hash ^= byte;
    hash *= UINT64_C(1099511628211);
  }
  return hash;
}

uint64_t fileSize(const std::string &path) {
  struct stat status {};
  require(stat(path.c_str(), &status) == 0, "stat input");
  return static_cast<uint64_t>(status.st_size);
}

std::string xattrNames(const std::string &path) {
  const ssize_t length = listxattr(path.c_str(), nullptr, 0, 0);
  require(length >= 0, "list input xattrs");
  if (length == 0) return {};
  std::vector<char> names(static_cast<size_t>(length));
  require(listxattr(path.c_str(), names.data(), names.size(), 0) == length,
          "read input xattrs");
  return {names.data(), names.size()};
}

bool exists(const std::string &path) {
  struct stat status {};
  return stat(path.c_str(), &status) == 0;
}

std::pair<int, std::string> runCaptured(const std::string &command) {
  FILE *pipe = popen((command + " 2>&1").c_str(), "r");
  require(pipe != nullptr, "open command pipe");
  std::string output;
  char buffer[4096];
  while (fgets(buffer, sizeof(buffer), pipe)) output += buffer;
  return {pclose(pipe), output};
}

std::vector<uint8_t> zlibCompress(const void *data, size_t length) {
  mz_ulong capacity = mz_compressBound(length);
  std::vector<uint8_t> output(capacity);
  mz_ulong outputLength = capacity;
  require(mz_compress(output.data(), &outputLength,
                      static_cast<const unsigned char *>(data), length) == MZ_OK,
          "compress synthetic MDX");
  output.resize(outputLength);
  return output;
}

uint32_t adler32Bytes(const void *data, size_t length) {
  return static_cast<uint32_t>(
      mz_adler32(MZ_ADLER32_INIT, static_cast<const unsigned char *>(data), length));
}

void writeBE16(std::vector<uint8_t> &bytes, uint16_t value) {
  bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
  bytes.push_back(static_cast<uint8_t>(value & 0xff));
}

void writeBE32(std::vector<uint8_t> &bytes, uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) {
    bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void writeLE32(std::vector<uint8_t> &bytes, uint32_t value) {
  for (int shift = 0; shift <= 24; shift += 8) {
    bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void writeBE64(std::vector<uint8_t> &bytes, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

// Golden Header fixtures are deliberately fixed UTF-16LE byte arrays. Their
// Adler-32 constants were independently precomputed before this source was
// written; this smoke never calls a checksum helper to create an expectation.
// v1.0 and v1.2 differ by exactly the ASCII version-minor byte (0x30/0x32).
constexpr uint8_t kGoldenHeaderV10[] = {
    0x3C, 0x00, 0x44, 0x00, 0x69, 0x00, 0x63, 0x00, 0x74, 0x00, 0x69, 0x00,
    0x6F, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x72, 0x00, 0x79, 0x00, 0x20, 0x00,
    0x47, 0x00, 0x65, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x72, 0x00, 0x61, 0x00,
    0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x42, 0x00, 0x79, 0x00, 0x45, 0x00,
    0x6E, 0x00, 0x67, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x56, 0x00,
    0x65, 0x00, 0x72, 0x00, 0x73, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00,
    0x3D, 0x00, 0x22, 0x00, 0x31, 0x00, 0x2E, 0x00, 0x30, 0x00, 0x22, 0x00,
    0x20, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00, 0x79, 0x00,
    0x70, 0x00, 0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x3D, 0x00, 0x22, 0x00,
    0x4E, 0x00, 0x6F, 0x00, 0x22, 0x00, 0x2F, 0x00, 0x3E, 0x00,
};
constexpr uint8_t kGoldenHeaderV12[] = {
    0x3C, 0x00, 0x44, 0x00, 0x69, 0x00, 0x63, 0x00, 0x74, 0x00, 0x69, 0x00,
    0x6F, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x72, 0x00, 0x79, 0x00, 0x20, 0x00,
    0x47, 0x00, 0x65, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x72, 0x00, 0x61, 0x00,
    0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x42, 0x00, 0x79, 0x00, 0x45, 0x00,
    0x6E, 0x00, 0x67, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x56, 0x00,
    0x65, 0x00, 0x72, 0x00, 0x73, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00,
    0x3D, 0x00, 0x22, 0x00, 0x31, 0x00, 0x2E, 0x00, 0x32, 0x00, 0x22, 0x00,
    0x20, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00, 0x79, 0x00,
    0x70, 0x00, 0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x3D, 0x00, 0x22, 0x00,
    0x4E, 0x00, 0x6F, 0x00, 0x22, 0x00, 0x2F, 0x00, 0x3E, 0x00,
};
constexpr uint8_t kGoldenHeaderV20Encrypted[] = {
    0x3C, 0x00, 0x44, 0x00, 0x69, 0x00, 0x63, 0x00, 0x74, 0x00, 0x69, 0x00,
    0x6F, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x72, 0x00, 0x79, 0x00, 0x20, 0x00,
    0x47, 0x00, 0x65, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x72, 0x00, 0x61, 0x00,
    0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x42, 0x00, 0x79, 0x00, 0x45, 0x00,
    0x6E, 0x00, 0x67, 0x00, 0x69, 0x00, 0x6E, 0x00, 0x65, 0x00, 0x56, 0x00,
    0x65, 0x00, 0x72, 0x00, 0x73, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00,
    0x3D, 0x00, 0x22, 0x00, 0x32, 0x00, 0x2E, 0x00, 0x30, 0x00, 0x22, 0x00,
    0x20, 0x00, 0x45, 0x00, 0x6E, 0x00, 0x63, 0x00, 0x72, 0x00, 0x79, 0x00,
    0x70, 0x00, 0x74, 0x00, 0x65, 0x00, 0x64, 0x00, 0x3D, 0x00, 0x22, 0x00,
    0x59, 0x00, 0x65, 0x00, 0x73, 0x00, 0x22, 0x00, 0x2F, 0x00, 0x3E, 0x00,
};
constexpr uint32_t kGoldenHeaderV10Checksum = UINT32_C(0x0FEB1482);
constexpr uint32_t kGoldenHeaderV12Checksum = UINT32_C(0x10371484);
constexpr uint32_t kGoldenHeaderV20Checksum = UINT32_C(0x3BB514F7);

void writeFixture(const std::string &path, const std::vector<uint8_t> &bytes) {
  std::ofstream output(path, std::ios::binary);
  require(output.good(), "open fixed golden fixture");
  output.write(reinterpret_cast<const char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  require(output.good(), "write fixed golden fixture");
}

std::string buildGoldenHeaderMDX(const std::string &directory, const std::string &filename,
                                 const uint8_t *header, size_t headerLength,
                                 uint32_t fixedChecksum, int major,
                                 bool metadataAfterChecksum = true) {
  std::vector<uint8_t> file;
  writeBE32(file, static_cast<uint32_t>(headerLength));
  file.insert(file.end(), header, header + headerLength);
  writeLE32(file, fixedChecksum);
  if (metadataAfterChecksum) {
    const uint64_t width = major >= 2 ? 8 : 4;
    const size_t keyHeaderFields = major >= 2 ? 5 : 4;
    for (size_t index = 0; index < keyHeaderFields; ++index) {
      if (width == 4) writeBE32(file, 0); else writeBE64(file, 0);
    }
    if (major >= 2) writeBE32(file, 0);  // unused when Encrypted="Yes"
    for (size_t index = 0; index < 4; ++index) {
      if (width == 4) writeBE32(file, 0); else writeBE64(file, 0);
    }
  }
  const std::string path = directory + "/" + filename;
  writeFixture(path, file);
  return path;
}

std::string buildMinimalMDX(const std::string &directory) {
  const std::string path = directory + "/synthetic-input.mdx";
  const char *header =
      "<Dictionary GeneratedByEngineVersion=\"2.0\" "
      "RequiredEngineVersion=\"2.0\" Encrypted=\"No\" Encoding=\"UTF-8\"/>";
  std::vector<uint8_t> headerUTF16;
  for (const char *cursor = header; *cursor; ++cursor) {
    headerUTF16.push_back(static_cast<uint8_t>(*cursor));
    headerUTF16.push_back(0);
  }

  std::vector<uint8_t> keyInfoRaw;
  writeBE64(keyInfoRaw, 2);
  writeBE16(keyInfoRaw, 3);
  keyInfoRaw.insert(keyInfoRaw.end(), {'a', 'a', 'a', 0});
  writeBE16(keyInfoRaw, 3);
  keyInfoRaw.insert(keyInfoRaw.end(), {'z', 'z', 'z', 0});
  const size_t keyInfoCompressedOffset = keyInfoRaw.size();
  writeBE64(keyInfoRaw, 0);
  const size_t keyInfoDecompressedOffset = keyInfoRaw.size();
  writeBE64(keyInfoRaw, 0);

  std::vector<uint8_t> keyRaw;
  writeBE64(keyRaw, 0);
  keyRaw.insert(keyRaw.end(), {'a', 'a', 'a', 0});
  writeBE64(keyRaw, 13);
  keyRaw.insert(keyRaw.end(), {'z', 'z', 'z', 0});
  const auto keyCompressed = zlibCompress(keyRaw.data(), keyRaw.size());
  const uint64_t keyCompressedSize = keyCompressed.size() + 8;
  const uint64_t keyDecompressedSize = keyRaw.size();
  for (int index = 0; index < 8; ++index) {
    keyInfoRaw[keyInfoCompressedOffset + static_cast<size_t>(index)] =
        static_cast<uint8_t>((keyCompressedSize >> ((7 - index) * 8)) & 0xff);
    keyInfoRaw[keyInfoDecompressedOffset + static_cast<size_t>(index)] =
        static_cast<uint8_t>((keyDecompressedSize >> ((7 - index) * 8)) & 0xff);
  }
  const auto keyInfoCompressed = zlibCompress(keyInfoRaw.data(), keyInfoRaw.size());

  std::string record = "synthetic record alpha";
  record.push_back('\0');
  record += "synthetic record omega";
  record.push_back('\0');
  const auto recordCompressed = zlibCompress(record.data(), record.size());

  std::vector<uint8_t> keyInfoBlock{2, 0, 0, 0};
  writeBE32(keyInfoBlock, adler32Bytes(keyInfoRaw.data(), keyInfoRaw.size()));
  keyInfoBlock.insert(keyInfoBlock.end(), keyInfoCompressed.begin(), keyInfoCompressed.end());
  std::vector<uint8_t> keyBlock{2, 0, 0, 0};
  writeBE32(keyBlock, adler32Bytes(keyRaw.data(), keyRaw.size()));
  keyBlock.insert(keyBlock.end(), keyCompressed.begin(), keyCompressed.end());
  std::vector<uint8_t> recordBlock{2, 0, 0, 0};
  writeBE32(recordBlock, adler32Bytes(record.data(), record.size()));
  recordBlock.insert(recordBlock.end(), recordCompressed.begin(), recordCompressed.end());
  std::vector<uint8_t> recordInfo;
  writeBE64(recordInfo, recordBlock.size());
  writeBE64(recordInfo, record.size());

  std::vector<uint8_t> keyHeader;
  writeBE64(keyHeader, 1); writeBE64(keyHeader, 2);
  writeBE64(keyHeader, keyInfoRaw.size());
  writeBE64(keyHeader, keyInfoBlock.size());
  writeBE64(keyHeader, keyBlock.size());

  std::vector<uint8_t> file;
  writeBE32(file, static_cast<uint32_t>(headerUTF16.size()));
  file.insert(file.end(), headerUTF16.begin(), headerUTF16.end());
  writeLE32(file, adler32Bytes(headerUTF16.data(), headerUTF16.size()));
  file.insert(file.end(), keyHeader.begin(), keyHeader.end());
  writeBE32(file, adler32Bytes(keyHeader.data(), keyHeader.size()));
  file.insert(file.end(), keyInfoBlock.begin(), keyInfoBlock.end());
  file.insert(file.end(), keyBlock.begin(), keyBlock.end());
  writeBE64(file, 1); writeBE64(file, 2);
  writeBE64(file, recordInfo.size()); writeBE64(file, recordBlock.size());
  file.insert(file.end(), recordInfo.begin(), recordInfo.end());
  file.insert(file.end(), recordBlock.begin(), recordBlock.end());

  std::ofstream output(path, std::ios::binary);
  require(output.good(), "open synthetic MDX");
  output.write(reinterpret_cast<const char *>(file.data()),
               static_cast<std::streamsize>(file.size()));
  require(output.good(), "write synthetic MDX");
  return path;
}

void writeNumber(std::vector<uint8_t> &bytes, uint64_t value, uint64_t width) {
  if (width == 4) {
    writeBE32(bytes, static_cast<uint32_t>(value));
  } else {
    writeBE64(bytes, value);
  }
}

std::string buildRecordMetadataMDX(
    const std::string &directory, const std::string &filename,
    const std::string &version, const std::string &encrypted,
    const std::vector<std::pair<uint64_t, uint64_t>> &recordPairs,
    uint64_t declaredPairBytes = 0, uint64_t declaredCompressedBytes = UINT64_MAX,
    size_t truncateBytes = 0) {
  const std::string path = directory + "/" + filename;
  const int major = version.empty() ? 0 : version[0] - '0';
  const uint64_t width = major >= 2 ? 8 : 4;
  const char *prefix = "<Dictionary GeneratedByEngineVersion=\"";
  const std::string header = std::string(prefix) + version +
      "\" RequiredEngineVersion=\"" + version + "\" Encrypted=\"" + encrypted +
      "\" Encoding=\"UTF-8\"/>";
  std::vector<uint8_t> headerUTF16;
  for (char character : header) {
    headerUTF16.push_back(static_cast<uint8_t>(character));
    headerUTF16.push_back(0);
  }

  uint64_t pairCompressedTotal = 0;
  for (const auto &[compressed, unused] : recordPairs) {
    (void)unused;
    pairCompressedTotal += compressed;
  }
  if (declaredPairBytes == 0) declaredPairBytes = recordPairs.size() * 2 * width;
  if (declaredCompressedBytes == UINT64_MAX) declaredCompressedBytes = pairCompressedTotal;

  std::vector<uint8_t> file;
  writeBE32(file, static_cast<uint32_t>(headerUTF16.size()));
  file.insert(file.end(), headerUTF16.begin(), headerUTF16.end());
  writeLE32(file, adler32Bytes(headerUTF16.data(), headerUTF16.size()));
  writeNumber(file, 0, width);  // key block count
  writeNumber(file, 0, width);  // entry count
  if (width == 8) {
    writeNumber(file, 0, width);  // key-info decompressed bytes
    writeNumber(file, 0, width);  // key-info compressed bytes
    writeNumber(file, 0, width);  // key block bytes
    writeBE32(file, adler32Bytes(file.data() + file.size() - 40, 40));
  } else {
    writeNumber(file, 0, width);  // key-info bytes
    writeNumber(file, 0, width);  // key block bytes
  }
  writeNumber(file, recordPairs.size(), width);
  writeNumber(file, 0, width);  // entry count matches key header
  writeNumber(file, declaredPairBytes, width);
  writeNumber(file, declaredCompressedBytes, width);
  for (const auto &[compressed, decompressed] : recordPairs) {
    writeNumber(file, compressed, width);
    writeNumber(file, decompressed, width);
  }
  if (declaredCompressedBytes <= 4096) {
    file.insert(file.end(), static_cast<size_t>(declaredCompressedBytes), 0);
  }
  if (truncateBytes > 0 && truncateBytes < file.size()) file.resize(file.size() - truncateBytes);

  std::ofstream output(path, std::ios::binary);
  require(output.good(), "open record metadata MDX");
  output.write(reinterpret_cast<const char *>(file.data()),
               static_cast<std::streamsize>(file.size()));
  require(output.good(), "write record metadata MDX");
  return path;
}

std::string buildHeaderOnlyMDX(const std::string &directory, const std::string &filename,
                               const std::string &version, const std::string &encrypted) {
  return buildRecordMetadataMDX(directory, filename, version, encrypted, {});
}

void sqliteRequire(int status, sqlite3 *database, const char *message) {
  if (status != SQLITE_OK && status != SQLITE_DONE) {
    std::fprintf(stderr, "SQLite fixture failure: %s (%s)\n", message,
                 database ? sqlite3_errmsg(database) : "no database");
    std::exit(1);
  }
  ++gAssertions;
}

void createEntriesDatabase(const std::string &path,
                           const std::vector<std::pair<int64_t, int64_t>> &ranges) {
  sqlite3 *database = nullptr;
  sqliteRequire(sqlite3_open_v2(path.c_str(), &database,
                                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                                nullptr), database, "open synthetic SQLite");
  sqliteRequire(sqlite3_exec(database,
                             "CREATE TABLE entries(record_start INTEGER, record_end INTEGER)",
                             nullptr, nullptr, nullptr), database, "create entries");
  sqlite3_stmt *statement = nullptr;
  sqliteRequire(sqlite3_prepare_v2(database,
                                   "INSERT INTO entries(record_start, record_end) VALUES(?1, ?2)",
                                   -1, &statement, nullptr), database, "prepare range insert");
  for (const auto &[start, end] : ranges) {
    sqliteRequire(sqlite3_bind_int64(statement, 1, start), database, "bind start");
    sqliteRequire(sqlite3_bind_int64(statement, 2, end), database, "bind end");
    sqliteRequire(sqlite3_step(statement), database, "insert range");
    sqliteRequire(sqlite3_reset(statement), database, "reset range insert");
    sqliteRequire(sqlite3_clear_bindings(statement), database, "clear range insert");
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
}

void createSQL(const std::string &path, const char *sql) {
  sqlite3 *database = nullptr;
  sqliteRequire(sqlite3_open_v2(path.c_str(), &database,
                                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                                nullptr), database, "open custom SQLite");
  sqliteRequire(sqlite3_exec(database, sql, nullptr, nullptr, nullptr), database,
                "create custom SQLite");
  sqlite3_close(database);
}

std::string probeCommand(const std::string &probe, const std::string &arguments) {
  return quote(probe) + " " + arguments;
}

void requireChecksumField(const std::string &json, const char *name, const char *value);

void testAggregateAndPrivacy(const std::string &directory, const std::string &probe) {
  const std::string mdx = buildMinimalMDX(directory);
  const std::string index = directory + "/synthetic-ranges.sqlite";
  createEntriesDatabase(index, {{0, 3}, {7, 20}, {20, 20}});
  const std::string output = directory + "/aggregate.json";
  const uint64_t mdxHash = fingerprint(mdx);
  const uint64_t mdxSize = fileSize(mdx);
  const std::string mdxXattrs = xattrNames(mdx);
  const uint64_t sqliteHash = fingerprint(index);
  const uint64_t sqliteSize = fileSize(index);
  const std::string sqliteXattrs = xattrNames(index);

  require(std::system(probeCommand(probe, "--mdx " + quote(mdx) + " --sqlite " +
                                      quote(index) + " --output " + quote(output)).c_str()) == 0,
          "aggregate probe succeeds");
  const std::string json = readFile(output);
  require(json.find("\"schemaVersion\":2") != std::string::npos, "schema version 2");
  require(json.find("\"maximumRecordRangeBytes\":13") != std::string::npos,
          "maximum record range");
  require(json.find("\"recordBlockInfoBytes\":") != std::string::npos,
          "legacy record info field retained");
  requireChecksumField(json, "checksumFailureStage", "none");
  requireChecksumField(json, "headerChecksumStatus", "valid");
  requireChecksumField(json, "keyInfoChecksumStatus", "valid");
  requireChecksumField(json, "keyBlockChecksumStatus", "notChecked");
  requireChecksumField(json, "recordBlockChecksumStatus", "notChecked");
  requireChecksumField(json, "headerChecksumEncodingMatch", "canonicalLittleEndian");
  require(json.find("\"dictionaries\"") == std::string::npos,
          "no per-dictionary output");
  require(json.find(mdx) == std::string::npos && json.find(index) == std::string::npos,
          "output hides input paths");
  require(json.find("synthetic-input.mdx") == std::string::npos &&
              json.find("synthetic-ranges.sqlite") == std::string::npos,
          "output hides input basenames");
  require(json.find("synthetic record") == std::string::npos &&
              json.find("alpha") == std::string::npos,
          "output hides content and headwords");
  require(json.find("GeneratedByEngineVersion") == std::string::npos,
          "output hides Header text");
  require(json.find("SHA") == std::string::npos && json.find("sha") == std::string::npos,
          "output hides hashes");
  require(fingerprint(mdx) == mdxHash && fileSize(mdx) == mdxSize,
          "MDX input unchanged");
  require(xattrNames(mdx) == mdxXattrs, "MDX xattrs unchanged");
  require(fingerprint(index) == sqliteHash && fileSize(index) == sqliteSize,
          "SQLite input unchanged");
  require(xattrNames(index) == sqliteXattrs, "SQLite xattrs unchanged");
  require(!exists(index + "-journal") && !exists(index + "-wal") && !exists(index + "-shm"),
          "read-only SQLite created no sidecars");
  struct stat mode {};
  require(stat(output.c_str(), &mode) == 0 && (mode.st_mode & 0777) == 0600,
          "output permission 0600");

  const std::string repeat = directory + "/aggregate-repeat.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(mdx) + " --sqlite " +
                                      quote(index) + " --output " + quote(repeat)).c_str()) == 0,
          "repeat aggregate succeeds");
  require(readFile(repeat) == json, "aggregate output deterministic");
  std::fprintf(stderr, "  aggregate / privacy / input immutability: PASS\n");
}

void testExplicitInputsOnly(const std::string &directory, const std::string &probe) {
  const std::string unusedMdx = buildMinimalMDX(directory);
  const std::string index = directory + "/only-explicit.sqlite";
  createEntriesDatabase(index, {{1, 5}});
  const std::string output = directory + "/only-sqlite.json";
  require(std::system(probeCommand(probe, "--sqlite " + quote(index) + " --output " +
                                      quote(output)).c_str()) == 0,
          "SQLite-only explicit input succeeds");
  const std::string json = readFile(output);
  require(json.find("\"maximumRecordRangeBytes\":4") != std::string::npos,
          "SQLite-only range aggregate");
  require(json.find("\"actualFileBytes\":0") != std::string::npos,
          "unprovided MDX was not discovered");
  require(json.find("\"metricsSupportStatus\":\"noMDXInput\"") != std::string::npos,
          "SQLite-only status identifies absent MDX");
  require(json.find(unusedMdx) == std::string::npos, "unprovided MDX not output");

  const std::string noInputOutput = directory + "/no-input.json";
  const auto [status, errors] = runCaptured(probeCommand(probe, "--output " + quote(noInputOutput)));
  require(status != 0, "no input rejected");
  require(!exists(noInputOutput), "no-input did not create output");
  require(errors.find(directory) == std::string::npos, "no-input error hides path");
  std::fprintf(stderr, "  explicit input only: PASS\n");
}

void testSQLiteRangesAndFailures(const std::string &directory, const std::string &probe) {
  const std::string first = directory + "/first.sqlite";
  const std::string second = directory + "/second.sqlite";
  createEntriesDatabase(first, {});
  createEntriesDatabase(second, {{0, 8}, {9, 33}});
  const std::string output = directory + "/multi.json";
  require(std::system(probeCommand(probe, "--sqlite " + quote(first) + " --sqlite " +
                                      quote(second) + " --output " + quote(output)).c_str()) == 0,
          "multiple SQLite inputs succeed");
  require(readFile(output).find("\"maximumRecordRangeBytes\":24") != std::string::npos,
          "multiple SQLite global maximum");

  const std::string signedBoundary = directory + "/signed-boundary.sqlite";
  createEntriesDatabase(signedBoundary, {{0, INT64_MAX}});
  const std::string signedOutput = directory + "/signed-boundary.json";
  require(std::system(probeCommand(probe, "--sqlite " + quote(signedBoundary) +
                                      " --output " + quote(signedOutput)).c_str()) == 0,
          "maximum signed range succeeds");
  require(readFile(signedOutput).find("\"maximumRecordRangeBytes\":9223372036854775807") !=
              std::string::npos,
          "maximum signed range exact value");

  struct InvalidCase { const char *name; const char *sql; };
  const InvalidCase cases[] = {
      {"missing-table", "CREATE TABLE other(x INTEGER)"},
      {"missing-column", "CREATE TABLE entries(record_start INTEGER)"},
      {"null", "CREATE TABLE entries(record_start INTEGER, record_end INTEGER); INSERT INTO entries VALUES(NULL, 1)"},
      {"text", "CREATE TABLE entries(record_start INTEGER, record_end INTEGER); INSERT INTO entries VALUES('x', 1)"},
      {"negative-start", "CREATE TABLE entries(record_start INTEGER, record_end INTEGER); INSERT INTO entries VALUES(-1, 1)"},
      {"negative-end", "CREATE TABLE entries(record_start INTEGER, record_end INTEGER); INSERT INTO entries VALUES(1, -1)"},
      {"reversed", "CREATE TABLE entries(record_start INTEGER, record_end INTEGER); INSERT INTO entries VALUES(7, 3)"},
  };
  for (const auto &invalid : cases) {
    const std::string input = directory + "/" + invalid.name + ".sqlite";
    const std::string failedOutput = directory + "/" + invalid.name + ".json";
    createSQL(input, invalid.sql);
    const auto [status, errors] = runCaptured(probeCommand(
        probe, "--sqlite " + quote(input) + " --output " + quote(failedOutput)));
    require(status != 0, "invalid SQLite rejected");
    require(!exists(failedOutput), "invalid SQLite has no partial JSON");
    require(errors.find(input) == std::string::npos &&
                errors.find(invalid.name) == std::string::npos,
            "invalid SQLite error hides path and basename");
  }

  const std::string valid = directory + "/valid-before-invalid.sqlite";
  createEntriesDatabase(valid, {{0, 2}});
  const std::string invalid = directory + "/invalid-after-valid.sqlite";
  createSQL(invalid, "CREATE TABLE entries(record_start INTEGER)");
  const std::string partial = directory + "/must-not-exist.json";
  require(std::system(probeCommand(probe, "--sqlite " + quote(valid) + " --sqlite " +
                                      quote(invalid) + " --output " + quote(partial)).c_str()) != 0,
          "later invalid input rejects aggregate");
  require(!exists(partial), "later invalid input wrote no partial aggregate");
  std::fprintf(stderr, "  SQLite ranges / malformed rows: PASS\n");
}

void testMdxAndOutputFailures(const std::string &directory, const std::string &probe) {
  const std::string missing = directory + "/missing-input.mdx";
  const std::string missingOutput = directory + "/missing.json";
  const auto [missingStatus, missingErrors] = runCaptured(
      probeCommand(probe, "--mdx " + quote(missing) + " --output " + quote(missingOutput)));
  require(missingStatus != 0, "missing MDX rejected");
  require(!exists(missingOutput), "missing MDX has no output");
  require(missingErrors.find(missing) == std::string::npos &&
              missingErrors.find("missing-input.mdx") == std::string::npos,
          "missing MDX error hides path");

  const std::string missingSQLite = directory + "/missing-input.sqlite";
  const std::string missingSQLiteOutput = directory + "/missing-sqlite.json";
  const auto [missingSQLiteStatus, missingSQLiteErrors] = runCaptured(
      probeCommand(probe, "--sqlite " + quote(missingSQLite) + " --output " +
                              quote(missingSQLiteOutput)));
  require(missingSQLiteStatus != 0, "missing SQLite rejected");
  require(!exists(missingSQLiteOutput), "missing SQLite has no output");
  require(missingSQLiteErrors.find(missingSQLite) == std::string::npos &&
              missingSQLiteErrors.find("missing-input.sqlite") == std::string::npos,
          "missing SQLite error hides path");

  const std::string directoryOutput = directory + "/directory-input.json";
  const auto [directoryStatus, directoryErrors] = runCaptured(
      probeCommand(probe, "--sqlite " + quote(directory) + " --output " +
                              quote(directoryOutput)));
  require(directoryStatus != 0, "non-regular SQLite input rejected");
  require(!exists(directoryOutput), "non-regular SQLite has no output");
  require(directoryErrors.find(directory) == std::string::npos,
          "non-regular SQLite error hides path");

  const std::string mdx = buildMinimalMDX(directory);
  const std::string protectedOutput = directory + "/protected.json";
  {
    std::ofstream protectedFile(protectedOutput);
    protectedFile << "preserve";
  }
  require(std::system(probeCommand(probe, "--mdx " + quote(mdx) + " --output " +
                                      quote(protectedOutput)).c_str()) != 0,
          "existing output protected");
  require(readFile(protectedOutput) == "preserve", "existing output unchanged");
  require(std::system(probeCommand(probe, "--mdx " + quote(mdx) + " --output " +
                                      quote(protectedOutput) + " --force").c_str()) == 0,
          "force output succeeds");
  std::fprintf(stderr, "  MDX failures / output protection: PASS\n");
}

void requireChecksumField(const std::string &json, const char *name, const char *value) {
  const std::string field = std::string("\"") + name + "\":\"" + value + "\"";
  require(json.find(field) != std::string::npos, "anonymous checksum diagnostic field");
}

void writeBE32At(std::vector<uint8_t> &bytes, size_t offset, uint32_t value) {
  require(offset <= bytes.size() && bytes.size() - offset >= 4, "checksum fixture field bounds");
  for (size_t index = 0; index < 4; ++index) {
    bytes[offset + index] = static_cast<uint8_t>((value >> ((3 - index) * 8)) & 0xff);
  }
}

std::vector<uint8_t> fixtureBytes(const std::string &path) {
  const std::string data = readFile(path);
  return {data.begin(), data.end()};
}

void assertChecksumDiagnosticPrivacy(const std::string &diagnostic,
                                     const std::string &directory,
                                     const std::string &basename) {
  require(diagnostic.find(directory) == std::string::npos &&
              diagnostic.find(basename) == std::string::npos,
          "checksum diagnostic hides input path and basename");
  require(diagnostic.find("Dictionary") == std::string::npos &&
              diagnostic.find("GeneratedByEngineVersion") == std::string::npos,
          "checksum diagnostic hides Header text");
  require(diagnostic.find("0FEB1482") == std::string::npos &&
              diagnostic.find("267064450") == std::string::npos,
          "checksum diagnostic hides checksum values");
  require(diagnostic.find("\"actualFileBytes\"") == std::string::npos,
          "checksum diagnostic is not partial metrics");
}

void testChecksumDiagnosticsAndGoldenFixtures(const std::string &directory,
                                              const std::string &probe) {
  // The v1.0/v1.2 fixtures differ in exactly one Header byte and have distinct
  // hardcoded checksum constants. The test never recomputes either constant.
  const std::string v10 = buildGoldenHeaderMDX(
      directory, "golden-v10.mdx", kGoldenHeaderV10, sizeof(kGoldenHeaderV10),
      kGoldenHeaderV10Checksum, 1);
  const std::string v12 = buildGoldenHeaderMDX(
      directory, "golden-v12.mdx", kGoldenHeaderV12, sizeof(kGoldenHeaderV12),
      kGoldenHeaderV12Checksum, 1);
  const std::string v20 = buildGoldenHeaderMDX(
      directory, "golden-v20.mdx", kGoldenHeaderV20Encrypted,
      sizeof(kGoldenHeaderV20Encrypted), kGoldenHeaderV20Checksum, 2);
  const uint64_t v10Hash = fingerprint(v10);
  const uint64_t v10Size = fileSize(v10);
  const std::string v10Xattrs = xattrNames(v10);
  require(kGoldenHeaderV10Checksum != kGoldenHeaderV12Checksum,
          "one-byte Header coverage boundary has distinct fixed checksums");

  for (const std::string *input : {&v10, &v12, &v20}) {
    const std::string output = *input + ".json";
    require(std::system(probeCommand(probe, "--mdx " + quote(*input) + " --output " +
                                        quote(output)).c_str()) == 0,
            "fixed canonical Header accepted");
    const std::string json = readFile(output);
    requireChecksumField(json, "checksumFailureStage", "none");
    requireChecksumField(json, "headerChecksumStatus", "valid");
    requireChecksumField(json, "headerChecksumEncodingMatch", "canonicalLittleEndian");
    requireChecksumField(json, "keyBlockChecksumStatus", "notChecked");
    requireChecksumField(json, "recordBlockChecksumStatus", "notChecked");
  }

  // A checksum ending exactly at EOF is accepted by the checksum path; the
  // later missing Key metadata yields only the expected truncated-file error.
  const std::string exactEOF = buildGoldenHeaderMDX(
      directory, "golden-exact-eof.mdx", kGoldenHeaderV10, sizeof(kGoldenHeaderV10),
      kGoldenHeaderV10Checksum, 1, false);
  const std::string exactEOFOutput = exactEOF + ".json";
  const auto [exactEOFStatus, exactEOFError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(exactEOF) + " --output " + quote(exactEOFOutput)));
  require(exactEOFStatus != 0 && !exists(exactEOFOutput) &&
              exactEOFError.find("truncatedFile") != std::string::npos &&
              exactEOFError.find("checksumMismatch") == std::string::npos,
          "checksum at exact EOF is accepted before later metadata truncation");

  std::vector<uint8_t> missingChecksum = fixtureBytes(exactEOF);
  missingChecksum.pop_back();
  const std::string missingOne = directory + "/golden-missing-one.mdx";
  writeFixture(missingOne, missingChecksum);
  const std::string missingOneOutput = missingOne + ".json";
  const auto [missingStatus, missingError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(missingOne) + " --output " + quote(missingOneOutput)));
  require(missingStatus != 0 && !exists(missingOneOutput) &&
              missingError.find("truncatedFile") != std::string::npos &&
              missingError.find("checksumMismatch") == std::string::npos,
          "missing checksum byte is truncated rather than mismatch");

  auto diagnose = [&](const std::string &input, const std::string &output) {
    return runCaptured(probeCommand(
        probe, "--diagnose-checksum --mdx " + quote(input) + " --output " + quote(output)));
  };
  const size_t checksumOffset = 4 + sizeof(kGoldenHeaderV10);
  std::vector<uint8_t> reversed = fixtureBytes(v10);
  writeBE32At(reversed, checksumOffset, kGoldenHeaderV10Checksum);
  const std::string reversedPath = directory + "/golden-reversed.mdx";
  writeFixture(reversedPath, reversed);
  const std::string reversedOutput = reversedPath + ".json";
  const auto [defaultReversedStatus, defaultReversedError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(reversedPath) + " --output " + quote(reversedOutput)));
  require(defaultReversedStatus != 0 && !exists(reversedOutput) &&
              defaultReversedError.find("checksumMismatch") != std::string::npos,
          "default mode strictly rejects byte-reversed checksum without diagnostics");
  const auto [reversedStatus, reversedDiagnostic] = diagnose(reversedPath, reversedOutput);
  require(reversedStatus != 0 && !exists(reversedOutput), "byte-reversed checksum remains strict failure");
  requireChecksumField(reversedDiagnostic, "checksumFailureStage", "header");
  requireChecksumField(reversedDiagnostic, "headerChecksumStatus", "mismatch");
  requireChecksumField(reversedDiagnostic, "headerChecksumEncodingMatch", "byteReversedBigEndian");
  requireChecksumField(reversedDiagnostic, "keyInfoChecksumStatus", "notReached");
  requireChecksumField(reversedDiagnostic, "keyBlockChecksumStatus", "notReached");
  requireChecksumField(reversedDiagnostic, "recordBlockChecksumStatus", "notReached");
  assertChecksumDiagnosticPrivacy(reversedDiagnostic, directory, "golden-reversed.mdx");

  std::vector<uint8_t> headerOnlyMismatch = fixtureBytes(exactEOF);
  writeBE32At(headerOnlyMismatch, checksumOffset, UINT32_C(0xA1B2C3D4));
  const std::string headerOnlyMismatchPath = directory + "/golden-header-only-mismatch.mdx";
  writeFixture(headerOnlyMismatchPath, headerOnlyMismatch);
  const auto [headerOnlyMismatchStatus, headerOnlyMismatchDiagnostic] = diagnose(
      headerOnlyMismatchPath, headerOnlyMismatchPath + ".json");
  require(headerOnlyMismatchStatus != 0, "Header mismatch occurs before missing metadata");
  requireChecksumField(headerOnlyMismatchDiagnostic, "checksumFailureStage", "header");
  require(headerOnlyMismatchDiagnostic.find("truncatedFile") == std::string::npos,
          "Header mismatch does not continue into Record metadata");

  std::vector<uint8_t> neither = fixtureBytes(v10);
  writeBE32At(neither, checksumOffset, UINT32_C(0xA1B2C3D4));
  const std::string neitherPath = directory + "/golden-neither.mdx";
  writeFixture(neitherPath, neither);
  const std::string neitherOutput = neitherPath + ".json";
  const auto [neitherStatus, neitherDiagnostic] = diagnose(neitherPath, neitherOutput);
  require(neitherStatus != 0 && !exists(neitherOutput), "neither checksum remains strict failure");
  requireChecksumField(neitherDiagnostic, "headerChecksumEncodingMatch", "neither");
  assertChecksumDiagnosticPrivacy(neitherDiagnostic, directory, "golden-neither.mdx");

  std::vector<uint8_t> tamperedHeader = fixtureBytes(v10);
  tamperedHeader[4] ^= UINT8_C(0x01);
  const std::string tamperedHeaderPath = directory + "/golden-header-tampered.mdx";
  writeFixture(tamperedHeaderPath, tamperedHeader);
  const auto [tamperedHeaderStatus, tamperedHeaderDiagnostic] = diagnose(
      tamperedHeaderPath, tamperedHeaderPath + ".json");
  require(tamperedHeaderStatus != 0, "tampered Header fixed checksum fails");
  requireChecksumField(tamperedHeaderDiagnostic, "checksumFailureStage", "header");

  std::vector<uint8_t> tamperedChecksum = fixtureBytes(v10);
  tamperedChecksum[checksumOffset] ^= UINT8_C(0x01);
  const std::string tamperedChecksumPath = directory + "/golden-checksum-tampered.mdx";
  writeFixture(tamperedChecksumPath, tamperedChecksum);
  const auto [tamperedChecksumStatus, tamperedChecksumDiagnostic] = diagnose(
      tamperedChecksumPath, tamperedChecksumPath + ".json");
  require(tamperedChecksumStatus != 0, "tampered checksum byte fails");
  requireChecksumField(tamperedChecksumDiagnostic, "checksumFailureStage", "header");

  std::vector<uint8_t> changedLength = fixtureBytes(v10);
  writeBE32At(changedLength, 0, static_cast<uint32_t>(sizeof(kGoldenHeaderV10) - 2));
  const std::string changedLengthPath = directory + "/golden-length-changed.mdx";
  writeFixture(changedLengthPath, changedLength);
  const auto [changedLengthStatus, changedLengthError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(changedLengthPath) + " --output " +
                              quote(changedLengthPath + ".json")));
  require(changedLengthStatus != 0 && changedLengthError.find("checksumMismatch") != std::string::npos,
          "changed Header length cannot reuse checksum coverage");

  std::vector<uint8_t> declaredPastEOF = fixtureBytes(v10);
  writeBE32At(declaredPastEOF, 0, static_cast<uint32_t>(declaredPastEOF.size()));
  const std::string declaredPastEOFPath = directory + "/golden-length-eof.mdx";
  writeFixture(declaredPastEOFPath, declaredPastEOF);
  const auto [pastEOFStatus, pastEOFError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(declaredPastEOFPath) + " --output " +
                              quote(declaredPastEOFPath + ".json")));
  require(pastEOFStatus != 0 && pastEOFError.find("truncatedFile") != std::string::npos,
          "declared Header length past EOF is truncated");

  std::vector<uint8_t> tooLarge = fixtureBytes(v10);
  writeBE32At(tooLarge, 0, UINT32_C(16 * 1024 * 1024 + 1));
  const std::string tooLargePath = directory + "/golden-length-too-large.mdx";
  writeFixture(tooLargePath, tooLarge);
  const auto [tooLargeStatus, tooLargeError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(tooLargePath) + " --output " +
                              quote(tooLargePath + ".json")));
  require(tooLargeStatus != 0 && tooLargeError.find("headerTooLarge") != std::string::npos,
          "declared Header length over tool limit is rejected");

  const std::string validFirstOutput = directory + "/must-not-exist-multi.json";
  const auto [multiStatus, multiDiagnostic] = runCaptured(probeCommand(
      probe, "--diagnose-checksum --mdx " + quote(v12) + " --mdx " + quote(neitherPath) +
                 " --output " + quote(validFirstOutput)));
  require(multiStatus != 0 && !exists(validFirstOutput),
          "later checksum failure writes no partial aggregate");
  requireChecksumField(multiDiagnostic, "checksumFailureStage", "header");
  require(multiDiagnostic.find("golden-v12.mdx") == std::string::npos,
          "multi-input diagnostic exposes no input mapping");

  const std::string untouchedSQLite = directory + "/checksum-not-sqlite.sqlite";
  createEntriesDatabase(untouchedSQLite, {{0, 7}});
  const uint64_t sqliteHash = fingerprint(untouchedSQLite);
  const uint64_t sqliteSize = fileSize(untouchedSQLite);
  const std::string sqliteXattrs = xattrNames(untouchedSQLite);
  const std::string checksumBeforeSQLiteOutput = directory + "/checksum-before-sqlite.json";
  const auto [checksumBeforeSQLiteStatus, checksumBeforeSQLiteDiagnostic] = runCaptured(probeCommand(
      probe, "--diagnose-checksum --mdx " + quote(neitherPath) + " --sqlite " +
                 quote(untouchedSQLite) + " --output " + quote(checksumBeforeSQLiteOutput)));
  require(checksumBeforeSQLiteStatus != 0 && !exists(checksumBeforeSQLiteOutput),
          "checksum mismatch blocks later SQLite aggregate output");
  requireChecksumField(checksumBeforeSQLiteDiagnostic, "checksumFailureStage", "header");
  require(fingerprint(untouchedSQLite) == sqliteHash && fileSize(untouchedSQLite) == sqliteSize &&
              xattrNames(untouchedSQLite) == sqliteXattrs,
          "Header mismatch does not access or modify later SQLite input");
  require(!exists(untouchedSQLite + "-journal") && !exists(untouchedSQLite + "-wal") &&
              !exists(untouchedSQLite + "-shm"),
          "checksum mismatch creates no SQLite sidecars");

  // Mutating a v2 Key-info checksum reaches the typed vendor exception. The
  // probe preserves that closed error as the fixed keyInfo stage without using
  // exception text or exposing any MDX metadata.
  const std::string keyInfoSource = buildMinimalMDX(directory);
  std::vector<uint8_t> keyInfoMismatch = fixtureBytes(keyInfoSource);
  const size_t sourceHeaderBytes = (size_t(keyInfoMismatch[0]) << 24) |
      (size_t(keyInfoMismatch[1]) << 16) | (size_t(keyInfoMismatch[2]) << 8) |
      size_t(keyInfoMismatch[3]);
  const size_t keyInfoChecksumOffset = 4 + sourceHeaderBytes + 4 + 40 + 4 + 4;
  require(keyInfoChecksumOffset < keyInfoMismatch.size(), "key-info checksum fixture offset");
  keyInfoMismatch[keyInfoChecksumOffset] ^= UINT8_C(0x01);
  const std::string keyInfoPath = directory + "/golden-key-info-mismatch.mdx";
  writeFixture(keyInfoPath, keyInfoMismatch);
  const std::string keyInfoOutput = keyInfoPath + ".json";
  const auto [keyInfoStatus, keyInfoDiagnostic] = diagnose(keyInfoPath, keyInfoOutput);
  require(keyInfoStatus != 0 && !exists(keyInfoOutput), "key-info mismatch remains strict failure");
  requireChecksumField(keyInfoDiagnostic, "checksumFailureStage", "keyInfo");
  requireChecksumField(keyInfoDiagnostic, "headerChecksumStatus", "valid");
  requireChecksumField(keyInfoDiagnostic, "keyInfoChecksumStatus", "mismatch");
  requireChecksumField(keyInfoDiagnostic, "keyBlockChecksumStatus", "notChecked");
  requireChecksumField(keyInfoDiagnostic, "recordBlockChecksumStatus", "notChecked");
  requireChecksumField(keyInfoDiagnostic, "headerChecksumEncodingMatch", "canonicalLittleEndian");
  assertChecksumDiagnosticPrivacy(keyInfoDiagnostic, directory, "golden-key-info-mismatch.mdx");
  require(fingerprint(v10) == v10Hash && fileSize(v10) == v10Size &&
              xattrNames(v10) == v10Xattrs,
          "golden MDX input remains byte-identical with unchanged xattrs");
  require(!exists(v10 + "-journal") && !exists(v10 + "-wal") && !exists(v10 + "-shm"),
          "golden MDX creates no sidecars");

  std::fprintf(stderr, "  checksum diagnostics / fixed golden Headers: PASS\n");
}

void testVersionIdentificationAndLegacyRecords(const std::string &directory,
                                               const std::string &probe) {
  const std::string v10 = buildRecordMetadataMDX(
      directory, "legacy-v10.mdx", "1.0", "No", {{8, 3}});
  const std::string v10Output = directory + "/legacy-v10.json";
  const uint64_t v10Hash = fingerprint(v10);
  const uint64_t v10Size = fileSize(v10);
  require(std::system(probeCommand(probe, "--mdx " + quote(v10) + " --output " +
                                      quote(v10Output)).c_str()) == 0,
          "v1.0 Record metrics succeed");
  const std::string v10JSON = readFile(v10Output);
  require(v10JSON.find("\"engineVersionMajor\":1") != std::string::npos &&
              v10JSON.find("\"engineVersionMinor\":0") != std::string::npos,
          "v1.0 identified anonymously");
  require(v10JSON.find("\"metricsSupportStatus\":\"supported\"") != std::string::npos,
          "v1.0 Record metrics supported");
  require(v10JSON.find("\"recordBlockCount\":1") != std::string::npos &&
              v10JSON.find("\"maximumSingleRecordBlockCompressedBytes\":8") !=
                  std::string::npos &&
              v10JSON.find("\"totalRecordBlockDecompressedBytes\":3") !=
                  std::string::npos,
          "v1.0 Record fields parsed without payload access");
  require(fingerprint(v10) == v10Hash && fileSize(v10) == v10Size,
          "v1.0 input unchanged");

  const std::string sameVersionOutput = directory + "/same-v10.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(v10) + " --mdx " +
                                      quote(v10) + " --output " + quote(sameVersionOutput)).c_str()) == 0,
          "multiple same-version inputs succeed");
  require(readFile(sameVersionOutput).find("\"metricsSupportStatus\":\"supported\"") !=
              std::string::npos,
          "multiple same versions retain supported status");

  const std::string v12 = buildRecordMetadataMDX(
      directory, "legacy-v12.mdx", "1.2", "No", {{8, 2}, {10, 5}});
  const std::string v12Output = directory + "/legacy-v12.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(v12) + " --output " +
                                      quote(v12Output)).c_str()) == 0,
          "v1.2 Record metrics succeed");
  const std::string v12JSON = readFile(v12Output);
  require(v12JSON.find("\"engineVersionMinor\":2") != std::string::npos &&
              v12JSON.find("\"recordBlockCount\":2") != std::string::npos &&
              v12JSON.find("\"maximumSingleRecordBlockCompressedBytes\":10") !=
                  std::string::npos &&
              v12JSON.find("\"totalRecordBlockCompressedBytes\":18") !=
                  std::string::npos,
          "v1.2 multi-block Record aggregate");

  const std::string mixedLegacyOutput = directory + "/mixed-v1.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(v10) + " --mdx " +
                                      quote(v12) + " --output " + quote(mixedLegacyOutput)).c_str()) == 0,
          "multiple legacy Record inputs succeed");
  require(readFile(mixedLegacyOutput).find("\"metricsSupportStatus\":\"mixedVersions\"") !=
              std::string::npos,
          "mixed v1 versions reported anonymously");

  const std::string v20 = buildMinimalMDX(directory);
  const std::string mixedOutput = directory + "/mixed-v1-v2.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(v10) + " --mdx " +
                                      quote(v20) + " --output " + quote(mixedOutput)).c_str()) == 0,
          "mixed v1/v2 inputs succeed");
  const std::string mixedJSON = readFile(mixedOutput);
  require(mixedJSON.find("\"metricsSupportStatus\":\"mixedVersions\"") !=
              std::string::npos &&
              mixedJSON.find("legacy-v10.mdx") == std::string::npos &&
              mixedJSON.find("synthetic-input.mdx") == std::string::npos,
          "mixed versions expose no input mapping");

  const std::string future = buildHeaderOnlyMDX(directory, "future.mdx", "3.0", "No");
  const std::string futureOutput = directory + "/future.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(future) + " --output " +
                                      quote(futureOutput)).c_str()) == 0,
          "future version is identified without metrics parsing");
  require(readFile(futureOutput).find(
              "\"metricsSupportStatus\":\"identifiedButUnsupportedVersion\"") !=
              std::string::npos,
          "future version has precise anonymous status");

  const std::string encryptedRecord = buildRecordMetadataMDX(
      directory, "encrypted-record.mdx", "1.0", "Yes", {{8, 3}});
  const std::string encryptedOutput = directory + "/encrypted-record.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(encryptedRecord) + " --output " +
                                      quote(encryptedOutput)).c_str()) == 0,
          "encrypted Record metadata is identified without payload access");
  const std::string encryptedJSON = readFile(encryptedOutput);
  require(encryptedJSON.find("\"encryptedMode\":1") != std::string::npos &&
              encryptedJSON.find("\"metricsSupportStatus\":\"identifiedButUnsupportedEncryption\"") !=
                  std::string::npos &&
              encryptedJSON.find("\"recordBlockCount\":1") != std::string::npos,
          "encrypted mode reports anonymous limited support");

  const std::string encryptedKeyInfo = buildRecordMetadataMDX(
      directory, "encrypted-key-info.mdx", "1.2", "2", {{8, 3}});
  const std::string encryptedKeyInfoOutput = directory + "/encrypted-key-info.json";
  require(std::system(probeCommand(probe, "--mdx " + quote(encryptedKeyInfo) + " --output " +
                                      quote(encryptedKeyInfoOutput)).c_str()) == 0,
          "encrypted key-info metadata is identified");
  require(readFile(encryptedKeyInfoOutput).find("\"encryptedMode\":2") !=
              std::string::npos,
          "encrypted key-info mode remains anonymous");

  const std::string malformedVersion = buildHeaderOnlyMDX(
      directory, "malformed-version.mdx", "not-a-version", "No");
  const std::string malformedVersionOutput = directory + "/malformed-version.json";
  const auto [malformedVersionStatus, malformedVersionError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(malformedVersion) + " --output " +
                              quote(malformedVersionOutput)));
  require(malformedVersionStatus != 0 && !exists(malformedVersionOutput) &&
              malformedVersionError.find("malformedVersion") != std::string::npos &&
              malformedVersionError.find(malformedVersion) == std::string::npos,
          "malformed version fails precisely without path");

  const std::string malformedEncryption = buildHeaderOnlyMDX(
      directory, "malformed-encryption.mdx", "1.0", "3");
  const std::string malformedEncryptionOutput = directory + "/malformed-encryption.json";
  const auto [malformedEncryptionStatus, malformedEncryptionError] = runCaptured(
      probeCommand(probe, "--mdx " + quote(malformedEncryption) + " --output " +
                              quote(malformedEncryptionOutput)));
  require(malformedEncryptionStatus != 0 && !exists(malformedEncryptionOutput) &&
              malformedEncryptionError.find("malformedEncryptedMode") != std::string::npos &&
              malformedEncryptionError.find(malformedEncryption) == std::string::npos,
          "malformed encrypted mode fails precisely without path");
  std::fprintf(stderr, "  version identification / legacy Record metadata: PASS\n");
}

void testLegacyRecordMetadataFailures(const std::string &directory, const std::string &probe) {
  const std::string truncated = buildRecordMetadataMDX(
      directory, "legacy-truncated.mdx", "1.0", "No", {{8, 3}}, 0, UINT64_MAX, 1);
  const std::string truncatedOutput = directory + "/legacy-truncated.json";
  const auto [truncatedStatus, truncatedErrors] = runCaptured(
      probeCommand(probe, "--mdx " + quote(truncated) + " --output " + quote(truncatedOutput)));
  require(truncatedStatus != 0 && !exists(truncatedOutput) &&
              truncatedErrors.find("truncatedFile") != std::string::npos,
          "v1 Record EOF minus one fails precisely");

  const std::string wrongShape = buildRecordMetadataMDX(
      directory, "legacy-wrong-shape.mdx", "1.0", "No", {{8, 3}}, 16);
  const std::string wrongShapeOutput = directory + "/legacy-wrong-shape.json";
  const auto [wrongShapeStatus, wrongShapeErrors] = runCaptured(
      probeCommand(probe, "--mdx " + quote(wrongShape) + " --output " + quote(wrongShapeOutput)));
  require(wrongShapeStatus != 0 && !exists(wrongShapeOutput) &&
              wrongShapeErrors.find("malformedRecordMetadata") != std::string::npos,
          "v1 Record table shape mismatch fails precisely");

  const std::string wrongTotal = buildRecordMetadataMDX(
      directory, "legacy-wrong-total.mdx", "1.0", "No", {{8, 3}}, 0, 7);
  const std::string wrongTotalOutput = directory + "/legacy-wrong-total.json";
  const auto [wrongTotalStatus, wrongTotalErrors] = runCaptured(
      probeCommand(probe, "--mdx " + quote(wrongTotal) + " --output " + quote(wrongTotalOutput)));
  require(wrongTotalStatus != 0 && !exists(wrongTotalOutput) &&
              wrongTotalErrors.find("malformedRecordMetadata") != std::string::npos,
          "v1 declared Record total mismatch fails precisely");

  const std::string overflow = buildRecordMetadataMDX(
      directory, "v2-overflow.mdx", "2.0", "Yes",
      {{UINT64_MAX, 1}, {UINT64_MAX, 1}}, 0, 0);
  const std::string overflowOutput = directory + "/v2-overflow.json";
  const auto [overflowStatus, overflowErrors] = runCaptured(
      probeCommand(probe, "--mdx " + quote(overflow) + " --output " + quote(overflowOutput)));
  require(overflowStatus != 0 && !exists(overflowOutput) &&
              overflowErrors.find("arithmeticOverflow") != std::string::npos,
          "Record compressed accumulator overflow fails precisely");

  const std::string decompressedOverflow = buildRecordMetadataMDX(
      directory, "v2-decompressed-overflow.mdx", "2.0", "Yes",
      {{1, UINT64_MAX}, {1, UINT64_MAX}}, 0, 2);
  const std::string decompressedOverflowOutput = directory + "/v2-decompressed-overflow.json";
  const auto [decompressedOverflowStatus, decompressedOverflowErrors] = runCaptured(
      probeCommand(probe, "--mdx " + quote(decompressedOverflow) + " --output " +
                              quote(decompressedOverflowOutput)));
  require(decompressedOverflowStatus != 0 && !exists(decompressedOverflowOutput) &&
              decompressedOverflowErrors.find("arithmeticOverflow") != std::string::npos,
          "Record decompressed accumulator overflow fails precisely");
  std::fprintf(stderr, "  legacy Record malformed metadata: PASS\n");
}

void testReleaseBinary(const std::string &directory) {
  const char *releasePath = std::getenv("MDICT_METRICS_PROBE_RELEASE_BIN");
  require(releasePath != nullptr && releasePath[0] != '\0', "release probe path provided");
  const std::string releaseProbe(releasePath);
  require(exists(releaseProbe), "release probe exists");
  const std::string mdx = buildMinimalMDX(directory);
  const std::string index = directory + "/release.sqlite";
  createEntriesDatabase(index, {{2, 10}});
  const std::string output = directory + "/release.json";
  require(std::system(probeCommand(releaseProbe, "--mdx " + quote(mdx) + " --sqlite " +
                                      quote(index) + " --output " + quote(output)).c_str()) == 0,
          "release probe succeeds");
  const std::string json = readFile(output);
  require(json.find("\"maximumRecordRangeBytes\":8") != std::string::npos,
          "release range output");
  require(json.find(mdx) == std::string::npos && json.find(index) == std::string::npos,
          "release output hides paths");
  const auto [nmStatus, symbols] = runCaptured("nm " + quote(releaseProbe));
  require(nmStatus == 0, "inspect release binary");
  require(symbols.find("__asan_") == std::string::npos &&
              symbols.find("__ubsan_") == std::string::npos,
          "release binary has no sanitizer symbols");
  const std::string releaseCompatibilityDirectory = directory + "/release-version-matrix";
  require(mkdir(releaseCompatibilityDirectory.c_str(), 0700) == 0,
          "create release version matrix workspace");
  testVersionIdentificationAndLegacyRecords(releaseCompatibilityDirectory, releaseProbe);
  testLegacyRecordMetadataFailures(releaseCompatibilityDirectory, releaseProbe);
  testChecksumDiagnosticsAndGoldenFixtures(releaseCompatibilityDirectory, releaseProbe);
  std::fprintf(stderr, "  release aggregate probe: PASS\n");
}

}  // namespace

int main() {
  const char *probeEnvironment = std::getenv("MDICT_METRICS_PROBE_BIN");
  const std::string probe = probeEnvironment ? probeEnvironment :
      ".build/mdict-resource-metrics-probe/MDictResourceMetricsProbe";
  require(exists(probe), "debug probe exists");

  std::string templatePath = std::string(std::getenv("TMPDIR") ? std::getenv("TMPDIR") : "/tmp") +
      "/mdict-record-metrics-smoke.XXXXXX";
  std::vector<char> mutableTemplate(templatePath.begin(), templatePath.end());
  mutableTemplate.push_back('\0');
  char *directory = mkdtemp(mutableTemplate.data());
  require(directory != nullptr, "create synthetic workspace");
  const std::string workDirectory(directory);

  std::fprintf(stderr, "MDictResourceMetricsProbeSmoke\n");
  testAggregateAndPrivacy(workDirectory, probe);
  testExplicitInputsOnly(workDirectory, probe);
  testSQLiteRangesAndFailures(workDirectory, probe);
  testMdxAndOutputFailures(workDirectory, probe);
  testChecksumDiagnosticsAndGoldenFixtures(workDirectory, probe);
  testVersionIdentificationAndLegacyRecords(workDirectory, probe);
  testLegacyRecordMetadataFailures(workDirectory, probe);
  testReleaseBinary(workDirectory);

  const std::string cleanup = "rm -rf " + quote(workDirectory);
  require(std::system(cleanup.c_str()) == 0, "remove synthetic workspace");
  std::fprintf(stderr, "MDictResourceMetricsProbeSmoke: %d total runtime assertions PASSED\n",
               gAssertions);
  return 0;
}
