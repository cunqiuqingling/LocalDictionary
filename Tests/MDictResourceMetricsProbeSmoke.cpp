// MDictResourceMetricsProbeSmoke – synthetic smoke test for the metrics probe.
//
// Creates a minimal valid MDX v2 file at runtime and verifies that the probe
// outputs correct anonymous metrics without leaking paths or content.
// Also tests error paths (missing file, malformed header, etc.).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#include "miniz.h"

static void require(bool cond, const char *msg) {
  if (!cond) { std::fprintf(stderr, "FAIL: %s\n", msg); std::exit(1); }
}

static std::string readFile(const char *path) {
  std::ifstream in(path, std::ios::binary);
  require(in.good(), "readFile open failed");
  return std::string((std::istreambuf_iterator<char>(in)),
                      std::istreambuf_iterator<char>());
}

static std::vector<uint8_t> zlibCompress(const void *data, size_t len) {
  mz_ulong bound = mz_compressBound(len);
  std::vector<uint8_t> out(bound);
  mz_ulong outLen = bound;
  int rc = mz_compress(out.data(), &outLen,
                       static_cast<const unsigned char *>(data), len);
  require(rc == MZ_OK, "zlib compress failed");
  out.resize(outLen);
  return out;
}

static uint32_t adler32bytes(const void *data, size_t len) {
  return static_cast<uint32_t>(
      mz_adler32(MZ_ADLER32_INIT, static_cast<const unsigned char *>(data), len));
}

static void writeBE32(std::vector<uint8_t> &buf, uint32_t v) {
  buf.push_back(static_cast<uint8_t>((v >> 24) & 0xff));
  buf.push_back(static_cast<uint8_t>((v >> 16) & 0xff));
  buf.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
  buf.push_back(static_cast<uint8_t>(v & 0xff));
}

static void writeBE64(std::vector<uint8_t> &buf, uint64_t v) {
  for (int i = 7; i >= 0; --i)
    buf.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xff));
}

static void writeBE16(std::vector<uint8_t> &buf, uint16_t v) {
  buf.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
  buf.push_back(static_cast<uint8_t>(v & 0xff));
}

