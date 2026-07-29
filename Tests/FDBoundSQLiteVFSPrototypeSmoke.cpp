#include "FDBoundSQLiteReadOnlyVFS.h"

#include <sqlite3.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fcntl.h>
#include <functional>
#include <memory>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

using localdict::prototype::EnsureFDBoundReadOnlyVFSRegistered;
using localdict::prototype::FDBoundDirectoryCapability;
using localdict::prototype::FDBoundReadOnlyFileCapability;
using localdict::prototype::FDBoundReadOnlyVFSName;
using localdict::prototype::FDBoundReadOnlyVFSStatistics;
using localdict::prototype::FDBoundRegisteredToken;
using localdict::prototype::InvalidateFDBoundRegisteredDescriptorForTesting;
using localdict::prototype::ShutdownFDBoundReadOnlyVFS;

constexpr int kReadOnlyFlags =
    SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX |
    SQLITE_OPEN_PRIVATECACHE;

class Harness {
 public:
  void Check(bool condition, const std::string &message) {
    ++assertions_;
    if (!condition) throw std::runtime_error(message);
  }

  template <typename Action>
  void ExpectThrow(Action action, const std::string &message) {
    bool threw = false;
    try {
      action();
    } catch (...) {
      threw = true;
    }
    Check(threw, message);
  }

  int assertions() const { return assertions_; }

 private:
  int assertions_ = 0;
};

template <typename Action>
void RunPhase(const char *name, Action action) {
  try {
    action();
  } catch (const std::exception &error) {
    throw std::runtime_error(std::string(name) + ": " + error.what());
  }
}

class TemporaryDirectory {
 public:
  TemporaryDirectory() {
    std::string pattern =
        (std::filesystem::temp_directory_path() /
         "LocalDictionary-fd-vfs-prototype.XXXXXX")
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

class SQLiteConnection {
 public:
  SQLiteConnection() = default;
  explicit SQLiteConnection(sqlite3 *database) : database_(database) {}
  SQLiteConnection(SQLiteConnection &&other) noexcept
      : database_(std::exchange(other.database_, nullptr)) {}
  SQLiteConnection &operator=(SQLiteConnection &&other) noexcept {
    if (this == &other) return *this;
    Close();
    database_ = std::exchange(other.database_, nullptr);
    return *this;
  }
  ~SQLiteConnection() { Close(); }

  SQLiteConnection(const SQLiteConnection &) = delete;
  SQLiteConnection &operator=(const SQLiteConnection &) = delete;

  sqlite3 *get() const { return database_; }
  sqlite3 *release() { return std::exchange(database_, nullptr); }
  void Close() {
    if (!database_) return;
    sqlite3_close(database_);
    database_ = nullptr;
  }

 private:
  sqlite3 *database_ = nullptr;
};

void SQLiteRequire(int result, sqlite3 *database, const char *operation) {
  if (result == SQLITE_OK) return;
  const std::string detail =
      database ? sqlite3_errmsg(database) : sqlite3_errstr(result);
  throw std::runtime_error(std::string(operation) + ": " + detail);
}

void Execute(sqlite3 *database, const std::string &sql) {
  char *message = nullptr;
  const int result =
      sqlite3_exec(database, sql.c_str(), nullptr, nullptr, &message);
  if (result != SQLITE_OK) {
    const std::string detail =
        message ? message : sqlite3_errmsg(database);
    sqlite3_free(message);
    throw std::runtime_error("sqlite exec failed: " + detail);
  }
}

std::string QueryText(sqlite3 *database, const std::string &sql) {
  sqlite3_stmt *statement = nullptr;
  SQLiteRequire(sqlite3_prepare_v2(database, sql.c_str(), -1, &statement,
                                   nullptr),
                database, "prepare query");
  std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)> owned(
      statement, sqlite3_finalize);
  if (sqlite3_step(statement) != SQLITE_ROW) {
    throw std::runtime_error("query returned no row");
  }
  const auto *value = sqlite3_column_text(statement, 0);
  if (!value) throw std::runtime_error("query returned null");
  return reinterpret_cast<const char *>(value);
}

sqlite3_int64 QueryInt64(sqlite3 *database, const std::string &sql) {
  sqlite3_stmt *statement = nullptr;
  SQLiteRequire(sqlite3_prepare_v2(database, sql.c_str(), -1, &statement,
                                   nullptr),
                database, "prepare integer query");
  std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)> owned(
      statement, sqlite3_finalize);
  if (sqlite3_step(statement) != SQLITE_ROW) {
    throw std::runtime_error("integer query returned no row");
  }
  return sqlite3_column_int64(statement, 0);
}

