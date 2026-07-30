#include "SQLiteDictionaryCore.h"

#include "FDBoundSQLiteReadOnlyVFS.h"
#include "mdict.h"

#include <sqlite3.h>
#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace localdict {
namespace {
using Clock = std::chrono::steady_clock;
constexpr int kSchemaVersion = 1;

double milliseconds(Clock::time_point start, Clock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - start).count();
}

void checkSQLite(int result, sqlite3 *database, const char *operation) {
  if (result != SQLITE_OK && result != SQLITE_DONE && result != SQLITE_ROW) {
    const std::string message = database ? sqlite3_errmsg(database) : "unknown";
    throw std::runtime_error(std::string(operation) + ": " + message);
  }
}

void execute(sqlite3 *database, const char *sql) {
  char *error = nullptr;
  const int result = sqlite3_exec(database, sql, nullptr, nullptr, &error);
  if (result != SQLITE_OK) {
    const std::string message = error ? error : sqlite3_errmsg(database);
    sqlite3_free(error);
    throw std::runtime_error("SQLite execute: " + message);
  }
}

std::string asciiLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return c < 128 ? static_cast<char>(std::tolower(c)) : static_cast<char>(c);
  });
  return value;
}

bool startsWith(const std::string &value, const std::string &prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

bool endsWith(const std::string &value, const std::string &suffix) {
  return value.size() >= suffix.size() &&
         value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

IndexSourceMetadata sourceMetadata(const std::string &path) {
  struct stat status {};
  if (stat(path.c_str(), &status) != 0) {
    throw std::runtime_error("Cannot stat dictionary: " + path);
  }
  return {static_cast<uint64_t>(status.st_size), status.st_mtimespec.tv_sec,
          status.st_mtimespec.tv_nsec, static_cast<uint64_t>(status.st_ino),
          static_cast<uint64_t>(status.st_dev),
          std::filesystem::path(path).filename().string(), path};
}

std::string numberString(uint64_t value) { return std::to_string(value); }

std::string signedNumberString(int64_t value) { return std::to_string(value); }

void bindText(sqlite3_stmt *statement, int position, const std::string &value) {
  checkSQLite(sqlite3_bind_text(statement, position, value.data(),
                                static_cast<int>(value.size()), SQLITE_TRANSIENT),
              sqlite3_db_handle(statement), "bind text");
}

std::string metadataValue(sqlite3 *database, const char *key) {
  sqlite3_stmt *statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(
                  database,
                  "SELECT value FROM metadata WHERE key=?1 LIMIT 1",
                  -1, &statement, nullptr),
              database, "prepare metadata query");
  sqlite3_bind_text(statement, 1, key, -1, SQLITE_STATIC);
  std::string value;
  if (sqlite3_step(statement) == SQLITE_ROW) {
    const auto *text = sqlite3_column_text(statement, 0);
    if (text) value = reinterpret_cast<const char *>(text);
  }
  sqlite3_finalize(statement);
  return value;
}

void validateTableColumns(
    sqlite3 *database, const char *table,
    const std::vector<std::pair<std::string, std::string>> &expected) {
  const std::string sql = "PRAGMA table_info('" + std::string(table) + "')";
  sqlite3_stmt *statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(database, sql.c_str(), -1, &statement,
                                nullptr),
              database, "prepare schema inspection");
  std::size_t position = 0;
  while (sqlite3_step(statement) == SQLITE_ROW) {
    const auto *name = sqlite3_column_text(statement, 1);
    const auto *type = sqlite3_column_text(statement, 2);
    if (position >= expected.size() || !name || !type ||
        expected[position].first !=
            reinterpret_cast<const char *>(name) ||
        expected[position].second !=
            reinterpret_cast<const char *>(type)) {
      sqlite3_finalize(statement);
      throw std::runtime_error("Managed dictionary index schema mismatch");
    }
    ++position;
  }
  sqlite3_finalize(statement);
  if (position != expected.size()) {
    throw std::runtime_error("Managed dictionary index schema mismatch");
  }
}
}  // namespace

SQLiteDictionaryCore::SQLiteDictionaryCore(std::string dictionary_path,
                                           std::string index_path,
                                           size_t cache_maximum_bytes,
                                           size_t cache_maximum_entries)
    : dictionary_path_(std::move(dictionary_path)),
      index_path_(std::move(index_path)),
      cache_maximum_bytes_(cache_maximum_bytes),
      cache_maximum_entries_(cache_maximum_entries) {}

