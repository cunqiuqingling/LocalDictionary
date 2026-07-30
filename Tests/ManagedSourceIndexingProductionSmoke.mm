#import <Foundation/Foundation.h>

#import "DictionaryCoreBridge.h"

#include "SQLiteDictionaryCore.h"
#include "Support/SyntheticMDictFixture.h"

#include <CommonCrypto/CommonDigest.h>
#include <sqlite3.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <future>
#include <stdexcept>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/resource.h>
#include <unistd.h>

namespace {

using localdict::testsupport::BuildSyntheticMDX;

class Harness {
 public:
  void Check(bool condition, const char *message) {
    ++assertions_;
    if (!condition) throw std::runtime_error(message);
  }

  int assertions() const { return assertions_; }

 private:
  int assertions_ = 0;
};

class TemporaryDirectory {
 public:
  TemporaryDirectory() {
    std::string pattern =
        (std::filesystem::temp_directory_path() /
         "LocalDictionary-managed-source-indexing.XXXXXX")
            .string();
    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    char *created = mkdtemp(writable.data());
    if (!created) throw std::runtime_error("mkdtemp failed");
    path_ = created;
  }

  ~TemporaryDirectory() {
    std::error_code ignored;
    std::filesystem::remove_all(path_, ignored);
  }

  const std::filesystem::path &path() const { return path_; }

 private:
  std::filesystem::path path_;
};

NSString *String(const std::filesystem::path &path) {
  return [NSString stringWithUTF8String:path.c_str()];
}

NSString *String(const std::string &value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

void WriteBytes(const std::filesystem::path &path,
                const std::vector<std::uint8_t> &bytes) {
  std::filesystem::create_directories(path.parent_path());
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output) throw std::runtime_error("cannot create synthetic source");
  output.write(reinterpret_cast<const char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  if (!output) throw std::runtime_error("cannot write synthetic source");
}

std::string SHA256(const std::vector<std::uint8_t> &bytes) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] {};
  if (!CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest)) {
    throw std::runtime_error("SHA-256 failed");
  }
  static constexpr char kHex[] = "0123456789abcdef";
  std::string result;
  result.reserve(CC_SHA256_DIGEST_LENGTH * 2);
  for (unsigned char byte : digest) {
    result.push_back(kHex[byte >> 4]);
    result.push_back(kHex[byte & 0x0f]);
  }
  return result;
}

bool ResultFlag(NSDictionary<NSString *, id> *result, NSString *key) {
  return [[result objectForKey:key] boolValue];
}

LocalDictionaryManagedSourceCapability *OpenSource(
    Harness &harness, const std::filesystem::path &root,
    const std::string &relative, const std::vector<std::uint8_t> &bytes) {
  NSDictionary<NSString *, id> *result = LocalDictionaryOpenManagedSource(
      String(root), String(relative),
      static_cast<unsigned long long>(bytes.size()), String(SHA256(bytes)),
      ^BOOL {
        return NO;
      });
  harness.Check(ResultFlag(result, @"success"),
                "production managed source open failed");
  auto *capability = static_cast<LocalDictionaryManagedSourceCapability *>(
      [result objectForKey:@"capability"]);
  harness.Check(capability != nil, "source open omitted capability");
  harness.Check(capability.sourceFileSize == bytes.size(),
                "capability size mismatch");
  harness.Check([capability.sourceSHA256 isEqualToString:String(SHA256(bytes))],
                "capability digest mismatch");
  return capability;
}

NSDictionary<NSString *, id> *Build(
    LocalDictionaryManagedSourceCapability *capability,
    const std::filesystem::path &candidate) {
  return LocalDictionaryBuildIndexFromManagedSource(
      capability, String(candidate), ^BOOL {
        return NO;
      });
}