void CreateDatabase(const std::filesystem::path &path,
                    const std::string &value,
                    std::size_t payload_bytes = 0,
                    bool wal_mode = false) {
  sqlite3 *raw = nullptr;
  SQLiteRequire(sqlite3_open_v2(
                    path.c_str(), &raw,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
                        SQLITE_OPEN_FULLMUTEX,
                    nullptr),
                raw, "create fixture");
  SQLiteConnection database(raw);
  Execute(database.get(), wal_mode ? "PRAGMA journal_mode=WAL"
                                   : "PRAGMA journal_mode=DELETE");
  Execute(database.get(), "PRAGMA page_size=4096");
  Execute(database.get(), "CREATE TABLE identity(value TEXT NOT NULL)");
  sqlite3_stmt *statement = nullptr;
  SQLiteRequire(sqlite3_prepare_v2(
                    database.get(),
                    "INSERT INTO identity(value) VALUES(?1)", -1,
                    &statement, nullptr),
                database.get(), "prepare identity insert");
  std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)> owned(
      statement, sqlite3_finalize);
  SQLiteRequire(sqlite3_bind_text(statement, 1, value.c_str(), -1,
                                  SQLITE_TRANSIENT),
                database.get(), "bind identity");
  if (sqlite3_step(statement) != SQLITE_DONE) {
    throw std::runtime_error("identity insert failed");
  }
  owned.reset();
  if (payload_bytes > 0) {
    Execute(database.get(),
            "CREATE TABLE payload(bytes BLOB NOT NULL)");
    Execute(database.get(),
            "INSERT INTO payload(bytes) VALUES(zeroblob(" +
                std::to_string(payload_bytes) + "))");
  }
  if (!wal_mode) Execute(database.get(), "VACUUM");
}

SQLiteConnection OpenCustom(const FDBoundReadOnlyFileCapability &capability,
                            std::string *consumed_token = nullptr) {
  FDBoundRegisteredToken token(capability);
  if (consumed_token) *consumed_token = token.value();
  sqlite3 *raw = nullptr;
  const int result =
      sqlite3_open_v2(token.value().c_str(), &raw, kReadOnlyFlags,
                      FDBoundReadOnlyVFSName());
  if (result != SQLITE_OK) {
    const auto statistics = FDBoundReadOnlyVFSStatistics();
    const std::string detail =
        raw ? sqlite3_errmsg(raw) : sqlite3_errstr(result);
    if (raw) sqlite3_close(raw);
    throw std::runtime_error(
        "open fd-bound database: " + detail +
        " registry=" + std::to_string(statistics.registry_entries) +
        " consumed=" + std::to_string(statistics.consumed_tokens) +
        " rejected_names=" + std::to_string(statistics.rejected_names) +
        " rejected_flags=" + std::to_string(statistics.rejected_flags) +
        " open_failures=" + std::to_string(statistics.open_failures));
  }
  SQLiteConnection database(raw);
  Execute(database.get(), "PRAGMA query_only=ON");
  Execute(database.get(), "PRAGMA mmap_size=0");
  return database;
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

int OpenDirectory(const std::filesystem::path &path) {
  const int descriptor =
      open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) throw std::runtime_error("open directory failed");
  return descriptor;
}

void TestBasicReadAndIntegrity(Harness &harness,
                               const FDBoundReadOnlyFileCapability &capability) {
  const auto before = FDBoundReadOnlyVFSStatistics();
  auto database = OpenCustom(capability);
  harness.Check(QueryText(database.get(),
                          "SELECT value FROM identity LIMIT 1") ==
                    "original",
                "fd-bound SELECT returned wrong value");
  harness.Check(QueryText(database.get(), "PRAGMA integrity_check") == "ok",
                "fd-bound integrity_check failed");
  harness.Check(QueryInt64(database.get(), "PRAGMA mmap_size") == 0,
                "prototype must keep SQLite mmap disabled");
  const auto during = FDBoundReadOnlyVFSStatistics();
  harness.Check(during.active_connections == before.active_connections + 1,
                "VFS did not account for active fd");
  database.Close();
  const auto after = FDBoundReadOnlyVFSStatistics();
  harness.Check(after.active_connections == before.active_connections,
                "VFS active connection leaked");
}