SQLiteDictionaryCore::~SQLiteDictionaryCore() { closeDatabase(); }

void SQLiteDictionaryCore::closeDatabase() {
  if (database_) {
    sqlite3_close(database_);
    database_ = nullptr;
  }
}

bool SQLiteDictionaryCore::indexMatchesDictionary() const {
  if (!std::filesystem::is_regular_file(index_path_)) return false;

  sqlite3 *database = nullptr;
  if (sqlite3_open_v2(index_path_.c_str(), &database,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nullptr) !=
      SQLITE_OK) {
    if (database) sqlite3_close(database);
    return false;
  }

  const IndexSourceMetadata source = sourceMetadata(dictionary_path_);
  const std::pair<const char *, std::string> expected[] = {
      {"schema_version", std::to_string(kSchemaVersion)},
      {"source_size", numberString(source.size)},
      {"source_mtime_seconds", signedNumberString(source.modified_seconds)},
      {"source_mtime_nanoseconds", signedNumberString(source.modified_nanoseconds)},
      {"source_inode", numberString(source.inode)},
      {"source_device", numberString(source.device)}};

  sqlite3_stmt *statement = nullptr;
  bool matches = sqlite3_prepare_v2(
                     database,
                     "SELECT value FROM metadata WHERE key = ?1 LIMIT 1", -1,
                     &statement, nullptr) == SQLITE_OK;
  for (const auto &item : expected) {
    if (!matches) break;
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
    sqlite3_bind_text(statement, 1, item.first, -1, SQLITE_STATIC);
    if (sqlite3_step(statement) != SQLITE_ROW) {
      matches = false;
      break;
    }
    const auto *text = sqlite3_column_text(statement, 0);
    if (!text || item.second != reinterpret_cast<const char *>(text)) {
      matches = false;
    }
  }
  sqlite3_finalize(statement);
  sqlite3_close(database);
  return matches;
}

IndexBuildResult SQLiteDictionaryCore::buildIndex(
    const std::function<bool()> &cancellation_check) {
  auto source = std::make_unique<mdict::Mdict>(dictionary_path_);
  return buildIndexWithSource(
      std::move(source), sourceMetadata(dictionary_path_),
      nullptr, false,
      cancellation_check);
}

IndexBuildResult SQLiteDictionaryCore::buildIndexFromFileDescriptor(
    int source_descriptor, const IndexSourceMetadata &source_metadata,
    const std::function<bool()> &cancellation_check) {
  auto source = mdict::Mdict::fromFileDescriptor(
      source_descriptor, mdict::MdictInputKind::mdx);
  return buildIndexWithSource(
      std::move(source), source_metadata, nullptr, false, cancellation_check);
}

IndexBuildResult SQLiteDictionaryCore::buildManagedIndexFromFileDescriptor(
    int source_descriptor, const IndexSourceMetadata &source_metadata,
    const PublishedIndexMetadata &published_metadata,
    const std::function<bool()> &cancellation_check) {
  auto source = mdict::Mdict::fromFileDescriptor(
      source_descriptor, mdict::MdictInputKind::mdx);
  return buildIndexWithSource(std::move(source), source_metadata,
                              &published_metadata, true,
                              cancellation_check);
}