std::string QueryMetadata(const std::filesystem::path &database_path,
                          const char *key) {
  sqlite3 *database = nullptr;
  if (sqlite3_open_v2(database_path.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                      nullptr) != SQLITE_OK) {
    if (database) sqlite3_close(database);
    throw std::runtime_error("cannot open candidate SQLite");
  }
  sqlite3_stmt *statement = nullptr;
  if (sqlite3_prepare_v2(
          database,
          "SELECT value FROM metadata WHERE key=?1 LIMIT 1", -1,
          &statement, nullptr) != SQLITE_OK) {
    sqlite3_close(database);
    throw std::runtime_error("cannot prepare metadata query");
  }
  sqlite3_bind_text(statement, 1, key, -1, SQLITE_STATIC);
  std::string value;
  if (sqlite3_step(statement) == SQLITE_ROW) {
    const auto *text = sqlite3_column_text(statement, 0);
    if (text) value = reinterpret_cast<const char *>(text);
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  return value;
}

std::size_t OpenDescriptorCount() {
  struct rlimit limit {};
  if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
    throw std::runtime_error("getrlimit failed");
  }
  const rlim_t maximum = std::min<rlim_t>(limit.rlim_cur, 16384);
  std::size_t count = 0;
  for (rlim_t descriptor = 0; descriptor < maximum; ++descriptor) {
    errno = 0;
    if (fcntl(static_cast<int>(descriptor), F_GETFD) != -1 ||
        errno != EBADF) {
      ++count;
    }
  }
  return count;
}

void TestNormalBuilds(Harness &harness,
                      const std::filesystem::path &root) {
  const auto bytes = BuildSyntheticMDX("managed-alpha", "managed-omega");
  const std::string local_relative =
      "Dictionaries/11111111-1111-4111-8111-111111111111/source/local.mdx";
  WriteBytes(root / local_relative, bytes);
  auto *local = OpenSource(harness, root, local_relative, bytes);
  const auto local_candidate = root / "local-candidate.sqlite";
  NSDictionary<NSString *, id> *local_result = Build(local, local_candidate);
  harness.Check(ResultFlag(local_result, @"success"),
                "managedLocal fd build failed");
  harness.Check(local.isValidForPublication,
                "managedLocal source lost identity after build");
  harness.Check(QueryMetadata(local_candidate, "source_name") == "local.mdx",
                "fd build metadata did not use explicit source name");
  harness.Check(QueryMetadata(local_candidate, "source_path") == "local.mdx",
                "fd build persisted a source pathname");
  const auto cancelled_candidate = root / "cancelled-candidate.sqlite";
  NSDictionary<NSString *, id> *cancelled_build =
      LocalDictionaryBuildIndexFromManagedSource(
          local, String(cancelled_candidate), ^BOOL {
            return YES;
          });
  harness.Check(ResultFlag(cancelled_build, @"cancelled"),
                "fd build cancellation did not propagate");
  harness.Check(!std::filesystem::exists(cancelled_candidate),
                "cancelled fd build left a candidate");

  const std::string resource_relative =
      "Dictionaries/22222222-2222-4222-8222-222222222222/payload.mdx";
  WriteBytes(root / resource_relative, bytes);
  auto *resource = OpenSource(harness, root, resource_relative, bytes);
  NSDictionary<NSString *, id> *resource_result =
      Build(resource, root / "resource-candidate.sqlite");
  harness.Check(ResultFlag(resource_result, @"success"),
                "openResource fd build failed");
  harness.Check(resource.isValidForPublication,
                "openResource source lost identity after build");
}

void TestExpectedIdentityFailures(Harness &harness,
                                  const std::filesystem::path &root) {
  const auto original = BuildSyntheticMDX("before-alpha", "before-omega", 64);
  auto replacement = original;
  replacement.back() ^= 0x5a;
  const std::string relative =
      "Dictionaries/33333333-3333-4333-8333-333333333333/source/source.mdx";
  WriteBytes(root / relative, replacement);

  NSDictionary<NSString *, id> *hash_result =
      LocalDictionaryOpenManagedSource(
          String(root), String(relative),
          static_cast<unsigned long long>(original.size()),
          String(SHA256(original)), ^BOOL {
            return NO;
          });
  harness.Check(!ResultFlag(hash_result, @"success"),
                "same-size replacement passed expected SHA");

  NSDictionary<NSString *, id> *size_result =
      LocalDictionaryOpenManagedSource(
          String(root), String(relative),
          static_cast<unsigned long long>(replacement.size() + 1),
          String(SHA256(replacement)), ^BOOL {
            return NO;
          });
  harness.Check(!ResultFlag(size_result, @"success"),
                "source size mismatch opened capability");

  __block int cancellation_checks = 0;
  const auto descriptors_before_cancel = OpenDescriptorCount();
  NSDictionary<NSString *, id> *cancelled =
      LocalDictionaryOpenManagedSource(
          String(root), String(relative),
          static_cast<unsigned long long>(replacement.size()),
          String(SHA256(replacement)), ^BOOL {
            ++cancellation_checks;
            return cancellation_checks > 1;
          });
  harness.Check(ResultFlag(cancelled, @"cancelled"),
                "hash cancellation did not propagate");
  harness.Check([cancelled objectForKey:@"capability"] == nil,
                "cancelled hash returned a capability");
  harness.Check(OpenDescriptorCount() == descriptors_before_cancel,
                "cancelled hash leaked a source descriptor");
}