void TestPathReplacement(Harness &harness,
                         const std::filesystem::path &directory_path,
                         const FDBoundReadOnlyFileCapability &capability) {
  auto database = OpenCustom(capability);
  const auto original = directory_path / "dictionary.sqlite";
  const auto retained = directory_path / "retained.sqlite";
  const auto replacement = directory_path / "replacement.sqlite";
  const auto original_size = std::filesystem::file_size(original);
  const auto replacement_size = std::filesystem::file_size(replacement);
  harness.Check(original_size == replacement_size,
                "same-size replacement fixture sizes differ");
  std::filesystem::rename(original, retained);
  std::filesystem::rename(replacement, original);
  harness.Check(QueryText(database.get(),
                          "SELECT value FROM identity LIMIT 1") ==
                    "original",
                "connection switched to replacement path");
  harness.Check(!capability.NameStillMatches(),
                "name rebind did not detect replacement");

  sqlite3 *replacement_database = nullptr;
  SQLiteRequire(sqlite3_open_v2(original.c_str(), &replacement_database,
                                SQLITE_OPEN_READONLY, nullptr),
                replacement_database, "open replacement fixture");
  SQLiteConnection replacement_connection(replacement_database);
  harness.Check(QueryText(replacement_connection.get(),
                          "SELECT value FROM identity LIMIT 1") ==
                    "replaced",
                "canonical path does not contain replacement data");
}

void TestAncestorReplacement(
    Harness &harness, int root_fd, const std::filesystem::path &root_path,
    const FDBoundDirectoryCapability &directory,
    const FDBoundReadOnlyFileCapability &capability) {
  auto database = OpenCustom(capability);
  const auto old_path = root_path / "ancestor-retained";
  const auto current_path = root_path / "ancestor";
  std::filesystem::rename(current_path, old_path);
  std::filesystem::create_directory(current_path);
  CreateDatabase(current_path / "dictionary.sqlite", "new-root");
  harness.Check(!directory.NameStillMatches(),
                "directory name rebind missed ancestor replacement");
  harness.Check(!capability.NameStillMatches(),
                "file capability missed ancestor replacement");
  harness.Check(QueryText(database.get(),
                          "SELECT value FROM identity LIMIT 1") ==
                    "ancestor-original",
                "ancestor replacement switched open connection");
  struct stat value {};
  harness.Check(fstat(root_fd, &value) == 0,
                "root anchor fd became invalid");
}

void TestSymlinkAndOwnerRejection(
    Harness &harness, const FDBoundDirectoryCapability &directory,
    const std::filesystem::path &directory_path) {
  const auto link = directory_path / "linked.sqlite";
  if (symlink("dictionary.sqlite", link.c_str()) != 0) {
    throw std::runtime_error("symlink fixture failed");
  }
  harness.ExpectThrow(
      [&] {
        auto ignored =
            FDBoundReadOnlyFileCapability::OpenAt(directory, "linked.sqlite");
        (void)ignored;
      },
      "symlink input was accepted");
  harness.ExpectThrow(
      [&] {
        auto ignored = FDBoundReadOnlyFileCapability::OpenAt(
            directory, "dictionary.sqlite",
            static_cast<uid_t>(geteuid() + 1));
        (void)ignored;
      },
      "owner mismatch was accepted");
}

std::string InvalidToken() {
  return "/localdict-fd-vfs-prototype-" + std::string(64, '0');
}

void CloseFailedSQLite(sqlite3 *database) {
  if (database) sqlite3_close(database);
}