static std::string buildMinimalMDX(const std::string &dir) {
  std::string path = dir + "/synthetic.mdx";

  const char *headerXML =
      "<Dictionary GeneratedByEngineVersion=\"2.0\" "
      "RequiredEngineVersion=\"2.0\" Encrypted=\"No\" Encoding=\"UTF-8\"/>";

  std::vector<uint8_t> headerUTF16;
  for (const char *p = headerXML; *p; ++p) {
    headerUTF16.push_back(static_cast<uint8_t>(*p));
    headerUTF16.push_back(0);
  }
  uint32_t header_bytes_size = static_cast<uint32_t>(headerUTF16.size());

  // Key block info (uncompressed): num_entries first_key_size first_key last_key_size last_key comp_size decomp_size
  std::vector<uint8_t> kbiRaw;
  writeBE64(kbiRaw, 2);  // num_entries
  writeBE16(kbiRaw, 3);  // first_key_size
  kbiRaw.push_back('a'); kbiRaw.push_back('a'); kbiRaw.push_back('a');
  kbiRaw.push_back(0);
  writeBE16(kbiRaw, 3);  // last_key_size
  kbiRaw.push_back('z'); kbiRaw.push_back('z'); kbiRaw.push_back('z');
  kbiRaw.push_back(0);
  size_t compOff = kbiRaw.size(); writeBE64(kbiRaw, 0); // placeholder comp
  size_t decompOff = kbiRaw.size(); writeBE64(kbiRaw, 0); // placeholder decomp

  // Key block (uncompressed): record_start + key + \0 per entry
  std::vector<uint8_t> kbRaw;
  writeBE64(kbRaw, 0);
  kbRaw.push_back('a'); kbRaw.push_back('a'); kbRaw.push_back('a'); kbRaw.push_back(0);
  writeBE64(kbRaw, 13);
  kbRaw.push_back('z'); kbRaw.push_back('z'); kbRaw.push_back('z'); kbRaw.push_back(0);

  auto kbComp = zlibCompress(kbRaw.data(), kbRaw.size());
  uint64_t kbCS = kbComp.size(), kbDS = kbRaw.size();
  for (int i = 0; i < 8; ++i) {
    kbiRaw[compOff + i] = static_cast<uint8_t>((kbCS >> ((7 - i) * 8)) & 0xff);
    kbiRaw[decompOff + i] = static_cast<uint8_t>((kbDS >> ((7 - i) * 8)) & 0xff);
  }

  auto kbiComp = zlibCompress(kbiRaw.data(), kbiRaw.size());

  // Record block: simple text
  std::string recContent = "record for aaa";
  recContent.push_back('\0');
  recContent += "record for zzz";
  recContent.push_back('\0');
  auto recComp = zlibCompress(recContent.data(), recContent.size());

  // Assemble key-block-info block: 4-byte comp_type + 4-byte adler32 + compressed
  std::vector<uint8_t> kbiBlock;
  kbiBlock.push_back(2); kbiBlock.push_back(0); kbiBlock.push_back(0); kbiBlock.push_back(0);
  writeBE32(kbiBlock, adler32bytes(kbiRaw.data(), kbiRaw.size()));
  kbiBlock.insert(kbiBlock.end(), kbiComp.begin(), kbiComp.end());

  // Key block full
  std::vector<uint8_t> kbFull;
  kbFull.push_back(2); kbFull.push_back(0); kbFull.push_back(0); kbFull.push_back(0);
  writeBE32(kbFull, adler32bytes(kbRaw.data(), kbRaw.size()));
  kbFull.insert(kbFull.end(), kbComp.begin(), kbComp.end());

  // Record block full
  std::vector<uint8_t> recFull;
  recFull.push_back(2); recFull.push_back(0); recFull.push_back(0); recFull.push_back(0);
  writeBE32(recFull, adler32bytes(recContent.data(), recContent.size()));
  recFull.insert(recFull.end(), recComp.begin(), recComp.end());

  // Record block info (uncompressed, 2x8)
  std::vector<uint8_t> recInfo;
  writeBE64(recInfo, recComp.size() + 8);
  writeBE64(recInfo, recContent.size());

  // Key block header adler32 (over first 40 bytes)
  std::vector<uint8_t> kbh;
  writeBE64(kbh, 1); writeBE64(kbh, 2);
  writeBE64(kbh, kbiRaw.size());
  writeBE64(kbh, kbiBlock.size());
  writeBE64(kbh, kbFull.size());

  // Write file
  std::vector<uint8_t> file;
  writeBE32(file, header_bytes_size);
  file.insert(file.end(), headerUTF16.begin(), headerUTF16.end());
  writeBE32(file, adler32bytes(headerUTF16.data(), headerUTF16.size()));
  file.insert(file.end(), kbh.begin(), kbh.end());
  writeBE32(file, adler32bytes(kbh.data(), kbh.size()));
  file.insert(file.end(), kbiBlock.begin(), kbiBlock.end());
  file.insert(file.end(), kbFull.begin(), kbFull.end());
  writeBE64(file, 1); writeBE64(file, 2);
  writeBE64(file, 16); writeBE64(file, recComp.size() + 8);
  file.insert(file.end(), recInfo.begin(), recInfo.end());
  file.insert(file.end(), recFull.begin(), recFull.end());

  std::ofstream out(path, std::ios::binary);
  require(out.good(), "write synthetic MDX failed");
  out.write(reinterpret_cast<const char *>(file.data()), static_cast<std::streamsize>(file.size()));
  require(out.good(), "write incomplete");
  return path;
}

// --- tests ---

static void test_happyPath(const std::string &workDir, const std::string &probeBin) {
  std::string mdxPath = buildMinimalMDX(workDir);
  std::string outPath = workDir + "/metrics.json";
  std::string cmd = probeBin + " --dictionary SYNTH \"" + mdxPath + "\" --output \"" + outPath + "\"";
  require(std::system(cmd.c_str()) == 0, "probe happy path failed");
  std::string json = readFile(outPath.c_str());
  require(json.find(mdxPath) == std::string::npos, "output leaked path");
  require(json.find("synthetic.mdx") == std::string::npos, "output leaked basename");
  require(json.find("record for aaa") == std::string::npos, "output leaked record");
  require(json.find("record for zzz") == std::string::npos, "output leaked record");
  require(json.find("\"schemaVersion\"") != std::string::npos, "missing schemaVersion");
  require(json.find("\"SYNTH\"") != std::string::npos, "missing SYNTH ID");
  require(json.find("\"entryCount\"") != std::string::npos, "missing entryCount");
  require(json.find("\"keyBlockCount\"") != std::string::npos, "missing keyBlockCount");
  require(json.find("\"recordBlockCount\"") != std::string::npos, "missing recordBlockCount");
  require(json.find("maximumSingleKeyBytes") != std::string::npos, "missing unavailable field");
  require(json.find("maximumObservedRecordRangeBytes") != std::string::npos, "missing unavailable field");
  std::fprintf(stderr, "  happy path: PASS\n");
}

static void test_missingFile(const std::string &workDir, const std::string &probeBin) {
  std::string outPath = workDir + "/missing.json";
  std::string cmd = probeBin + " --dictionary MISS \"" + workDir + "/no-file.mdx\" --output \"" + outPath + "\"";
  require(std::system(cmd.c_str()) == 0, "missing file: exit 0");
  std::string json = readFile(outPath.c_str());
  require(json.find("fileUnavailable") != std::string::npos, "missing fileUnavailable");
  std::fprintf(stderr, "  missing file: PASS\n");
}