void TestReplacementAfterOpen(Harness &harness,
                              const std::filesystem::path &root) {
  const auto bytes = BuildSyntheticMDX("held-alpha", "held-omega", 64);
  auto replacement = bytes;
  replacement.back() ^= 0x33;
  const std::string relative =
      "Dictionaries/44444444-4444-4444-8444-444444444444/source/source.mdx";
  const auto canonical = root / relative;
  WriteBytes(canonical, bytes);
  auto *capability = OpenSource(harness, root, relative, bytes);
  const auto held = canonical.parent_path() / "held.mdx";
  std::filesystem::rename(canonical, held);
  WriteBytes(canonical, replacement);

  const auto candidate = root / "replacement-candidate.sqlite";
  NSDictionary<NSString *, id> *result = Build(capability, candidate);
  harness.Check(ResultFlag(result, @"success"),
                "fd parser switched away from held inode");
  harness.Check(!capability.isValidForPublication,
                "canonical replacement passed post-build binding");
  harness.Check(QueryMetadata(candidate, "source_size") ==
                    std::to_string(bytes.size()),
                "fd build metadata switched to replacement source");
  std::filesystem::remove(candidate);
  harness.Check(!std::filesystem::exists(candidate),
                "rejected replacement candidate was not discarded");
}

void TestAncestorAndSymlinkFailures(
    Harness &harness, const std::filesystem::path &root) {
  const auto bytes = BuildSyntheticMDX("ancestor-alpha", "ancestor-omega");
  const std::string relative =
      "Dictionaries/55555555-5555-4555-8555-555555555555/source/source.mdx";
  const auto canonical = root / relative;
  WriteBytes(canonical, bytes);
  auto *capability = OpenSource(harness, root, relative, bytes);
  const auto ancestor = canonical.parent_path();
  const auto held = ancestor.parent_path() / "source-held";
  std::filesystem::rename(ancestor, held);
  WriteBytes(canonical, bytes);
  harness.Check(!capability.isValidForPublication,
                "ancestor replacement passed name binding");

  const auto symlink_target =
      root / "Dictionaries/66666666-6666-4666-8666-666666666666/real";
  WriteBytes(symlink_target / "source.mdx", bytes);
  const auto symlink_ancestor = symlink_target.parent_path() / "source";
  if (symlink(symlink_target.c_str(), symlink_ancestor.c_str()) != 0) {
    throw std::runtime_error("cannot create synthetic ancestor symlink");
  }
  NSDictionary<NSString *, id> *ancestor_result =
      LocalDictionaryOpenManagedSource(
          String(root),
          @"Dictionaries/66666666-6666-4666-8666-666666666666/source/source.mdx",
          static_cast<unsigned long long>(bytes.size()),
          String(SHA256(bytes)), ^BOOL {
            return NO;
          });
  harness.Check(!ResultFlag(ancestor_result, @"success"),
                "symlink ancestor opened capability");

  const auto file_root =
      root / "Dictionaries/77777777-7777-4777-8777-777777777777/source";
  WriteBytes(file_root / "real.mdx", bytes);
  if (symlink("real.mdx", (file_root / "linked.mdx").c_str()) != 0) {
    throw std::runtime_error("cannot create synthetic source symlink");
  }
  NSDictionary<NSString *, id> *file_result =
      LocalDictionaryOpenManagedSource(
          String(root),
          @"Dictionaries/77777777-7777-4777-8777-777777777777/source/linked.mdx",
          static_cast<unsigned long long>(bytes.size()),
          String(SHA256(bytes)), ^BOOL {
            return NO;
          });
  harness.Check(!ResultFlag(file_result, @"success"),
                "symlink source opened capability");

  const auto nonregular =
      root / "Dictionaries/88888888-8888-4888-8888-888888888888/source/not-file.mdx";
  std::filesystem::create_directories(nonregular);
  NSDictionary<NSString *, id> *directory_result =
      LocalDictionaryOpenManagedSource(
          String(root),
          @"Dictionaries/88888888-8888-4888-8888-888888888888/source/not-file.mdx",
          0, String(SHA256({})), ^BOOL {
            return NO;
          });
  harness.Check(!ResultFlag(directory_result, @"success"),
                "non-regular source opened capability");
}

