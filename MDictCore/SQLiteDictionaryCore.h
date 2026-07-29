#pragma once

#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <list>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

struct sqlite3;

namespace mdict {
class Mdict;
}

namespace localdict {

struct IndexOpenResult {
  bool rebuilt = false;
  uint64_t entry_count = 0;
  double index_milliseconds = 0;
  double startup_milliseconds = 0;
};

struct LookupResult {
  bool found = false;
  bool used_case_fallback = false;
  bool cache_hit = false;
  std::string query;
  std::string normalized_query;
  std::string matched_headword;
  std::string html;
  bool html_truncated = false;
  double milliseconds = 0;
};

struct CacheStats {
  size_t entries = 0;
  size_t bytes = 0;
  size_t maximum_entries = 0;
  size_t maximum_bytes = 0;
};

struct IndexBuildResult {
  uint64_t entry_count = 0;
};

struct IndexSourceMetadata {
  uint64_t size = 0;
  int64_t modified_seconds = 0;
  int64_t modified_nanoseconds = 0;
  uint64_t inode = 0;
  uint64_t device = 0;
  std::string source_name;
  std::string source_identifier;
};

class IndexBuildCancelled final : public std::exception {
 public:
  const char *what() const noexcept override { return "index build cancelled"; }
};

class SQLiteDictionaryCore {
 public:
  SQLiteDictionaryCore(std::string dictionary_path, std::string index_path,
                       size_t cache_maximum_bytes = 8 * 1024 * 1024,
                       size_t cache_maximum_entries = 64);
  ~SQLiteDictionaryCore();

  SQLiteDictionaryCore(const SQLiteDictionaryCore &) = delete;
  SQLiteDictionaryCore &operator=(const SQLiteDictionaryCore &) = delete;

  IndexOpenResult open(bool force_rebuild = false);
  IndexOpenResult openExistingReadOnly();
  IndexBuildResult buildIndex(
      const std::function<bool()> &cancellation_check = {});
  IndexBuildResult buildIndexFromFileDescriptor(
      int source_descriptor, const IndexSourceMetadata &source_metadata,
      const std::function<bool()> &cancellation_check = {});
  LookupResult lookup(const std::string &input,
                      size_t maximum_html_bytes = 0);
  CacheStats cacheStats() const;

  static std::string normalizeQuery(const std::string &input);
  static int schemaVersion();

 private:
  struct IndexedRecord {
    std::string headword;
    uint64_t start = 0;
    uint64_t end = 0;
  };

  struct CacheValue {
    std::string html;
    std::list<std::string>::iterator position;
  };

  bool indexMatchesDictionary() const;
  void openReadOnlyIndex();
  std::vector<IndexedRecord> findRecords(const std::string &query,
                                         bool folded) const;
  std::string readWithCache(const IndexedRecord &record, bool &cache_hit);
  void insertCache(const std::string &key, std::string value);
  void closeDatabase();
  IndexBuildResult buildIndexWithSource(
      std::unique_ptr<mdict::Mdict> source,
      const IndexSourceMetadata &source_metadata,
      const std::function<bool()> &cancellation_check);

  std::string dictionary_path_;
  std::string index_path_;
  size_t cache_maximum_bytes_;
  size_t cache_maximum_entries_;
  size_t cache_bytes_ = 0;
  sqlite3 *database_ = nullptr;
  std::unique_ptr<mdict::Mdict> dictionary_;
  std::list<std::string> cache_lru_;
  std::unordered_map<std::string, CacheValue> cache_;
};

}  // namespace localdict