IndexBuildResult SQLiteDictionaryCore::buildIndexWithSource(
    std::unique_ptr<mdict::Mdict> source_owner,
    const IndexSourceMetadata &source_metadata,
    const PublishedIndexMetadata *published_metadata,
    bool use_precreated_destination,
    const std::function<bool()> &cancellation_check) {
  const auto cancelled = [&cancellation_check]() {
    return cancellation_check && cancellation_check();
  };
  if (cancelled()) throw IndexBuildCancelled();
  const std::filesystem::path index_path(index_path_);
  std::filesystem::create_directories(index_path.parent_path());
  const std::filesystem::path temporary_path =
      use_precreated_destination ? index_path
                                 : std::filesystem::path(index_path.string() + ".building");
  std::error_code ignored;
  if (!use_precreated_destination) {
    std::filesystem::remove(temporary_path, ignored);
  }

  mdict::Mdict &source = *source_owner;
  source.init();
  if (cancelled()) throw IndexBuildCancelled();
  if (source.engineVersion() < 2.0f || source.dictionaryEncoding() != 0) {
    throw std::runtime_error("Phase 2 requires an unencrypted UTF-8 MDict v2 file");
  }
  const auto keys = source.keyList();
  const uint64_t record_stream_size = source.recordStreamSize();
  if (cancelled()) throw IndexBuildCancelled();

  sqlite3 *database = nullptr;
  checkSQLite(sqlite3_open_v2(temporary_path.c_str(), &database,
                              SQLITE_OPEN_READWRITE |
                                  (use_precreated_destination ? 0 : SQLITE_OPEN_CREATE) |
                                  SQLITE_OPEN_FULLMUTEX,
                              nullptr),
              database, "create index database");
  try {
    execute(database, "PRAGMA page_size=4096");
    execute(database, "PRAGMA journal_mode=OFF");
    execute(database, "PRAGMA synchronous=OFF");
    execute(database, "PRAGMA temp_store=MEMORY");
    execute(database,
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    execute(database,
            "CREATE TABLE entries (id INTEGER PRIMARY KEY, headword TEXT NOT NULL "
            "COLLATE BINARY, folded TEXT NOT NULL COLLATE BINARY, "
            "record_start INTEGER NOT NULL, record_end INTEGER NOT NULL)");
    execute(database, "BEGIN IMMEDIATE");

    sqlite3_stmt *insert_entry = nullptr;
    checkSQLite(sqlite3_prepare_v2(
                    database,
                    "INSERT INTO entries(headword, folded, record_start, record_end) "
                    "VALUES(?1, ?2, ?3, ?4)",
                    -1, &insert_entry, nullptr),
                database, "prepare entry insert");
    uint64_t inserted_entry_count = 0;
    for (size_t i = 0; i < keys.size(); ++i) {
      if ((i & 0xff) == 0 && cancelled()) throw IndexBuildCancelled();
      if (!keys[i]) continue;
      const uint64_t start = keys[i]->record_start;
      uint64_t end = record_stream_size;
      for (size_t next = i + 1; next < keys.size(); ++next) {
        if (keys[next] && keys[next]->record_start > start) {
          end = keys[next]->record_start;
          break;
        }
      }
      if (end <= start) continue;
      const std::string &headword = keys[i]->key_word;
      bindText(insert_entry, 1, headword);
      bindText(insert_entry, 2, asciiLower(headword));
      sqlite3_bind_int64(insert_entry, 3, static_cast<sqlite3_int64>(start));
      sqlite3_bind_int64(insert_entry, 4, static_cast<sqlite3_int64>(end));
      checkSQLite(sqlite3_step(insert_entry), database, "insert entry");
      ++inserted_entry_count;
      sqlite3_reset(insert_entry);
      sqlite3_clear_bindings(insert_entry);
    }
    sqlite3_finalize(insert_entry);

    if (cancelled()) throw IndexBuildCancelled();

    const std::pair<std::string, std::string> values[] = {
        {"schema_version", std::to_string(kSchemaVersion)},
        {"source_path", source_metadata.source_identifier},
        {"source_name", source_metadata.source_name},
        {"source_size", numberString(source_metadata.size)},
        {"source_mtime_seconds",
         signedNumberString(source_metadata.modified_seconds)},
        {"source_mtime_nanoseconds",
         signedNumberString(source_metadata.modified_nanoseconds)},
        {"source_inode", numberString(source_metadata.inode)},
        {"source_device", numberString(source_metadata.device)},
        {"entry_count", numberString(inserted_entry_count)},
        {"engine_version", std::to_string(source.engineVersion())},
        {"encoding", "UTF-8"}};
    sqlite3_stmt *insert_metadata = nullptr;
    checkSQLite(sqlite3_prepare_v2(
                    database, "INSERT INTO metadata(key, value) VALUES(?1, ?2)",
                    -1, &insert_metadata, nullptr),
                database, "prepare metadata insert");
    for (const auto &item : values) {
      bindText(insert_metadata, 1, item.first);
      bindText(insert_metadata, 2, item.second);
      checkSQLite(sqlite3_step(insert_metadata), database, "insert metadata");
      sqlite3_reset(insert_metadata);
      sqlite3_clear_bindings(insert_metadata);
    }
    if (published_metadata) {
      const std::pair<std::string, std::string> published_values[] = {
          {"dictionary_id", published_metadata->dictionary_id},
          {"publication_id", published_metadata->publication_id},
          {"source_sha256", published_metadata->source_sha256},
          {"builder_format_version",
           published_metadata->builder_format_version}};
      for (const auto &item : published_values) {
        bindText(insert_metadata, 1, item.first);
        bindText(insert_metadata, 2, item.second);
        checkSQLite(sqlite3_step(insert_metadata), database,
                    "insert published metadata");
        sqlite3_reset(insert_metadata);
        sqlite3_clear_bindings(insert_metadata);
      }
    }
    sqlite3_finalize(insert_metadata);
    if (cancelled()) throw IndexBuildCancelled();
    execute(database, "COMMIT");
    execute(database, "CREATE INDEX entries_headword ON entries(headword)");
    execute(database, "CREATE INDEX entries_folded ON entries(folded)");
    execute(database, "ANALYZE");
    sqlite3_close(database);
    database = nullptr;

    if (cancelled()) throw IndexBuildCancelled();
    if (!use_precreated_destination) {
      std::filesystem::remove(index_path, ignored);
      std::filesystem::rename(temporary_path, index_path);
    }
    return IndexBuildResult{inserted_entry_count};
  } catch (...) {
    if (database) sqlite3_close(database);
    if (!use_precreated_destination) {
      std::filesystem::remove(temporary_path, ignored);
    }
    throw;
  }
}

int SQLiteDictionaryCore::schemaVersion() { return kSchemaVersion; }

void SQLiteDictionaryCore::openReadOnlyIndex() {
  closeDatabase();
  checkSQLite(sqlite3_open_v2(index_path_.c_str(), &database_,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                              nullptr),
              database_, "open read-only index");
  execute(database_, "PRAGMA query_only=ON");
  validateTableColumns(
      database_, "metadata", {{"key", "TEXT"}, {"value", "TEXT"}});
  validateTableColumns(
      database_, "entries",
      {{"id", "INTEGER"}, {"headword", "TEXT"}, {"folded", "TEXT"},
       {"record_start", "INTEGER"}, {"record_end", "INTEGER"}});
}

IndexOpenResult SQLiteDictionaryCore::openExistingReadOnly() {
  const auto total_start = Clock::now();
  if (!std::filesystem::is_regular_file(dictionary_path_) ||
      !std::filesystem::is_regular_file(index_path_)) {
    throw std::runtime_error("Managed dictionary files are unavailable");
  }
  openReadOnlyIndex();

  sqlite3_stmt *schema_statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(
                  database_,
                  "SELECT value FROM metadata WHERE key='schema_version' LIMIT 1",
                  -1, &schema_statement, nullptr),
              database_, "prepare schema version");
  bool schema_matches = false;
  if (sqlite3_step(schema_statement) == SQLITE_ROW) {
    const auto *value = sqlite3_column_text(schema_statement, 0);
    schema_matches = value &&
        std::to_string(kSchemaVersion) == reinterpret_cast<const char *>(value);
  }
  sqlite3_finalize(schema_statement);
  if (!schema_matches) {
    closeDatabase();
    throw std::runtime_error("Managed dictionary index schema mismatch");
  }

  dictionary_ = std::make_unique<mdict::Mdict>(dictionary_path_);
  dictionary_->initMetadataOnly();

  IndexOpenResult result;
  sqlite3_stmt *statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(database_, "SELECT COUNT(*) FROM entries", -1,
                                &statement, nullptr),
              database_, "prepare entry count");
  if (sqlite3_step(statement) == SQLITE_ROW) {
    result.entry_count = static_cast<uint64_t>(sqlite3_column_int64(statement, 0));
  }
  sqlite3_finalize(statement);
  result.startup_milliseconds = milliseconds(total_start, Clock::now());
  return result;
}