void TestTokenFailures(Harness &harness,
                       const FDBoundReadOnlyFileCapability &capability,
                       const std::filesystem::path &existing_ordinary_path) {
  const auto before = FDBoundReadOnlyVFSStatistics();
  harness.Check(capability.valid(),
                "capability fd invalid before token tests");
  harness.Check(capability.NameStillMatches(),
                "capability name invalid before token tests");
  sqlite3 *invalid_database = nullptr;
  const int invalid_result =
      sqlite3_open_v2(InvalidToken().c_str(), &invalid_database,
                      kReadOnlyFlags, FDBoundReadOnlyVFSName());
  harness.Check(invalid_result != SQLITE_OK,
                "unregistered token was accepted");
  CloseFailedSQLite(invalid_database);

  sqlite3 *path_database = nullptr;
  const int path_result =
      sqlite3_open_v2(existing_ordinary_path.c_str(), &path_database,
                      kReadOnlyFlags, FDBoundReadOnlyVFSName());
  harness.Check(path_result != SQLITE_OK,
                "custom VFS accepted an ordinary path");
  CloseFailedSQLite(path_database);

  std::string consumed;
  auto first = OpenCustom(capability, &consumed);
  sqlite3 *second = nullptr;
  const int reused_result =
      sqlite3_open_v2(consumed.c_str(), &second, kReadOnlyFlags,
                      FDBoundReadOnlyVFSName());
  harness.Check(reused_result != SQLITE_OK,
                "consumed token was accepted twice");
  CloseFailedSQLite(second);
  first.Close();

  const auto after = FDBoundReadOnlyVFSStatistics();
  harness.Check(after.registry_entries == before.registry_entries,
                "token failure test leaked registry entry");
  harness.Check(after.active_connections == before.active_connections,
                "token failure test leaked connection");
}

void TestEarlyCloseAndCancellation(
    Harness &harness, const FDBoundDirectoryCapability &directory) {
  auto closed =
      FDBoundReadOnlyFileCapability::OpenAt(directory, "dictionary.sqlite");
  closed.CloseDescriptorForTesting();
  closed.CloseDescriptorForTesting();
  harness.Check(!closed.valid(),
                "closed capability still reports valid");
  harness.ExpectThrow(
      [&] {
        FDBoundRegisteredToken ignored(closed);
        (void)ignored;
      },
      "closed capability registered successfully");

  auto invalidated =
      FDBoundReadOnlyFileCapability::OpenAt(directory, "dictionary.sqlite");
  const auto before_invalid = OpenDescriptorCount();
  FDBoundRegisteredToken token(invalidated);
  const std::string value = token.value();
  harness.Check(InvalidateFDBoundRegisteredDescriptorForTesting(value),
                "registry fd fault injection failed");
  sqlite3 *database = nullptr;
  const int result =
      sqlite3_open_v2(value.c_str(), &database, kReadOnlyFlags,
                      FDBoundReadOnlyVFSName());
  harness.Check(result != SQLITE_OK,
                "closed registry fd did not fail closed");
  CloseFailedSQLite(database);
  token.Cancel();
  harness.Check(FDBoundReadOnlyVFSStatistics().registry_entries == 0,
                "invalid registry entry leaked");
  harness.Check(OpenDescriptorCount() == before_invalid,
                "invalidated registry fd count is unexpected");

  const auto before_cancel = OpenDescriptorCount();
  {
    FDBoundRegisteredToken cancelled(invalidated);
    harness.Check(OpenDescriptorCount() == before_cancel + 1,
                  "registration did not own exactly one dup fd");
  }
  harness.Check(OpenDescriptorCount() == before_cancel,
                "unconsumed token cancellation leaked fd");
}

using AlignedVFSStorage = std::vector<std::max_align_t>;

int DirectVFSOpen(const std::string &token, int flags,
                  AlignedVFSStorage &storage,
                  sqlite3_file **file_out = nullptr) {
  sqlite3_vfs *vfs = sqlite3_vfs_find(FDBoundReadOnlyVFSName());
  if (!vfs) throw std::runtime_error("prototype VFS not registered");
  const std::size_t count =
      (static_cast<std::size_t>(vfs->szOsFile) +
       sizeof(std::max_align_t) - 1) /
      sizeof(std::max_align_t);
  storage.assign(count, std::max_align_t {});
  auto *file = reinterpret_cast<sqlite3_file *>(storage.data());
  int output_flags = 0;
  const int result =
      vfs->xOpen(vfs, token.c_str(), file, flags, &output_flags);
  if (file_out) *file_out = file;
  return result;
}

