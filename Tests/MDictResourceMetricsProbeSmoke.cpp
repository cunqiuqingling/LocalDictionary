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

void writeBE64(std::vector<uint8_t> &bytes, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
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
  writeBE32(file, adler32Bytes(headerUTF16.data(), headerUTF16.size()));
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

void testAggregateAndPrivacy(const std::string &directory, const std::string &probe) {
  const std::string mdx = buildMinimalMDX(directory);
  const std::string index = directory + "/synthetic-ranges.sqlite";
  createEntriesDatabase(index, {{0, 3}, {7, 20}, {20, 20}});
  const std::string output = directory + "/aggregate.json";
  const uint64_t mdxHash = fingerprint(mdx);
  const uint64_t mdxSize = fileSize(mdx);
  const uint64_t sqliteHash = fingerprint(index);
  const uint64_t sqliteSize = fileSize(index);

  require(std::system(probeCommand(probe, "--mdx " + quote(mdx) + " --sqlite " +
                                      quote(index) + " --output " + quote(output)).c_str()) == 0,
          "aggregate probe succeeds");
  const std::string json = readFile(output);
  require(json.find("\"schemaVersion\":2") != std::string::npos, "schema version 2");
  require(json.find("\"maximumRecordRangeBytes\":13") != std::string::npos,
          "maximum record range");
  require(json.find("\"recordBlockInfoBytes\":") != std::string::npos,
          "legacy record info field retained");
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
  require(json.find("SHA") == std::string::npos && json.find("sha") == std::string::npos,
          "output hides hashes");
  require(fingerprint(mdx) == mdxHash && fileSize(mdx) == mdxSize,
          "MDX input unchanged");
  require(fingerprint(index) == sqliteHash && fileSize(index) == sqliteSize,
          "SQLite input unchanged");
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
  testReleaseBinary(workDirectory);

  const std::string cleanup = "rm -rf " + quote(workDirectory);
  require(std::system(cleanup.c_str()) == 0, "remove synthetic workspace");
  std::fprintf(stderr, "MDictResourceMetricsProbeSmoke: %d total runtime assertions PASSED\n",
               gAssertions);
  return 0;
}