IndexOpenResult SQLiteDictionaryCore::openManagedReadOnly(
    int source_descriptor,
    const fdsqlite::FDBoundReadOnlyFileCapability &index_capability,
    const PublishedIndexMetadata &expected_metadata) {
  const auto total_start = Clock::now();
  closeDatabase();
  if (fdsqlite::EnsureFDBoundReadOnlyVFSRegistered() != SQLITE_OK) {
    throw std::runtime_error("Cannot register fd-bound SQLite VFS");
  }
  fdsqlite::FDBoundRegisteredToken token(index_capability);
  checkSQLite(sqlite3_open_v2(
                  token.value().c_str(), &database_,
                  SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                  fdsqlite::FDBoundReadOnlyVFSName()),
              database_, "open fd-bound read-only index");
  execute(database_, "PRAGMA query_only=ON");
  validateTableColumns(
      database_, "metadata", {{"key", "TEXT"}, {"value", "TEXT"}});
  validateTableColumns(
      database_, "entries",
      {{"id", "INTEGER"}, {"headword", "TEXT"}, {"folded", "TEXT"},
       {"record_start", "INTEGER"}, {"record_end", "INTEGER"}});
  const std::pair<const char *, std::string> expected[] = {
      {"dictionary_id", expected_metadata.dictionary_id},
      {"publication_id", expected_metadata.publication_id},
      {"source_sha256", expected_metadata.source_sha256},
      {"source_size", numberString(expected_metadata.source_size)},
      {"schema_version", std::to_string(expected_metadata.schema_version)},
      {"entry_count", numberString(expected_metadata.entry_count)},
      {"builder_format_version", expected_metadata.builder_format_version}};
  for (const auto &item : expected) {
    if (metadataValue(database_, item.first) != item.second) {
      closeDatabase();
      throw std::runtime_error("Managed dictionary index metadata mismatch");
    }
  }
  sqlite3_stmt *statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(database_, "SELECT COUNT(*) FROM entries", -1,
                                &statement, nullptr),
              database_, "prepare entry count");
  uint64_t actual_entry_count = 0;
  if (sqlite3_step(statement) == SQLITE_ROW) {
    actual_entry_count =
        static_cast<uint64_t>(sqlite3_column_int64(statement, 0));
  }
  sqlite3_finalize(statement);
  if (actual_entry_count != expected_metadata.entry_count) {
    closeDatabase();
    throw std::runtime_error("Managed dictionary entry count mismatch");
  }
  auto dictionary = mdict::Mdict::fromFileDescriptor(
      source_descriptor, mdict::MdictInputKind::mdx);
  dictionary->initMetadataOnly();
  if (metadataValue(database_, "engine_version") !=
      std::to_string(dictionary->engineVersion())) {
    closeDatabase();
    throw std::runtime_error("Managed dictionary engine metadata mismatch");
  }
  dictionary_ = std::move(dictionary);
  IndexOpenResult result;
  result.entry_count = actual_entry_count;
  result.startup_milliseconds = milliseconds(total_start, Clock::now());
  return result;
}