void TestBuildFailureAndLegacyPath(Harness &harness,
                                   const std::filesystem::path &root) {
  const std::vector<std::uint8_t> malformed{'n', 'o', 't', 'm', 'd', 'x'};
  const std::string relative =
      "Dictionaries/99999999-9999-4999-8999-999999999999/source/bad.mdx";
  WriteBytes(root / relative, malformed);
  auto *capability = OpenSource(harness, root, relative, malformed);
  const auto candidate = root / "malformed-candidate.sqlite";
  NSDictionary<NSString *, id> *result = Build(capability, candidate);
  harness.Check(!ResultFlag(result, @"success"),
                "parser initialization failure reported success");
  harness.Check(!std::filesystem::exists(candidate),
                "failed fd build left a query-eligible candidate");
  harness.Check(!std::filesystem::exists(candidate.string() + ".building"),
                "failed fd build left a temporary candidate");

  const auto legacy_bytes =
      BuildSyntheticMDX("legacy-alpha", "legacy-omega");
  const auto legacy_source = root / "legacy-preferred.mdx";
  const auto legacy_index = root / "legacy-preferred.sqlite";
  WriteBytes(legacy_source, legacy_bytes);
  localdict::SQLiteDictionaryCore legacy(
      legacy_source.string(), legacy_index.string(), 0, 0);
  const auto legacy_result = legacy.buildIndex();
  harness.Check(legacy_result.entry_count == 2,
                "legacy path build API regressed");
}

void TestConcurrencyAndFDRecovery(Harness &harness,
                                  const std::filesystem::path &root) {
  const auto before = OpenDescriptorCount();
  const auto work = [&root](int sequence) {
    @autoreleasepool {
      Harness local;
      const auto bytes = BuildSyntheticMDX(
          "parallel-alpha-" + std::to_string(sequence),
          "parallel-omega-" + std::to_string(sequence));
      const std::string id =
          sequence == 1
              ? "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
              : "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      const std::string relative =
          "Dictionaries/" + id + "/source/source.mdx";
      WriteBytes(root / relative, bytes);
      auto *capability = OpenSource(local, root, relative, bytes);
      auto *result = Build(
          capability, root / ("parallel-" + std::to_string(sequence) +
                              ".sqlite"));
      if (!ResultFlag(result, @"success") ||
          !capability.isValidForPublication) {
        throw std::runtime_error("parallel capability crossed identity");
      }
      return local.assertions();
    }
  };
  auto first = std::async(std::launch::async, work, 1);
  auto second = std::async(std::launch::async, work, 2);
  harness.Check(first.get() == 4 && second.get() == 4,
                "parallel managed sources did not remain independent");
  @autoreleasepool {
    // Drain thread-local Objective-C owners before counting descriptors.
  }
  harness.Check(OpenDescriptorCount() == before,
                "source/parser descriptors leaked after all owners released");
}