void TestReadOnlyAndAuxiliaryRejection(
    Harness &harness, const FDBoundReadOnlyFileCapability &capability) {
  {
    FDBoundRegisteredToken token(capability);
    sqlite3 *database = nullptr;
    const int result = sqlite3_open_v2(
        token.value().c_str(), &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        FDBoundReadOnlyVFSName());
    harness.Check(result != SQLITE_OK, "read-write open was accepted");
    CloseFailedSQLite(database);
    harness.Check(FDBoundReadOnlyVFSStatistics().registry_entries == 1,
                  "rejected write consumed token");
  }
  harness.Check(FDBoundReadOnlyVFSStatistics().registry_entries == 0,
                "write rejection leaked token");

  {
    FDBoundRegisteredToken token(capability);
    sqlite3 *database = nullptr;
    const int result =
        sqlite3_open_v2(token.value().c_str(), &database,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                        FDBoundReadOnlyVFSName());
    harness.Check(result != SQLITE_OK, "create open was accepted");
    CloseFailedSQLite(database);
  }

  const std::vector<int> auxiliary_flags = {
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
          SQLITE_OPEN_MAIN_JOURNAL,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_WAL,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
          SQLITE_OPEN_TEMP_JOURNAL,
  };
  for (int flags : auxiliary_flags) {
    FDBoundRegisteredToken token(capability);
    AlignedVFSStorage storage;
    harness.Check(DirectVFSOpen(token.value(), flags, storage) != SQLITE_OK,
                  "auxiliary VFS open was accepted");
    harness.Check(FDBoundReadOnlyVFSStatistics().registry_entries == 1,
                  "auxiliary rejection consumed token");
  }
  harness.Check(FDBoundReadOnlyVFSStatistics().registry_entries == 0,
                "auxiliary rejection leaked token");

  FDBoundRegisteredToken direct_token(capability);
  AlignedVFSStorage storage;
  sqlite3_file *file = nullptr;
  harness.Check(
      DirectVFSOpen(direct_token.value(),
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_MAIN_DB,
                    storage, &file) == SQLITE_OK,
      "direct read-only main database open failed");
  harness.Check(file->pMethods != nullptr &&
                    file->pMethods->iVersion == 1 &&
                    file->pMethods->xShmMap == nullptr &&
                    file->pMethods->xShmLock == nullptr,
                "VFS unexpectedly exposes SHM/WAL methods");
  harness.Check(file->pMethods->xClose(file) == SQLITE_OK,
                "direct close failed");
  harness.Check(file->pMethods->xClose(file) == SQLITE_OK,
                "duplicate close was not idempotent");
}

void TestShortReadAndFileSize(
    Harness &harness, const FDBoundReadOnlyFileCapability &capability) {
  FDBoundRegisteredToken token(capability);
  AlignedVFSStorage storage;
  sqlite3_file *file = nullptr;
  harness.Check(
      DirectVFSOpen(token.value(),
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_MAIN_DB,
                    storage, &file) == SQLITE_OK,
      "direct file open failed");
  sqlite3_int64 size = -1;
  harness.Check(file->pMethods->xFileSize(file, &size) == SQLITE_OK &&
                    size == capability.identity().size,
                "xFileSize reported wrong value");
  std::vector<unsigned char> bytes(64, 0xaa);
  const sqlite3_int64 offset = std::max<sqlite3_int64>(0, size - 16);
  harness.Check(file->pMethods->xRead(file, bytes.data(),
                                      static_cast<int>(bytes.size()),
                                      offset) == SQLITE_IOERR_SHORT_READ,
                "xRead did not report short EOF read");
  harness.Check(std::all_of(bytes.begin() + 16, bytes.end(),
                           [](unsigned char value) { return value == 0; }),
                "xRead did not zero-fill EOF tail");
  harness.Check(file->pMethods->xClose(file) == SQLITE_OK,
                "short-read file close failed");
}

void TestFDLifecycle(Harness &harness,
                     const FDBoundReadOnlyFileCapability &capability) {
  const auto baseline = OpenDescriptorCount();
  FDBoundRegisteredToken token(capability);
  harness.Check(OpenDescriptorCount() == baseline + 1,
                "registry token should own one dup fd");
  sqlite3 *raw = nullptr;
  SQLiteRequire(sqlite3_open_v2(token.value().c_str(), &raw,
                                kReadOnlyFlags,
                                FDBoundReadOnlyVFSName()),
                raw, "fd lifecycle open");
  SQLiteConnection database(raw);
  harness.Check(OpenDescriptorCount() == baseline + 1,
                "connection should take, not duplicate, registry fd");
  database.Close();
  harness.Check(OpenDescriptorCount() == baseline,
                "connection close did not restore fd count");
}