IndexOpenResult SQLiteDictionaryCore::open(bool force_rebuild) {
  const auto total_start = Clock::now();
  IndexOpenResult result;
  if (force_rebuild || !indexMatchesDictionary()) {
    const auto index_start = Clock::now();
    buildIndex();
    result.index_milliseconds = milliseconds(index_start, Clock::now());
    result.rebuilt = true;
  }

  openReadOnlyIndex();
  dictionary_ = std::make_unique<mdict::Mdict>(dictionary_path_);
  dictionary_->initMetadataOnly();

  sqlite3_stmt *statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(database_, "SELECT COUNT(*) FROM entries", -1,
                                &statement, nullptr),
              database_, "prepare entry count");
  if (sqlite3_step(statement) == SQLITE_ROW) {
    result.entry_count = static_cast<uint64_t>(sqlite3_column_int64(statement, 0));
  }
  sqlite3_finalize(statement);
  result.startup_milliseconds = milliseconds(total_start, Clock::now());
  return result;
}

std::string SQLiteDictionaryCore::normalizeQuery(const std::string &input) {
  std::string value = input;
  while (!value.empty() &&
         std::isspace(static_cast<unsigned char>(value.front()))) {
    value.erase(value.begin());
  }
  while (!value.empty() &&
         std::isspace(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
  }

  const std::string leading[] = {"\"", "'", "(", "[", "{", "<", "“", "‘"};
  const std::string trailing[] = {".", ",", ";", ":", "!", "?", "\"", "'",
                                  ")", "]", "}", ">", "”", "’"};
  bool changed = true;
  while (changed && !value.empty()) {
    changed = false;
    for (const auto &token : leading) {
      if (startsWith(value, token)) {
        value.erase(0, token.size());
        changed = true;
        break;
      }
    }
    for (const auto &token : trailing) {
      if (endsWith(value, token)) {
        value.erase(value.size() - token.size());
        changed = true;
        break;
      }
    }
  }
  return value;
}

std::vector<SQLiteDictionaryCore::IndexedRecord>
SQLiteDictionaryCore::findRecords(const std::string &query, bool folded) const {
  const char *sql = folded
                        ? "SELECT headword, record_start, record_end FROM entries "
                          "WHERE folded = ?1 ORDER BY id LIMIT 16"
                        : "SELECT headword, record_start, record_end FROM entries "
                          "WHERE headword = ?1 COLLATE BINARY ORDER BY id LIMIT 16";
  sqlite3_stmt *statement = nullptr;
  checkSQLite(sqlite3_prepare_v2(database_, sql, -1, &statement, nullptr),
              database_, "prepare exact query");
  bindText(statement, 1, folded ? asciiLower(query) : query);
  std::vector<IndexedRecord> records;
  while (sqlite3_step(statement) == SQLITE_ROW) {
    const auto *headword = sqlite3_column_text(statement, 0);
    records.push_back({headword ? reinterpret_cast<const char *>(headword) : "",
                       static_cast<uint64_t>(sqlite3_column_int64(statement, 1)),
                       static_cast<uint64_t>(sqlite3_column_int64(statement, 2))});
  }
  sqlite3_finalize(statement);
  return records;
}

void SQLiteDictionaryCore::insertCache(const std::string &key,
                                       std::string value) {
  if (cache_maximum_entries_ == 0 || cache_maximum_bytes_ == 0 ||
      value.size() > cache_maximum_bytes_) {
    return;
  }
  while (!cache_lru_.empty() &&
         (cache_.size() >= cache_maximum_entries_ ||
          cache_bytes_ + value.size() > cache_maximum_bytes_)) {
    const std::string oldest = cache_lru_.back();
    cache_lru_.pop_back();
    const auto found = cache_.find(oldest);
    if (found != cache_.end()) {
      cache_bytes_ -= found->second.html.size();
      cache_.erase(found);
    }
  }
  cache_lru_.push_front(key);
  cache_bytes_ += value.size();
  cache_.emplace(key, CacheValue{std::move(value), cache_lru_.begin()});
}

std::string SQLiteDictionaryCore::readWithCache(const IndexedRecord &record,
                                                bool &cache_hit) {
  const std::string key = std::to_string(record.start) + ":" +
                          std::to_string(record.end);
  const auto found = cache_.find(key);
  if (found != cache_.end()) {
    cache_hit = true;
    cache_lru_.erase(found->second.position);
    cache_lru_.push_front(key);
    found->second.position = cache_lru_.begin();
    return found->second.html;
  }
  cache_hit = false;
  std::string html = dictionary_->readRecordAt(record.start, record.end);
  insertCache(key, html);
  return html;
}

LookupResult SQLiteDictionaryCore::lookup(const std::string &input,
                                          size_t maximum_html_bytes) {
  const auto start = Clock::now();
  LookupResult result;
  result.query = input;
  result.normalized_query = normalizeQuery(input);
  if (result.normalized_query.empty()) {
    result.milliseconds = milliseconds(start, Clock::now());
    return result;
  }

  auto records = findRecords(result.normalized_query, false);
  if (records.empty()) {
    records = findRecords(result.normalized_query, true);
    result.used_case_fallback = !records.empty();
  }
  for (const auto &record : records) {
    bool cache_hit = false;
    std::string html = readWithCache(record, cache_hit);
    if (!html.empty()) {
      if (maximum_html_bytes > 0 && html.size() > maximum_html_bytes) {
        size_t boundary = maximum_html_bytes;
        while (boundary > 0 && boundary < html.size() &&
               (static_cast<unsigned char>(html[boundary]) & 0xc0) == 0x80) {
          --boundary;
        }
        html.resize(boundary);
        result.html_truncated = true;
      }
      result.found = true;
      result.cache_hit = cache_hit;
      result.matched_headword = record.headword;
      result.html = std::move(html);
      break;
    }
  }
  result.milliseconds = milliseconds(start, Clock::now());
  return result;
}

CacheStats SQLiteDictionaryCore::cacheStats() const {
  return {cache_.size(), cache_bytes_, cache_maximum_entries_,
          cache_maximum_bytes_};
}

}  // namespace localdict