void TestSealedPublicationAndManagedQuery(
    Harness &harness, const std::filesystem::path &root) {
  const std::string dictionary_id =
      "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const std::string publication_id =
      "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
  const std::string source_relative =
      "Dictionaries/" + dictionary_id + "/source/source.mdx";
  const std::string index_directory =
      "Dictionaries/" + dictionary_id + "/index";
  const std::string final_relative =
      index_directory + "/dictionary." + publication_id + ".sqlite";
  const auto bytes =
      BuildSyntheticMDX("sealed-alpha", "sealed-omega", 128);
  WriteBytes(root / source_relative, bytes);
  std::filesystem::create_directories(root / index_directory);
  auto *source = OpenSource(harness, root, source_relative, bytes);
  auto *created = LocalDictionaryCreateManagedIndexCandidate(
      String(root), String(index_directory), String(publication_id));
  harness.Check(ResultFlag(created, @"success"),
                "sealed candidate creation failed");
  auto *candidate =
      static_cast<LocalDictionarySealedIndexCapability *>(
          [created objectForKey:@"capability"]);
  harness.Check(candidate != nil && !candidate.isSealed,
                "candidate capability missing or prematurely sealed");
  auto *built = LocalDictionaryBuildManagedIndex(
      source, candidate, String(dictionary_id), String(SHA256(bytes)),
      bytes.size(), ^BOOL {
        return NO;
      });
  harness.Check(ResultFlag(built, @"success"),
                "managed candidate build failed");
  const auto entry_count =
      [[built objectForKey:@"entryCount"] unsignedLongLongValue];
  auto *sealed = LocalDictionarySealManagedIndex(
      candidate, String(dictionary_id), String(SHA256(bytes)), bytes.size(),
      LocalDictionaryIndexSchemaVersion(), entry_count);
  harness.Check(ResultFlag(sealed, @"success") && candidate.isSealed,
                "fd-bound candidate seal failed");
  harness.Check(candidate.indexSHA256.length == 64 &&
                    candidate.indexFileSize > 0,
                "sealed identity omitted digest or size");
  auto *published = LocalDictionaryPublishManagedIndex(candidate);
  harness.Check(ResultFlag(published, @"success"),
                "no-replace publication failed");
  auto *duplicate_created = LocalDictionaryCreateManagedIndexCandidate(
      String(root), String(index_directory), String(publication_id));
  harness.Check(ResultFlag(duplicate_created, @"success"),
                "duplicate-target setup candidate failed");
  auto *duplicate =
      static_cast<LocalDictionarySealedIndexCapability *>(
          [duplicate_created objectForKey:@"capability"]);
  auto *duplicate_built = LocalDictionaryBuildManagedIndex(
      source, duplicate, String(dictionary_id), String(SHA256(bytes)),
      bytes.size(), ^BOOL {
        return NO;
      });
  harness.Check(ResultFlag(duplicate_built, @"success"),
                "duplicate-target setup build failed");
  auto *duplicate_sealed = LocalDictionarySealManagedIndex(
      duplicate, String(dictionary_id), String(SHA256(bytes)), bytes.size(),
      LocalDictionaryIndexSchemaVersion(),
      [[duplicate_built objectForKey:@"entryCount"] unsignedLongLongValue]);
  harness.Check(ResultFlag(duplicate_sealed, @"success"),
                "duplicate-target setup seal failed");
  harness.Check(
      !ResultFlag(LocalDictionaryPublishManagedIndex(duplicate), @"success"),
      "no-replace publication overwrote an existing final");
  LocalDictionaryDiscardManagedIndex(duplicate);
  const auto startup_begin = std::chrono::steady_clock::now();
  harness.Check(LocalDictionaryValidatePublishedIndex(
                    String(root), String(final_relative),
                    String(dictionary_id), String(publication_id),
                    candidate.indexSHA256, candidate.indexFileSize,
                    String(SHA256(bytes)), bytes.size(),
                    LocalDictionaryIndexSchemaVersion(), entry_count),
                "published fd identity validation failed");
  const auto startup_end = std::chrono::steady_clock::now();

  const auto descriptors_before_runtime = OpenDescriptorCount();
  const auto memory_before_runtime = sqlite3_memory_used();
  const auto query_open_begin = std::chrono::steady_clock::now();
  DictionaryCoreBridge *runtime = [[DictionaryCoreBridge alloc]
      initManagedReadOnlyWithRootPath:String(root)
                   sourceRelativePath:String(source_relative)
                    indexRelativePath:String(final_relative)
                         dictionaryID:String(dictionary_id)
                        publicationID:String(publication_id)
                          indexSHA256:candidate.indexSHA256
                        indexFileSize:candidate.indexFileSize
                         sourceSHA256:String(SHA256(bytes))
                       sourceFileSize:bytes.size()
                        schemaVersion:LocalDictionaryIndexSchemaVersion()
                           entryCount:entry_count
                    cacheMaximumBytes:1024 * 1024
                  cacheMaximumEntries:16];
  const auto query_open_end = std::chrono::steady_clock::now();
  harness.Check(runtime.isReady, "managed fd/VFS runtime did not open");
  auto *lookup = [runtime lookup:@"aaa" maximumHTMLBytes:1024];
  harness.Check([[lookup objectForKey:@"found"] boolValue],
                "managed fd/VFS runtime lookup missed");
  const auto cache_begin = std::chrono::steady_clock::now();
  auto *cached_lookup = [runtime lookup:@"aaa" maximumHTMLBytes:1024];
  const auto cache_end = std::chrono::steady_clock::now();
  harness.Check([[cached_lookup objectForKey:@"cacheHit"] boolValue],
                "managed runtime cache hit was not retained");
  const auto descriptors_with_runtime = OpenDescriptorCount();
  const auto memory_with_runtime = sqlite3_memory_used();
  harness.Check(LocalDictionaryCommitManagedIndex(candidate),
                "post-Catalog final rebind failed");

  const auto final_path = root / final_relative;
  const auto held_path = final_path.string() + ".held";
  std::filesystem::rename(final_path, held_path);
  std::ifstream input(held_path, std::ios::binary);
  std::vector<std::uint8_t> replacement(
      (std::istreambuf_iterator<char>(input)),
      std::istreambuf_iterator<char>());
  replacement.back() ^= 0x5a;
  WriteBytes(final_path, replacement);
  auto *replaced_lookup =
      [runtime lookup:@"aaa" maximumHTMLBytes:1024];
  harness.Check([replaced_lookup objectForKey:@"error"] != nil,
                "cached runtime ignored final-name replacement");
  harness.Check(!LocalDictionaryValidatePublishedIndex(
                    String(root), String(final_relative),
                    String(dictionary_id), String(publication_id),
                    candidate.indexSHA256, candidate.indexFileSize,
                    String(SHA256(bytes)), bytes.size(),
                    LocalDictionaryIndexSchemaVersion(), entry_count),
                "same-size final replacement retained query eligibility");
  const auto elapsed_ms = [](auto begin, auto end) {
    return std::chrono::duration<double, std::milli>(end - begin).count();
  };
  std::printf(
      "sealed_index_metrics bytes=%llu first_sha_ms=%.3f "
      "vfs_validation_ms=%.3f second_sha_ms=%.3f startup_ms=%.3f "
      "query_open_ms=%.3f cache_hit_ms=%.3f extra_fds=%zu "
      "sqlite_heap_delta=%lld\n",
      candidate.indexFileSize,
      [[sealed objectForKey:@"firstSHA256Milliseconds"] doubleValue],
      [[sealed objectForKey:@"vfsValidationMilliseconds"] doubleValue],
      [[sealed objectForKey:@"secondSHA256Milliseconds"] doubleValue],
      elapsed_ms(startup_begin, startup_end),
      elapsed_ms(query_open_begin, query_open_end),
      elapsed_ms(cache_begin, cache_end),
      descriptors_with_runtime - descriptors_before_runtime,
      static_cast<long long>(memory_with_runtime - memory_before_runtime));
}