void TestIndependentConnections(
    Harness &harness,
    const FDBoundReadOnlyFileCapability &first_capability,
    const FDBoundReadOnlyFileCapability &second_capability) {
  auto first = OpenCustom(first_capability);
  auto second = OpenCustom(second_capability);
  harness.Check(QueryText(first.get(),
                          "SELECT value FROM identity LIMIT 1") ==
                    "connection-a",
                "first connection crossed fd identity");
  harness.Check(QueryText(second.get(),
                          "SELECT value FROM identity LIMIT 1") ==
                    "connection-b",
                "second connection crossed fd identity");
  first.Close();
  second.Close();
  harness.Check(FDBoundReadOnlyVFSStatistics().active_connections == 0,
                "independent connections leaked");
}

void TestConcurrentTokens(
    Harness &harness,
    const std::vector<std::unique_ptr<FDBoundReadOnlyFileCapability>>
        &capabilities) {
  std::atomic<int> failures {0};
  std::vector<std::thread> threads;
  for (std::size_t index = 0; index < capabilities.size(); ++index) {
    threads.emplace_back([&, index] {
      try {
        auto database = OpenCustom(*capabilities[index]);
        const std::string expected = "thread-" + std::to_string(index);
        if (QueryText(database.get(),
                      "SELECT value FROM identity LIMIT 1") != expected) {
          ++failures;
        }
      } catch (...) {
        ++failures;
      }
    });
  }
  for (auto &thread : threads) thread.join();
  harness.Check(failures.load() == 0,
                "concurrent token connections crossed or failed");
  const auto statistics = FDBoundReadOnlyVFSStatistics();
  harness.Check(statistics.registry_entries == 0 &&
                    statistics.active_connections == 0,
                "concurrent token test leaked resources");
}

struct OpenObservation {
  double average_microseconds = 0;
  int sqlite_cache_bytes = 0;
  sqlite3_int64 sqlite_memory_bytes = 0;
  std::uint64_t average_vfs_bytes_read = 0;
};

OpenObservation ObserveOpen(
    const FDBoundReadOnlyFileCapability &capability, int iterations) {
  std::vector<double> durations;
  durations.reserve(static_cast<std::size_t>(iterations));
  int cache_bytes = 0;
  sqlite3_int64 memory_before = 0;
  sqlite3_int64 memory_highwater = 0;
  sqlite3_status64(SQLITE_STATUS_MEMORY_USED, &memory_before,
                   &memory_highwater, 1);
  sqlite3_int64 maximum_memory = memory_before;
  const auto bytes_before = FDBoundReadOnlyVFSStatistics().bytes_read;
  for (int iteration = 0; iteration < iterations; ++iteration) {
    const auto start = std::chrono::steady_clock::now();
    auto database = OpenCustom(capability);
    (void)QueryText(database.get(),
                    "SELECT name FROM sqlite_schema ORDER BY name LIMIT 1");
    const auto end = std::chrono::steady_clock::now();
    durations.push_back(
        std::chrono::duration<double, std::micro>(end - start).count());
    int current_cache = 0;
    int ignored_highwater = 0;
    SQLiteRequire(
        sqlite3_db_status(database.get(), SQLITE_DBSTATUS_CACHE_USED,
                          &current_cache, &ignored_highwater, 0),
        database.get(), "read cache status");
    cache_bytes = std::max(cache_bytes, current_cache);
    sqlite3_int64 memory_during = 0;
    sqlite3_status64(SQLITE_STATUS_MEMORY_USED, &memory_during,
                     &memory_highwater, 0);
    maximum_memory = std::max(
        maximum_memory, std::max(memory_during, memory_highwater));
  }
  const double average =
      std::accumulate(durations.begin(), durations.end(), 0.0) /
      static_cast<double>(durations.size());
  const auto bytes_after = FDBoundReadOnlyVFSStatistics().bytes_read;
  return {average, cache_bytes,
          std::max<sqlite3_int64>(0, maximum_memory - memory_before),
          (bytes_after - bytes_before) /
              static_cast<std::uint64_t>(iterations)};
}

void TestWALRejection(Harness &harness,
                      const FDBoundReadOnlyFileCapability &capability) {
  FDBoundRegisteredToken token(capability);
  sqlite3 *raw = nullptr;
  const int open_result =
      sqlite3_open_v2(token.value().c_str(), &raw, kReadOnlyFlags,
                      FDBoundReadOnlyVFSName());
  if (open_result == SQLITE_OK) {
    sqlite3_stmt *statement = nullptr;
    const int prepare_result =
        sqlite3_prepare_v2(raw, "SELECT value FROM identity", -1,
                           &statement, nullptr);
    if (statement) sqlite3_finalize(statement);
    harness.Check(prepare_result != SQLITE_OK,
                  "WAL database was readable without SHM support");
  } else {
    harness.Check(true, "WAL database rejected at open");
  }
  CloseFailedSQLite(raw);
  harness.Check(FDBoundReadOnlyVFSStatistics().active_connections == 0,
                "WAL rejection leaked active fd");
}

}  // namespace