static void test_truncatedFile(const std::string &workDir, const std::string &probeBin) {
  std::string mdxPath = workDir + "/truncated.mdx";
  {
    std::ofstream out(mdxPath, std::ios::binary);
    std::vector<uint8_t> tiny;
    writeBE32(tiny, 0x40000000);
    out.write(reinterpret_cast<const char *>(tiny.data()), 4);
  }
  std::string outPath = workDir + "/truncated.json";
  std::string cmd = probeBin + " --dictionary TRUNC \"" + mdxPath + "\" --output \"" + outPath + "\"";
  require(std::system(cmd.c_str()) == 0, "truncated exit 0");
  std::string json = readFile(outPath.c_str());
  require(json.find("invalidHeader") != std::string::npos ||
          json.find("malformedMetadata") != std::string::npos ||
          json.find("offsetOutOfBounds") != std::string::npos ||
          json.find("unsupportedVersion") != std::string::npos,
          "truncated missing error");
  require(json.find(mdxPath) == std::string::npos, "truncated leaked path");
  std::fprintf(stderr, "  truncated file: PASS\n");
}

static void test_overwriteProtection(const std::string &workDir, const std::string &probeBin) {
  std::string mdxPath = buildMinimalMDX(workDir);
  std::string outPath = workDir + "/protected.json";
  std::string cmd1 = probeBin + " --dictionary P1 \"" + mdxPath + "\" --output \"" + outPath + "\"";
  require(std::system(cmd1.c_str()) == 0, "first run failed");
  std::string cmd2 = probeBin + " --dictionary P2 \"" + mdxPath + "\" --output \"" + outPath + "\"";
  require(std::system(cmd2.c_str()) != 0, "overwrite not rejected");
  std::string cmd3 = probeBin + " --dictionary P3 \"" + mdxPath + "\" --output \"" + outPath + "\" --force";
  require(std::system(cmd3.c_str()) == 0, "--force failed");
  std::fprintf(stderr, "  overwrite protection: PASS\n");
}

static void test_outputPermissions(const std::string &workDir, const std::string &probeBin) {
  std::string mdxPath = buildMinimalMDX(workDir);
  std::string outPath = workDir + "/perm.json";
  std::string cmd = probeBin + " --dictionary PERM \"" + mdxPath + "\" --output \"" + outPath + "\"";
  require(std::system(cmd.c_str()) == 0, "perm probe failed");
  struct stat st;
  require(stat(outPath.c_str(), &st) == 0, "stat failed");
  require((st.st_mode & 0777) == 0600, "not 0600");
  std::fprintf(stderr, "  output permissions: PASS\n");
}

static void test_noSQLiteNoFormatter(const std::string & /*workDir*/, const std::string &probeBin) {
  std::string cmd = "nm \"" + probeBin + "\" 2>/dev/null";
  FILE *fp = popen(cmd.c_str(), "r");
  require(fp != nullptr, "nm failed");
  std::string symbols; char buf[4096];
  while (fgets(buf, sizeof(buf), fp)) symbols += buf;
  pclose(fp);
  require(symbols.find("sqlite3_") == std::string::npos, "probe links sqlite3");
  require(symbols.find("NSAutoreleasePool") == std::string::npos, "probe links Foundation");
  require(symbols.find("OBJC_CLASS") == std::string::npos, "probe links ObjC");
  std::fprintf(stderr, "  no SQLite / no Formatter: PASS\n");
}

int main() {
  const char *pb = std::getenv("MDICT_METRICS_PROBE_BIN");
  std::string probeBin = pb ? pb : (std::string(std::getenv("PROBE_BUILD_DIR") ?
    std::getenv("PROBE_BUILD_DIR") : ".build/mdict-resource-metrics-probe") + "/MDictResourceMetricsProbe");
  struct stat st;
  if (stat(probeBin.c_str(), &st) != 0) {
    std::fprintf(stderr, "Probe binary not found at %s\n", probeBin.c_str());
    return 1;
  }
  std::string tmpl = std::string(std::getenv("TMPDIR") ? std::getenv("TMPDIR") : "/tmp") + "/mdict-probe-smoke.XXXXXX";
  char *t = strdup(tmpl.c_str());
  char *wd = mkdtemp(t);
  require(wd != nullptr, "mkdtemp failed");
  std::string workDir(wd); free(t);
  std::fprintf(stderr, "MDictResourceMetricsProbeSmoke\n");
  test_happyPath(workDir, probeBin);
  test_missingFile(workDir, probeBin);
  test_truncatedFile(workDir, probeBin);
  test_overwriteProtection(workDir, probeBin);
  test_outputPermissions(workDir, probeBin);
  test_noSQLiteNoFormatter(workDir, probeBin);
  std::system(("rm -rf \"" + workDir + "\"").c_str());
  std::fprintf(stderr, "MDictResourceMetricsProbeSmoke: ALL PASSED\n");
  return 0;
}