void TestMediumSealingPerformance(
    Harness &harness, const std::filesystem::path &root) {
  const std::string dictionary_id =
      "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const std::string publication_id =
      "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const std::string index_directory =
      "Dictionaries/" + dictionary_id + "/index";
  const std::string source_sha(64, 'a');
  std::filesystem::create_directories(root / index_directory);
  auto *created = LocalDictionaryCreateManagedIndexCandidate(
      String(root), String(index_directory), String(publication_id));
  harness.Check(ResultFlag(created, @"success"),
                "medium candidate creation failed");
  auto *candidate =
      static_cast<LocalDictionarySealedIndexCapability *>(
          [created objectForKey:@"capability"]);
  sqlite3 *database = nullptr;
  harness.Check(sqlite3_open_v2(
                    candidate.candidatePath.UTF8String, &database,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                    nullptr) == SQLITE_OK,
                "medium synthetic SQLite open failed");
  const auto exec = [&database](const char *sql) {
    if (sqlite3_exec(database, sql, nullptr, nullptr, nullptr) != SQLITE_OK) {
      throw std::runtime_error("medium synthetic SQLite statement failed");
    }
  };
  exec("PRAGMA journal_mode=OFF");
  exec("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)");
  exec("CREATE TABLE entries(id INTEGER PRIMARY KEY,headword TEXT NOT NULL,"
       "folded TEXT NOT NULL,record_start INTEGER NOT NULL,"
       "record_end INTEGER NOT NULL)");
  exec("INSERT INTO entries VALUES(1,'medium','medium',0,1)");
  exec("CREATE TABLE filler(payload BLOB)");
  exec("INSERT INTO filler VALUES(zeroblob(8388608))");
  const std::string metadata_sql =
      "INSERT INTO metadata VALUES"
      "('dictionary_id','" + dictionary_id + "'),"
      "('publication_id','" + publication_id + "'),"
      "('source_sha256','" + source_sha + "'),"
      "('source_size','1'),"
      "('schema_version','1'),"
      "('entry_count','1'),"
      "('engine_version','2.000000'),"
      "('builder_format_version','managed-fd-v1')";
  exec(metadata_sql.c_str());
  sqlite3_close(database);
  auto *sealed = LocalDictionarySealManagedIndex(
      candidate, String(dictionary_id), String(source_sha), 1, 1, 1);
  harness.Check(ResultFlag(sealed, @"success") &&
                    candidate.indexFileSize >= 8 * 1024 * 1024,
                "medium fd-bound seal failed");
  std::printf(
      "medium_seal_metrics bytes=%llu first_sha_ms=%.3f "
      "vfs_validation_ms=%.3f second_sha_ms=%.3f\n",
      candidate.indexFileSize,
      [[sealed objectForKey:@"firstSHA256Milliseconds"] doubleValue],
      [[sealed objectForKey:@"vfsValidationMilliseconds"] doubleValue],
      [[sealed objectForKey:@"secondSHA256Milliseconds"] doubleValue]);
  LocalDictionaryDiscardManagedIndex(candidate);
}