int main() {
  try {
    Harness harness;
    harness.Check(EnsureFDBoundReadOnlyVFSRegistered() == SQLITE_OK,
                  "prototype VFS registration failed");
    harness.Check(sqlite3_vfs_find(FDBoundReadOnlyVFSName()) != nullptr,
                  "prototype VFS is not discoverable");

    TemporaryDirectory temporary;
    const auto root = temporary.path();
    std::filesystem::create_directory(root / "basic");
    CreateDatabase(root / "basic/dictionary.sqlite", "original");
    CreateDatabase(root / "basic/replacement.sqlite", "replaced");
    const int root_fd = OpenDirectory(root);
    auto basic_directory =
        FDBoundDirectoryCapability::OpenAt(root_fd, "basic");
    auto basic_capability = FDBoundReadOnlyFileCapability::OpenAt(
        basic_directory, "dictionary.sqlite");
    harness.Check(basic_directory.NameStillMatches(),
                  "basic directory capability not rebound");
    harness.Check(basic_capability.NameStillMatches(),
                  "basic file capability not rebound");
    RunPhase("short read", [&] {
      TestShortReadAndFileSize(harness, basic_capability);
    });
    RunPhase("basic read", [&] {
      TestBasicReadAndIntegrity(harness, basic_capability);
    });
    RunPhase("symlink and owner", [&] {
      TestSymlinkAndOwnerRejection(harness, basic_directory,
                                   root / "basic");
    });
    RunPhase("token failures", [&] {
      TestTokenFailures(harness, basic_capability,
                        root / "basic/dictionary.sqlite");
    });
    RunPhase("early close", [&] {
      TestEarlyCloseAndCancellation(harness, basic_directory);
    });
    RunPhase("read-only rejection", [&] {
      TestReadOnlyAndAuxiliaryRejection(harness, basic_capability);
    });
    RunPhase("fd lifecycle", [&] {
      TestFDLifecycle(harness, basic_capability);
    });
    RunPhase("path replacement", [&] {
      TestPathReplacement(harness, root / "basic", basic_capability);
    });

    std::filesystem::create_directory(root / "ancestor");
    CreateDatabase(root / "ancestor/dictionary.sqlite",
                   "ancestor-original");
    auto ancestor_directory =
        FDBoundDirectoryCapability::OpenAt(root_fd, "ancestor");
    auto ancestor_capability = FDBoundReadOnlyFileCapability::OpenAt(
        ancestor_directory, "dictionary.sqlite");
    TestAncestorReplacement(harness, root_fd, root, ancestor_directory,
                            ancestor_capability);

    std::filesystem::create_directory(root / "independent");
    CreateDatabase(root / "independent/a.sqlite", "connection-a");
    CreateDatabase(root / "independent/b.sqlite", "connection-b");
    auto independent_directory =
        FDBoundDirectoryCapability::OpenAt(root_fd, "independent");
    auto first_capability = FDBoundReadOnlyFileCapability::OpenAt(
        independent_directory, "a.sqlite");
    auto second_capability = FDBoundReadOnlyFileCapability::OpenAt(
        independent_directory, "b.sqlite");
    TestIndependentConnections(harness, first_capability,
                               second_capability);

    std::filesystem::create_directory(root / "concurrent");
    auto concurrent_directory =
        FDBoundDirectoryCapability::OpenAt(root_fd, "concurrent");
    std::vector<std::unique_ptr<FDBoundReadOnlyFileCapability>>
        concurrent_capabilities;
    for (int index = 0; index < 8; ++index) {
      const std::string name = "thread-" + std::to_string(index) + ".sqlite";
      CreateDatabase(root / "concurrent" / name,
                     "thread-" + std::to_string(index));
      concurrent_capabilities.push_back(
          std::make_unique<FDBoundReadOnlyFileCapability>(
              FDBoundReadOnlyFileCapability::OpenAt(
                  concurrent_directory, name)));
    }
    TestConcurrentTokens(harness, concurrent_capabilities);

    std::filesystem::create_directory(root / "wal");
    CreateDatabase(root / "wal/dictionary.sqlite", "wal-data", 0, true);
    auto wal_directory =
        FDBoundDirectoryCapability::OpenAt(root_fd, "wal");
    auto wal_capability = FDBoundReadOnlyFileCapability::OpenAt(
        wal_directory, "dictionary.sqlite");
    TestWALRejection(harness, wal_capability);

    std::filesystem::create_directory(root / "performance");
    CreateDatabase(root / "performance/small.sqlite", "small");
    constexpr std::size_t kMediumPayloadBytes = 8 * 1024 * 1024;
    CreateDatabase(root / "performance/medium.sqlite", "medium",
                   kMediumPayloadBytes);
    auto performance_directory =
        FDBoundDirectoryCapability::OpenAt(root_fd, "performance");
    auto small_capability = FDBoundReadOnlyFileCapability::OpenAt(
        performance_directory, "small.sqlite");
    auto medium_capability = FDBoundReadOnlyFileCapability::OpenAt(
        performance_directory, "medium.sqlite");
    const auto small_observation = ObserveOpen(small_capability, 20);
    const auto medium_observation = ObserveOpen(medium_capability, 20);
    harness.Check(
        medium_observation.sqlite_cache_bytes <
            static_cast<int>(kMediumPayloadBytes / 4),
        "SQLite cache suggests whole medium database copy");
    harness.Check(
        medium_observation.sqlite_memory_bytes <
            static_cast<sqlite3_int64>(kMediumPayloadBytes / 4),
        "SQLite allocator suggests whole medium database copy");
    harness.Check(
        medium_observation.average_vfs_bytes_read <
            static_cast<std::uint64_t>(kMediumPayloadBytes / 4),
        "VFS reads suggest whole medium database copy");

    close(root_fd);
    const auto final_statistics = FDBoundReadOnlyVFSStatistics();
    harness.Check(final_statistics.registry_entries == 0,
                  "final registry entries leaked");
    harness.Check(final_statistics.active_connections == 0,
                  "final active connections leaked");
    harness.Check(final_statistics.consumed_tokens > 0,
                  "VFS never consumed a registered token");
    harness.Check(final_statistics.rejected_names >= 1,
                  "VFS did not record rejected names");
    harness.Check(final_statistics.open_failures >= 2,
                  "VFS did not record invalid/consumed token failures");
    harness.Check(final_statistics.rejected_flags >= 5,
                  "VFS did not record rejected flags");
    harness.Check(final_statistics.bytes_read > 0,
                  "VFS did not serve bytes from fd");
    harness.Check(ShutdownFDBoundReadOnlyVFS() == SQLITE_OK,
                  "prototype VFS shutdown failed");

    std::printf(
        "FDBoundSQLiteVFSPrototypeSmoke passed assertions=%d "
        "small_bytes=%lld medium_bytes=%lld "
        "small_open_us=%.2f medium_open_us=%.2f "
        "small_cache_bytes=%d medium_cache_bytes=%d "
        "small_sqlite_memory_delta=%lld medium_sqlite_memory_delta=%lld "
        "small_vfs_bytes_per_open=%llu medium_vfs_bytes_per_open=%llu "
        "extra_fd_per_connection=1 mmap=disabled "
        "consumed=%llu rejected_names=%llu rejected_flags=%llu "
        "closed=%llu bytes_read=%llu\n",
        harness.assertions(),
        static_cast<long long>(small_capability.identity().size),
        static_cast<long long>(medium_capability.identity().size),
        small_observation.average_microseconds,
        medium_observation.average_microseconds,
        small_observation.sqlite_cache_bytes,
        medium_observation.sqlite_cache_bytes,
        static_cast<long long>(
            small_observation.sqlite_memory_bytes),
        static_cast<long long>(
            medium_observation.sqlite_memory_bytes),
        static_cast<unsigned long long>(
            small_observation.average_vfs_bytes_read),
        static_cast<unsigned long long>(
            medium_observation.average_vfs_bytes_read),
        static_cast<unsigned long long>(
            final_statistics.consumed_tokens),
        static_cast<unsigned long long>(
            final_statistics.rejected_names),
        static_cast<unsigned long long>(
            final_statistics.rejected_flags),
        static_cast<unsigned long long>(final_statistics.closed_files),
        static_cast<unsigned long long>(final_statistics.bytes_read));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "FDBoundSQLiteVFSPrototypeSmoke failed: %s\n",
                 error.what());
    return 1;
  }
}