void TestCandidateFailureModes(
    Harness &harness, const std::filesystem::path &root) {
  const auto bytes = BuildSyntheticMDX("failure-alpha", "failure-omega");
  const std::string source_sha = SHA256(bytes);
  const auto exercise = [&](const std::string &dictionary_id,
                            const std::string &publication_id) {
    const std::string source_relative =
        "Dictionaries/" + dictionary_id + "/source/source.mdx";
    const std::string index_directory =
        "Dictionaries/" + dictionary_id + "/index";
    WriteBytes(root / source_relative, bytes);
    std::filesystem::create_directories(root / index_directory);
    auto *source = OpenSource(harness, root, source_relative, bytes);
    auto *created = LocalDictionaryCreateManagedIndexCandidate(
        String(root), String(index_directory), String(publication_id));
    harness.Check(ResultFlag(created, @"success"),
                  "failure-mode candidate creation failed");
    auto *candidate =
        static_cast<LocalDictionarySealedIndexCapability *>(
            [created objectForKey:@"capability"]);
    return std::make_pair(source, candidate);
  };

  @autoreleasepool {
    auto values = exercise(
        "10101010-1010-4010-8010-101010101010",
        "11111111-2222-4333-8444-555555555555");
    const auto held =
        std::filesystem::path(values.second.candidatePath.UTF8String)
            .string() + ".held";
    std::filesystem::rename(values.second.candidatePath.UTF8String, held);
    WriteBytes(values.second.candidatePath.UTF8String, {});
    auto *result = LocalDictionaryBuildManagedIndex(
        values.first, values.second,
        @"10101010-1010-4010-8010-101010101010",
        String(source_sha), bytes.size(), ^BOOL {
          return NO;
        });
    harness.Check(!ResultFlag(result, @"success"),
                  "same-size candidate replacement reached builder");
  }

  @autoreleasepool {
    auto values = exercise(
        "20202020-2020-4020-8020-202020202020",
        "22222222-3333-4444-8555-666666666666");
    const auto candidate =
        std::filesystem::path(values.second.candidatePath.UTF8String);
    const auto link = candidate.string() + ".link";
    if (::link(candidate.c_str(), link.c_str()) != 0) {
      throw std::runtime_error("candidate hard-link setup failed");
    }
    auto *result = LocalDictionaryBuildManagedIndex(
        values.first, values.second,
        @"20202020-2020-4020-8020-202020202020",
        String(source_sha), bytes.size(), ^BOOL {
          return NO;
        });
    harness.Check(!ResultFlag(result, @"success"),
                  "hard-linked candidate reached builder");
  }

  @autoreleasepool {
    auto values = exercise(
        "30303030-3030-4030-8030-303030303030",
        "33333333-4444-4555-8666-777777777777");
    auto *built = LocalDictionaryBuildManagedIndex(
        values.first, values.second,
        @"30303030-3030-4030-8030-303030303030",
        String(source_sha), bytes.size(), ^BOOL {
          return NO;
        });
    harness.Check(ResultFlag(built, @"success"),
                  "auxiliary-file setup build failed");
    WriteBytes(
        std::string(values.second.candidatePath.UTF8String) + "-wal",
        {'w', 'a', 'l'});
    auto *sealed = LocalDictionarySealManagedIndex(
        values.second, @"30303030-3030-4030-8030-303030303030",
        String(source_sha), bytes.size(),
        LocalDictionaryIndexSchemaVersion(),
        [[built objectForKey:@"entryCount"] unsignedLongLongValue]);
    harness.Check(!ResultFlag(sealed, @"success"),
                  "candidate with WAL auxiliary file sealed");
  }

  @autoreleasepool {
    auto values = exercise(
        "40404040-4040-4040-8040-404040404040",
        "44444444-5555-4666-8777-888888888888");
    auto *built = LocalDictionaryBuildManagedIndex(
        values.first, values.second,
        @"40404040-4040-4040-8040-404040404040",
        String(source_sha), bytes.size(), ^BOOL {
          return NO;
        });
    harness.Check(ResultFlag(built, @"success"),
                  "metadata-mismatch setup build failed");
    auto *sealed = LocalDictionarySealManagedIndex(
        values.second, @"40404040-4040-4040-8040-404040404040",
        String(std::string(64, 'f')), bytes.size(),
        LocalDictionaryIndexSchemaVersion(),
        [[built objectForKey:@"entryCount"] unsignedLongLongValue]);
    harness.Check(!ResultFlag(sealed, @"success"),
                  "source metadata mismatch sealed");
  }
}

}  // namespace

int main() {
  @autoreleasepool {
    try {
      Harness harness;
      TemporaryDirectory temporary;
      std::filesystem::create_directory(temporary.path() / "Dictionaries");
      TestNormalBuilds(harness, temporary.path());
      TestExpectedIdentityFailures(harness, temporary.path());
      TestReplacementAfterOpen(harness, temporary.path());
      TestAncestorAndSymlinkFailures(harness, temporary.path());
      TestBuildFailureAndLegacyPath(harness, temporary.path());
      TestConcurrencyAndFDRecovery(harness, temporary.path());
      TestSealedPublicationAndManagedQuery(harness, temporary.path());
      TestMediumSealingPerformance(harness, temporary.path());
      TestCandidateFailureModes(harness, temporary.path());
      std::printf(
          "ManagedSourceIndexingProductionSmoke assertions=%d PASS\n",
          harness.assertions());
      return 0;
    } catch (const std::exception &exception) {
      std::fprintf(stderr, "ManagedSourceIndexingProductionSmoke FAILED: %s\n",
                   exception.what());
      return 1;
    }
  }
}
