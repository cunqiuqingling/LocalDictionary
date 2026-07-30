#import "DictionaryCoreBridge.h"

#include "ManagedMDictSource.h"
#include "FDBoundSQLiteReadOnlyVFS.h"
#include "SQLiteDictionaryCore.h"

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sqlite3.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

class DictionaryBridgeStorage {
 public:
  std::unique_ptr<localdict::SQLiteDictionaryCore> core;
  std::unique_ptr<localdict::MDictSourceCapability> managed_source;
  std::unique_ptr<localdict::fdsqlite::FDBoundReadOnlyFileCapability>
      managed_index;
  std::string error;
};

struct ManagedSourceBridgeStorage {
  explicit ManagedSourceBridgeStorage(
      localdict::MDictSourceCapability source_value)
      : source(std::move(source_value)) {}

  localdict::MDictSourceCapability source;
};

struct SealedIndexBridgeStorage {
  std::unique_ptr<localdict::fdsqlite::FDBoundDirectoryCapability> directory;
  std::unique_ptr<localdict::fdsqlite::FDBoundReadOnlyFileCapability> readonly;
  int writable_descriptor = -1;
  dev_t device = 0;
  ino_t inode = 0;
  uid_t owner = 0;
  std::string candidate_name;
  std::string final_name;
  std::string current_name;
  std::string candidate_path;
  std::string publication_id;
  std::string sha256;
  uint64_t size = 0;
  bool published = false;
  bool committed = false;

  ~SealedIndexBridgeStorage() {
    if (writable_descriptor >= 0) close(writable_descriptor);
  }
};

namespace {
std::string utf8(NSString *value) {
  const char *bytes = value.UTF8String;
  return bytes ? std::string(bytes) : std::string();
}

NSString *string(const std::string &value) {
  NSString *result = [[NSString alloc] initWithBytes:value.data()
                                              length:value.size()
                                            encoding:NSUTF8StringEncoding];
  return result ?: @"";
}

NSString *sanitizedIndexBuildError() {
  return @"索引核心无法处理此 MDX 文件。";
}

NSDictionary<NSString *, id> *sourceFailure(NSString *kind) {
  return @{ @"success" : @NO, @"cancelled" : @NO,
            @"errorKind" : kind };
}

bool safeComponent(const std::string &value) {
  return !value.empty() && value != "." && value != ".." &&
      value.find('/') == std::string::npos &&
      value.find('\\') == std::string::npos &&
      value.find('\0') == std::string::npos;
}

bool canonicalLowercaseUUID(NSString *value) {
  if (value.length == 0) return false;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
  return uuid != nil &&
      [uuid.UUIDString.lowercaseString isEqualToString:value];
}

std::vector<std::string> relativeComponents(const std::string &path) {
  if (path.empty() || path.front() == '/') {
    throw std::runtime_error("unsafe relative path");
  }
  std::vector<std::string> result;
  std::size_t start = 0;
  while (start <= path.size()) {
    const auto slash = path.find('/', start);
    const auto item = path.substr(
        start, slash == std::string::npos ? std::string::npos : slash - start);
    if (!safeComponent(item)) throw std::runtime_error("unsafe path component");
    result.push_back(item);
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return result;
}

std::unique_ptr<localdict::fdsqlite::FDBoundDirectoryCapability>
openDirectoryRelative(const std::string &root_path,
                      const std::string &relative_path) {
  const int root = open(root_path.c_str(),
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root < 0) throw std::runtime_error("cannot open managed root");
  struct stat root_status {};
  if (fstat(root, &root_status) != 0 ||
      (root_status.st_mode & S_IFMT) != S_IFDIR ||
      root_status.st_uid != geteuid()) {
    close(root);
    throw std::runtime_error("unsafe managed root");
  }
  try {
    std::unique_ptr<localdict::fdsqlite::FDBoundDirectoryCapability> current;
    for (const auto &component : relativeComponents(relative_path)) {
      auto next = current
          ? localdict::fdsqlite::FDBoundDirectoryCapability::OpenAt(
                *current, component)
          : localdict::fdsqlite::FDBoundDirectoryCapability::OpenAt(
                root, component);
      current = std::make_unique<
          localdict::fdsqlite::FDBoundDirectoryCapability>(std::move(next));
    }
    close(root);
    if (!current) throw std::runtime_error("empty managed path");
    return current;
  } catch (...) {
    close(root);
    throw;
  }
}

bool writableNameMatches(const SealedIndexBridgeStorage &storage) {
  if (storage.writable_descriptor < 0 || !storage.directory ||
      !storage.directory->NameStillMatches()) {
    return false;
  }
  struct stat descriptor_status {};
  struct stat name_status {};
  return fstat(storage.writable_descriptor, &descriptor_status) == 0 &&
      fstatat(storage.directory->descriptor(), storage.current_name.c_str(),
              &name_status, AT_SYMLINK_NOFOLLOW) == 0 &&
      (descriptor_status.st_mode & S_IFMT) == S_IFREG &&
      (name_status.st_mode & S_IFMT) == S_IFREG &&
      descriptor_status.st_uid == storage.owner &&
      name_status.st_uid == storage.owner &&
      descriptor_status.st_nlink == 1 && name_status.st_nlink == 1 &&
      descriptor_status.st_dev == storage.device &&
      name_status.st_dev == storage.device &&
      descriptor_status.st_ino == storage.inode &&
      name_status.st_ino == storage.inode;
}

std::string sha256Descriptor(int descriptor, uint64_t &size) {
  struct stat status {};
  if (fstat(descriptor, &status) != 0 || status.st_size < 0 ||
      (status.st_mode & S_IFMT) != S_IFREG || status.st_nlink != 1) {
    throw std::runtime_error("unsafe index descriptor");
  }
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  std::array<unsigned char, 1024 * 1024> buffer {};
  off_t offset = 0;
  while (offset < status.st_size) {
    const auto remaining = static_cast<uint64_t>(status.st_size - offset);
    const auto requested = static_cast<size_t>(
        std::min<uint64_t>(buffer.size(), remaining));
    ssize_t count;
    do {
      count = pread(descriptor, buffer.data(), requested, offset);
    } while (count < 0 && errno == EINTR);
    if (count <= 0) throw std::runtime_error("cannot hash index descriptor");
    CC_SHA256_Update(&context, buffer.data(), static_cast<CC_LONG>(count));
    offset += count;
  }
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (unsigned char byte : digest) {
    output << std::setw(2) << static_cast<unsigned int>(byte);
  }
  size = static_cast<uint64_t>(status.st_size);
  return output.str();
}

std::string sqliteText(sqlite3 *database, const char *sql) {
  sqlite3_stmt *statement = nullptr;
  if (sqlite3_prepare_v2(database, sql, -1, &statement, nullptr) != SQLITE_OK) {
    throw std::runtime_error("cannot prepare sealed index validation");
  }
  std::string result;
  if (sqlite3_step(statement) == SQLITE_ROW) {
    const auto *value = sqlite3_column_text(statement, 0);
    if (value) result = reinterpret_cast<const char *>(value);
  }
  sqlite3_finalize(statement);
  return result;
}

void validateTableColumns(
    sqlite3 *database, const char *table,
    const std::vector<std::pair<std::string, std::string>> &expected) {
  const std::string sql = "PRAGMA table_info('" + std::string(table) + "')";
  sqlite3_stmt *statement = nullptr;
  if (sqlite3_prepare_v2(database, sql.c_str(), -1, &statement, nullptr) !=
      SQLITE_OK) {
    throw std::runtime_error("cannot inspect sealed SQLite schema");
  }
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
      throw std::runtime_error("sealed SQLite schema mismatch");
    }
    ++position;
  }
  sqlite3_finalize(statement);
  if (position != expected.size()) {
    throw std::runtime_error("sealed SQLite schema column count mismatch");
  }
}

void validateSealedSQLite(
    const localdict::fdsqlite::FDBoundReadOnlyFileCapability &capability,
    const localdict::PublishedIndexMetadata &expected) {
  if (localdict::fdsqlite::EnsureFDBoundReadOnlyVFSRegistered() != SQLITE_OK) {
    throw std::runtime_error("cannot register fd-bound SQLite VFS");
  }
  localdict::fdsqlite::FDBoundRegisteredToken token(capability);
  sqlite3 *database = nullptr;
  const int result = sqlite3_open_v2(
      token.value().c_str(), &database,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
      localdict::fdsqlite::FDBoundReadOnlyVFSName());
  if (result != SQLITE_OK || !database) {
    if (database) sqlite3_close(database);
    throw std::runtime_error("cannot open sealed SQLite capability");
  }
  try {
    if (sqlite3_exec(database, "PRAGMA query_only=ON", nullptr, nullptr,
                     nullptr) != SQLITE_OK ||
        sqlite3_db_readonly(database, "main") != 1 ||
        sqliteText(database, "PRAGMA integrity_check") != "ok") {
      throw std::runtime_error("sealed SQLite integrity check failed");
    }
    validateTableColumns(
        database, "metadata", {{"key", "TEXT"}, {"value", "TEXT"}});
    validateTableColumns(
        database, "entries",
        {{"id", "INTEGER"}, {"headword", "TEXT"}, {"folded", "TEXT"},
         {"record_start", "INTEGER"}, {"record_end", "INTEGER"}});
    const std::pair<const char *, std::string> values[] = {
        {"dictionary_id", expected.dictionary_id},
        {"publication_id", expected.publication_id},
        {"source_sha256", expected.source_sha256},
        {"source_size", std::to_string(expected.source_size)},
        {"schema_version", std::to_string(expected.schema_version)},
        {"entry_count", std::to_string(expected.entry_count)},
        {"builder_format_version", expected.builder_format_version}};
    for (const auto &item : values) {
      const std::string sql =
          "SELECT value FROM metadata WHERE key='" +
          std::string(item.first) + "' LIMIT 1";
      if (sqliteText(database, sql.c_str()) != item.second) {
        throw std::runtime_error("sealed SQLite metadata mismatch");
      }
    }
    const std::string engine_version =
        sqliteText(database,
                   "SELECT value FROM metadata WHERE key='engine_version' "
                   "LIMIT 1");
    char *engine_end = nullptr;
    const float engine =
        std::strtof(engine_version.c_str(), &engine_end);
    if (engine_version.empty() || engine_end == engine_version.c_str() ||
        *engine_end != '\0' || !std::isfinite(engine) || engine < 2.0F) {
      throw std::runtime_error("sealed SQLite engine metadata mismatch");
    }
    if (sqliteText(database, "SELECT COUNT(*) FROM entries") !=
        std::to_string(expected.entry_count)) {
      throw std::runtime_error("sealed SQLite entry count mismatch");
    }
    sqlite3_close(database);
  } catch (...) {
    sqlite3_close(database);
    throw;
  }
}

localdict::PublishedIndexMetadata publishedMetadata(
    NSString *dictionaryID, NSString *publicationID, NSString *sourceSHA256,
    unsigned long long sourceFileSize, NSInteger schemaVersion,
    unsigned long long entryCount) {
  localdict::PublishedIndexMetadata metadata;
  metadata.dictionary_id = utf8(dictionaryID);
  metadata.publication_id = utf8(publicationID);
  metadata.source_sha256 = utf8(sourceSHA256);
  metadata.source_size = sourceFileSize;
  metadata.schema_version = static_cast<int>(schemaVersion);
  metadata.entry_count = entryCount;
  metadata.builder_format_version = "managed-fd-v1";
  return metadata;
}
}  // namespace

NSInteger LocalDictionaryIndexSchemaVersion(void) {
  return localdict::SQLiteDictionaryCore::schemaVersion();
}

NSDictionary<NSString *, id> *LocalDictionaryBuildIndex(
    NSString *dictionaryPath,
    NSString *indexPath,
    DictionaryIndexCancellationCheck cancellationCheck) {
  if (dictionaryPath.length == 0 || indexPath.length == 0) {
    return @{ @"success" : @NO, @"cancelled" : @NO,
              @"error" : @"索引计划缺少必要文件。" };
  }
  try {
    localdict::SQLiteDictionaryCore core(utf8(dictionaryPath), utf8(indexPath), 0, 0);
    const auto result = core.buildIndex([cancellationCheck]() {
      return cancellationCheck && cancellationCheck();
    });
    return @{ @"success" : @YES, @"cancelled" : @NO,
              @"entryCount" : @(result.entry_count) };
  } catch (const localdict::IndexBuildCancelled &) {
    return @{ @"success" : @NO, @"cancelled" : @YES };
  } catch (const std::exception &) {
    return @{ @"success" : @NO, @"cancelled" : @NO,
              @"error" : sanitizedIndexBuildError() };
  }
}

@interface LocalDictionaryManagedSourceCapability ()

- (instancetype)initWithSource:(localdict::MDictSourceCapability)source;
- (ManagedSourceBridgeStorage *)managedSourceStorage;

@end

@implementation LocalDictionaryManagedSourceCapability

- (instancetype)initWithSource:(localdict::MDictSourceCapability)source {
  self = [super init];
  if (self) {
    _managedSourceStorage =
        new ManagedSourceBridgeStorage(std::move(source));
  }
  return self;
}

- (void)dealloc {
  delete static_cast<ManagedSourceBridgeStorage *>(_managedSourceStorage);
}

- (ManagedSourceBridgeStorage *)managedSourceStorage {
  return static_cast<ManagedSourceBridgeStorage *>(_managedSourceStorage);
}

- (unsigned long long)sourceFileSize {
  const auto *storage = [self managedSourceStorage];
  return storage
      ? static_cast<unsigned long long>(storage->source.identity().size)
      : 0;
}

- (NSString *)sourceSHA256 {
  const auto *storage = [self managedSourceStorage];
  return storage ? string(storage->source.sha256()) : @"";
}

- (BOOL)isValidForPublication {
  const auto *storage = [self managedSourceStorage];
  return storage && storage->source.ValidForPublication();
}

@end

@interface LocalDictionarySealedIndexCapability ()

- (instancetype)initWithStorage:(SealedIndexBridgeStorage *)storage;
- (SealedIndexBridgeStorage *)sealedIndexStorage;

@end

@implementation LocalDictionarySealedIndexCapability

- (instancetype)initWithStorage:(SealedIndexBridgeStorage *)storage {
  self = [super init];
  if (self) _sealedIndexStorage = storage;
  return self;
}

- (void)dealloc {
  auto *storage =
      static_cast<SealedIndexBridgeStorage *>(_sealedIndexStorage);
  if (storage && !storage->committed) {
    if (storage->writable_descriptor >= 0 &&
        writableNameMatches(*storage)) {
      close(storage->writable_descriptor);
      storage->writable_descriptor = -1;
      (void)unlinkat(storage->directory->descriptor(),
                     storage->current_name.c_str(), 0);
    } else if (storage->readonly &&
               storage->readonly->NameStillMatches()) {
      (void)unlinkat(storage->directory->descriptor(),
                     storage->current_name.c_str(), 0);
    }
  }
  delete storage;
}

- (SealedIndexBridgeStorage *)sealedIndexStorage {
  return static_cast<SealedIndexBridgeStorage *>(_sealedIndexStorage);
}

- (NSString *)candidatePath {
  const auto *storage = [self sealedIndexStorage];
  return storage ? string(storage->candidate_path) : @"";
}

- (NSString *)publicationID {
  const auto *storage = [self sealedIndexStorage];
  return storage ? string(storage->publication_id) : @"";
}

- (NSString *)indexSHA256 {
  const auto *storage = [self sealedIndexStorage];
  return storage ? string(storage->sha256) : @"";
}

- (unsigned long long)indexFileSize {
  const auto *storage = [self sealedIndexStorage];
  return storage ? storage->size : 0;
}

- (BOOL)isSealed {
  const auto *storage = [self sealedIndexStorage];
  return storage && storage->readonly && storage->writable_descriptor < 0;
}

@end

NSDictionary<NSString *, id> *LocalDictionaryCreateManagedIndexCandidate(
    NSString *managedRootPath,
    NSString *indexDirectoryRelativePath,
    NSString *publicationID) {
  if (managedRootPath.length == 0 ||
      indexDirectoryRelativePath.length == 0 ||
      publicationID.length == 0) {
    return sourceFailure(@"unsafePath");
  }
  try {
    const std::string publication = utf8(publicationID);
    if (!safeComponent(publication) ||
        !canonicalLowercaseUUID(publicationID)) {
      throw std::runtime_error("unsafe publication id");
    }
    auto storage = std::make_unique<SealedIndexBridgeStorage>();
    storage->directory = openDirectoryRelative(
        utf8(managedRootPath), utf8(indexDirectoryRelativePath));
    storage->publication_id = publication;
    storage->candidate_name =
        ".dictionary." + publication + ".candidate";
    storage->final_name = "dictionary." + publication + ".sqlite";
    storage->current_name = storage->candidate_name;
    storage->candidate_path =
        utf8(managedRootPath) + "/" + utf8(indexDirectoryRelativePath) +
        "/" + storage->candidate_name;
    storage->writable_descriptor =
        openat(storage->directory->descriptor(),
               storage->candidate_name.c_str(),
               O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
               mode_t(0600));
    if (storage->writable_descriptor < 0) {
      throw std::runtime_error("cannot create exclusive index candidate");
    }
    struct stat status {};
    if (fstat(storage->writable_descriptor, &status) != 0 ||
        (status.st_mode & S_IFMT) != S_IFREG ||
        status.st_uid != geteuid() || status.st_nlink != 1 ||
        status.st_size != 0) {
      throw std::runtime_error("unsafe index candidate");
    }
    storage->device = status.st_dev;
    storage->inode = status.st_ino;
    storage->owner = status.st_uid;
    if (!writableNameMatches(*storage)) {
      throw std::runtime_error("candidate name binding mismatch");
    }
    auto *capability =
        [[LocalDictionarySealedIndexCapability alloc]
            initWithStorage:storage.release()];
    return @{@"success" : @YES, @"capability" : capability};
  } catch (const std::exception &) {
    return sourceFailure(@"unsafePath");
  }
}

NSDictionary<NSString *, id> *LocalDictionaryBuildManagedIndex(
    LocalDictionaryManagedSourceCapability *sourceCapability,
    LocalDictionarySealedIndexCapability *indexCapability,
    NSString *dictionaryID,
    NSString *sourceSHA256,
    unsigned long long sourceFileSize,
    DictionaryIndexCancellationCheck cancellationCheck) {
  auto *source = [sourceCapability managedSourceStorage];
  auto *index = [indexCapability sealedIndexStorage];
  if (!source || !source->source.valid() || !index ||
      !writableNameMatches(*index)) {
    return sourceFailure(@"sourceChanged");
  }
  const auto &identity = source->source.identity();
  localdict::IndexSourceMetadata source_metadata;
  source_metadata.size = static_cast<uint64_t>(identity.size);
  source_metadata.modified_seconds =
      static_cast<int64_t>(identity.modified_seconds);
  source_metadata.modified_nanoseconds =
      static_cast<int64_t>(identity.modified_nanoseconds);
  source_metadata.inode = static_cast<uint64_t>(identity.inode);
  source_metadata.device = static_cast<uint64_t>(identity.device);
  source_metadata.source_name = source->source.sourceName();
  source_metadata.source_identifier = source_metadata.source_name;
  auto metadata = publishedMetadata(
      dictionaryID, indexCapability.publicationID, sourceSHA256,
      sourceFileSize, LocalDictionaryIndexSchemaVersion(), 0);
  try {
    localdict::SQLiteDictionaryCore core(
        "", index->candidate_path, 0, 0);
    const auto result = core.buildManagedIndexFromFileDescriptor(
        source->source.borrowedDescriptor(), source_metadata, metadata,
        [cancellationCheck]() {
          return cancellationCheck && cancellationCheck();
        });
    if (!writableNameMatches(*index)) {
      throw std::runtime_error("candidate replaced during build");
    }
    return @{@"success" : @YES, @"cancelled" : @NO,
             @"entryCount" : @(result.entry_count)};
  } catch (const localdict::IndexBuildCancelled &) {
    return @{@"success" : @NO, @"cancelled" : @YES};
  } catch (const std::exception &) {
    return @{@"success" : @NO, @"cancelled" : @NO,
             @"error" : sanitizedIndexBuildError()};
  }
}

NSDictionary<NSString *, id> *LocalDictionarySealManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability,
    NSString *dictionaryID,
    NSString *sourceSHA256,
    unsigned long long sourceFileSize,
    NSInteger schemaVersion,
    unsigned long long entryCount) {
  auto *storage = [indexCapability sealedIndexStorage];
  if (!storage || storage->readonly ||
      !writableNameMatches(*storage) || entryCount == 0) {
    return sourceFailure(@"invalidSQLite");
  }
  try {
    const std::string suffixes[] = {"-journal", "-wal", "-shm"};
    for (const auto &suffix : suffixes) {
      struct stat ignored {};
      if (fstatat(storage->directory->descriptor(),
                  (storage->candidate_name + suffix).c_str(), &ignored,
                  AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
        throw std::runtime_error("SQLite auxiliary file present");
      }
    }
    if (fsync(storage->writable_descriptor) != 0 ||
        fchmod(storage->writable_descriptor, mode_t(0400)) != 0 ||
        !writableNameMatches(*storage)) {
      throw std::runtime_error("cannot seal writable candidate");
    }
    auto readonly =
        localdict::fdsqlite::FDBoundReadOnlyFileCapability::OpenAt(
            *storage->directory, storage->candidate_name);
    if (readonly.identity().device != storage->device ||
        readonly.identity().inode != storage->inode ||
        readonly.identity().permissions != 0400) {
      throw std::runtime_error("readonly candidate identity mismatch");
    }
    close(storage->writable_descriptor);
    storage->writable_descriptor = -1;
    const auto first_start = std::chrono::steady_clock::now();
    uint64_t first_size = 0;
    const std::string first_sha =
        sha256Descriptor(readonly.descriptor(), first_size);
    const auto first_end = std::chrono::steady_clock::now();
    auto expected = publishedMetadata(
        dictionaryID, indexCapability.publicationID, sourceSHA256,
        sourceFileSize, schemaVersion, entryCount);
    validateSealedSQLite(readonly, expected);
    const auto validation_end = std::chrono::steady_clock::now();
    uint64_t second_size = 0;
    const std::string second_sha =
        sha256Descriptor(readonly.descriptor(), second_size);
    const auto second_end = std::chrono::steady_clock::now();
    if (first_sha != second_sha || first_size != second_size ||
        first_size == 0 || !readonly.valid() ||
        !readonly.NameStillMatches()) {
      throw std::runtime_error("sealed candidate changed during validation");
    }
    storage->sha256 = second_sha;
    storage->size = second_size;
    storage->readonly = std::make_unique<
        localdict::fdsqlite::FDBoundReadOnlyFileCapability>(
            std::move(readonly));
    const auto milliseconds = [](auto begin, auto end) {
      return std::chrono::duration<double, std::milli>(end - begin).count();
    };
    return @{@"success" : @YES, @"indexSHA256" : string(storage->sha256),
             @"indexFileSize" : @(storage->size),
             @"firstSHA256Milliseconds" : @(milliseconds(first_start, first_end)),
             @"vfsValidationMilliseconds" :
                @(milliseconds(first_end, validation_end)),
             @"secondSHA256Milliseconds" :
                @(milliseconds(validation_end, second_end))};
  } catch (const std::exception &) {
    return sourceFailure(@"invalidSQLite");
  }
}

NSDictionary<NSString *, id> *LocalDictionaryPublishManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability) {
  auto *storage = [indexCapability sealedIndexStorage];
  if (!storage || !storage->readonly || storage->published ||
      !storage->readonly->valid() ||
      !storage->readonly->NameStillMatches()) {
    return sourceFailure(@"publicationFailed");
  }
  const auto sealed_identity = storage->readonly->identity();
  const int result = renameatx_np(
      storage->directory->descriptor(), storage->candidate_name.c_str(),
      storage->directory->descriptor(), storage->final_name.c_str(),
      RENAME_EXCL);
  if (result != 0) return sourceFailure(@"publicationFailed");
  try {
    auto final_capability =
        localdict::fdsqlite::FDBoundReadOnlyFileCapability::OpenAt(
            *storage->directory, storage->final_name);
    if (!(final_capability.identity() == sealed_identity) ||
        fsync(final_capability.descriptor()) != 0 ||
        fsync(storage->directory->descriptor()) != 0 ||
        !final_capability.NameStillMatches()) {
      throw std::runtime_error("published final identity mismatch");
    }
    storage->readonly = std::make_unique<
        localdict::fdsqlite::FDBoundReadOnlyFileCapability>(
            std::move(final_capability));
    storage->current_name = storage->final_name;
    storage->published = true;
    return @{@"success" : @YES,
             @"finalName" : string(storage->final_name)};
  } catch (const std::exception &) {
    storage->current_name = storage->final_name;
    storage->published = true;
    return sourceFailure(@"publicationFailed");
  }
}

void LocalDictionaryDiscardManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability) {
  auto *storage = [indexCapability sealedIndexStorage];
  if (!storage || storage->committed) return;
  bool matches = false;
  if (storage->writable_descriptor >= 0) {
    matches = writableNameMatches(*storage);
    close(storage->writable_descriptor);
    storage->writable_descriptor = -1;
  } else if (storage->readonly) {
    matches = storage->readonly->NameStillMatches();
  }
  if (matches) {
    (void)unlinkat(storage->directory->descriptor(),
                   storage->current_name.c_str(), 0);
    (void)fsync(storage->directory->descriptor());
  }
  storage->readonly.reset();
}

BOOL LocalDictionaryCommitManagedIndex(
    LocalDictionarySealedIndexCapability *indexCapability) {
  auto *storage = [indexCapability sealedIndexStorage];
  if (storage && storage->published && storage->readonly &&
      storage->readonly->NameStillMatches()) {
    storage->committed = true;
    return YES;
  }
  return NO;
}

BOOL LocalDictionaryValidatePublishedIndex(
    NSString *managedRootPath,
    NSString *indexRelativePath,
    NSString *dictionaryID,
    NSString *publicationID,
    NSString *indexSHA256,
    unsigned long long indexFileSize,
    NSString *sourceSHA256,
    unsigned long long sourceFileSize,
    NSInteger schemaVersion,
    unsigned long long entryCount) {
  try {
    if (!canonicalLowercaseUUID(dictionaryID) ||
        !canonicalLowercaseUUID(publicationID)) {
      return NO;
    }
    const auto components = relativeComponents(utf8(indexRelativePath));
    if (components.size() != 4 || components[0] != "Dictionaries" ||
        components[1] != utf8(dictionaryID) || components[2] != "index" ||
        components[3] !=
            "dictionary." + utf8(publicationID) + ".sqlite") {
      return NO;
    }
    auto directory = openDirectoryRelative(
        utf8(managedRootPath),
        "Dictionaries/" + utf8(dictionaryID) + "/index");
    auto capability =
        localdict::fdsqlite::FDBoundReadOnlyFileCapability::OpenAt(
            *directory, components[3]);
    if (capability.identity().permissions != 0400) return NO;
    uint64_t first_size = 0;
    const std::string first_sha =
        sha256Descriptor(capability.descriptor(), first_size);
    if (first_size != indexFileSize || first_sha != utf8(indexSHA256)) {
      return NO;
    }
    validateSealedSQLite(
        capability,
        publishedMetadata(dictionaryID, publicationID, sourceSHA256,
                          sourceFileSize, schemaVersion, entryCount));
    uint64_t second_size = 0;
    const std::string second_sha =
        sha256Descriptor(capability.descriptor(), second_size);
    return first_sha == second_sha && first_size == second_size &&
        capability.valid() && capability.NameStillMatches();
  } catch (const std::exception &) {
    return NO;
  }
}

NSDictionary<NSString *, id> *LocalDictionaryOpenManagedSource(
    NSString *managedRootPath,
    NSString *sourceRelativePath,
    unsigned long long expectedSourceSize,
    NSString *expectedSourceSHA256,
    DictionaryIndexCancellationCheck cancellationCheck) {
  if (managedRootPath.length == 0 || sourceRelativePath.length == 0 ||
      expectedSourceSHA256.length != 64) {
    return sourceFailure(@"sourceChanged");
  }
  try {
    auto source = localdict::MDictSourceCapability::OpenManagedRelative(
        utf8(managedRootPath), utf8(sourceRelativePath), geteuid(),
        [cancellationCheck]() {
          return cancellationCheck && cancellationCheck();
        });
    if (static_cast<unsigned long long>(source.identity().size) !=
            expectedSourceSize ||
        source.sha256() != utf8(expectedSourceSHA256)) {
      return sourceFailure(@"sourceChanged");
    }
    auto *capability =
        [[LocalDictionaryManagedSourceCapability alloc]
            initWithSource:std::move(source)];
    return @{ @"success" : @YES, @"cancelled" : @NO,
              @"capability" : capability };
  } catch (const localdict::MDictSourceHashCancelled &) {
    return @{ @"success" : @NO, @"cancelled" : @YES };
  } catch (const std::exception &) {
    return sourceFailure(@"sourceChanged");
  }
}

NSDictionary<NSString *, id> *LocalDictionaryBuildIndexFromManagedSource(
    LocalDictionaryManagedSourceCapability *sourceCapability,
    NSString *indexPath,
    DictionaryIndexCancellationCheck cancellationCheck) {
  if (!sourceCapability || indexPath.length == 0) {
    return sourceFailure(@"sourceChanged");
  }
  auto *storage = [sourceCapability managedSourceStorage];
  if (!storage || !storage->source.valid()) {
    return sourceFailure(@"sourceChanged");
  }
  const auto &identity = storage->source.identity();
  localdict::IndexSourceMetadata metadata;
  metadata.size = static_cast<uint64_t>(identity.size);
  metadata.modified_seconds =
      static_cast<int64_t>(identity.modified_seconds);
  metadata.modified_nanoseconds =
      static_cast<int64_t>(identity.modified_nanoseconds);
  metadata.inode = static_cast<uint64_t>(identity.inode);
  metadata.device = static_cast<uint64_t>(identity.device);
  metadata.source_name = storage->source.sourceName();
  metadata.source_identifier = metadata.source_name;
  try {
    localdict::SQLiteDictionaryCore core("", utf8(indexPath), 0, 0);
    const auto result = core.buildIndexFromFileDescriptor(
        storage->source.borrowedDescriptor(), metadata,
        [cancellationCheck]() {
          return cancellationCheck && cancellationCheck();
        });
    return @{ @"success" : @YES, @"cancelled" : @NO,
              @"entryCount" : @(result.entry_count) };
  } catch (const localdict::IndexBuildCancelled &) {
    return @{ @"success" : @NO, @"cancelled" : @YES };
  } catch (const std::exception &) {
    return @{ @"success" : @NO, @"cancelled" : @NO,
              @"error" : sanitizedIndexBuildError() };
  }
}

@implementation DictionaryCoreBridge

- (instancetype)initWithDictionaryPath:(NSString *)dictionaryPath
                             indexPath:(NSString *)indexPath {
  return [self initWithDictionaryPath:dictionaryPath
                            indexPath:indexPath
                   cacheMaximumBytes:8 * 1024 * 1024
                 cacheMaximumEntries:64];
}

- (instancetype)initWithDictionaryPath:(NSString *)dictionaryPath
                              indexPath:(NSString *)indexPath
                     cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                   cacheMaximumEntries:(NSUInteger)cacheMaximumEntries {
  self = [super init];
  if (self) {
    _storage = new DictionaryBridgeStorage();
    if (dictionaryPath.length == 0 || indexPath.length == 0) {
      _storage->error = "尚未安装本地词典";
      return self;
    }
    try {
      _storage->core = std::make_unique<localdict::SQLiteDictionaryCore>(
          utf8(dictionaryPath), utf8(indexPath),
          static_cast<size_t>(cacheMaximumBytes),
          static_cast<size_t>(cacheMaximumEntries));
      _storage->core->open(false);
    } catch (const std::exception &exception) {
      _storage->error = exception.what();
      _storage->core.reset();
    }
  }
  return self;
}

- (instancetype)initReadOnlyWithDictionaryPath:(NSString *)dictionaryPath
                                      indexPath:(NSString *)indexPath
                             cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                           cacheMaximumEntries:(NSUInteger)cacheMaximumEntries {
  self = [super init];
  if (self) {
    _storage = new DictionaryBridgeStorage();
    if (dictionaryPath.length == 0 || indexPath.length == 0) {
      _storage->error = "Managed dictionary files are unavailable";
      return self;
    }
    try {
      _storage->core = std::make_unique<localdict::SQLiteDictionaryCore>(
          utf8(dictionaryPath), utf8(indexPath),
          static_cast<size_t>(cacheMaximumBytes),
          static_cast<size_t>(cacheMaximumEntries));
      _storage->core->openExistingReadOnly();
    } catch (const std::exception &exception) {
      _storage->error = exception.what();
      _storage->core.reset();
    }
  }
  return self;
}

- (instancetype)initManagedReadOnlyWithRootPath:(NSString *)managedRootPath
                             sourceRelativePath:(NSString *)sourceRelativePath
                              indexRelativePath:(NSString *)indexRelativePath
                                   dictionaryID:(NSString *)dictionaryID
                                  publicationID:(NSString *)publicationID
                                    indexSHA256:(NSString *)indexSHA256
                                  indexFileSize:(unsigned long long)indexFileSize
                                   sourceSHA256:(NSString *)sourceSHA256
                                 sourceFileSize:(unsigned long long)sourceFileSize
                                  schemaVersion:(NSInteger)schemaVersion
                                     entryCount:(unsigned long long)entryCount
                              cacheMaximumBytes:(NSUInteger)cacheMaximumBytes
                            cacheMaximumEntries:(NSUInteger)cacheMaximumEntries {
  self = [super init];
  if (!self) return self;
  _storage = new DictionaryBridgeStorage();
  try {
    if (!canonicalLowercaseUUID(dictionaryID) ||
        !canonicalLowercaseUUID(publicationID)) {
      throw std::runtime_error("unsafe managed identity");
    }
    const auto index_components = relativeComponents(utf8(indexRelativePath));
    if (index_components.size() != 4 ||
        index_components[0] != "Dictionaries" ||
        index_components[1] != utf8(dictionaryID) ||
        index_components[2] != "index" ||
        index_components[3] !=
            "dictionary." + utf8(publicationID) + ".sqlite") {
      throw std::runtime_error("unsafe managed index relative path");
    }
    auto source = localdict::MDictSourceCapability::OpenManagedRelative(
        utf8(managedRootPath), utf8(sourceRelativePath), geteuid());
    if (static_cast<unsigned long long>(source.identity().size) !=
            sourceFileSize ||
        source.sha256() != utf8(sourceSHA256) ||
        !source.ValidForPublication()) {
      throw std::runtime_error("managed source identity mismatch");
    }
    auto index_directory = openDirectoryRelative(
        utf8(managedRootPath),
        "Dictionaries/" + utf8(dictionaryID) + "/index");
    auto index =
        localdict::fdsqlite::FDBoundReadOnlyFileCapability::OpenAt(
            *index_directory, index_components[3]);
    if (index.identity().permissions != 0400) {
      throw std::runtime_error("managed index mode mismatch");
    }
    uint64_t first_size = 0;
    const std::string first_sha =
        sha256Descriptor(index.descriptor(), first_size);
    if (first_size != indexFileSize || first_sha != utf8(indexSHA256)) {
      throw std::runtime_error("managed index digest mismatch");
    }
    auto metadata = publishedMetadata(
        dictionaryID, publicationID, sourceSHA256, sourceFileSize,
        schemaVersion, entryCount);
    auto core = std::make_unique<localdict::SQLiteDictionaryCore>(
        "", "", static_cast<size_t>(cacheMaximumBytes),
        static_cast<size_t>(cacheMaximumEntries));
    core->openManagedReadOnly(
        source.borrowedDescriptor(), index, metadata);
    uint64_t second_size = 0;
    const std::string second_sha =
        sha256Descriptor(index.descriptor(), second_size);
    if (first_sha != second_sha || first_size != second_size ||
        !source.ValidForPublication() || !index.valid() ||
        !index.NameStillMatches()) {
      throw std::runtime_error("managed runtime identity changed while opening");
    }
    _storage->managed_source =
        std::make_unique<localdict::MDictSourceCapability>(std::move(source));
    _storage->managed_index = std::make_unique<
        localdict::fdsqlite::FDBoundReadOnlyFileCapability>(
            std::move(index));
    _storage->core = std::move(core);
  } catch (const std::exception &exception) {
    _storage->error = exception.what();
    _storage->core.reset();
    _storage->managed_source.reset();
    _storage->managed_index.reset();
  }
  return self;
}

- (void)dealloc {
  delete _storage;
}

- (BOOL)isReady { return _storage && _storage->core != nullptr; }

- (NSString *)lastError {
  return _storage ? string(_storage->error) : @"Dictionary core unavailable";
}

- (NSDictionary<NSString *, id> *)lookup:(NSString *)query {
  return [self lookup:query maximumHTMLBytes:0];
}

- (NSDictionary<NSString *, id> *)lookup:(NSString *)query
                         maximumHTMLBytes:(NSUInteger)maximumHTMLBytes {
  if (![self isReady]) {
    return @{ @"found" : @NO, @"error" : self.lastError };
  }
  if ((_storage->managed_source &&
       !_storage->managed_source->ValidForPublication()) ||
      (_storage->managed_index &&
       (!_storage->managed_index->valid() ||
        !_storage->managed_index->NameStillMatches()))) {
    _storage->error = "Managed dictionary runtime identity changed";
    _storage->core.reset();
    return @{@"found" : @NO, @"error" : string(_storage->error)};
  }
  try {
    const auto result = _storage->core->lookup(
        utf8(query), static_cast<size_t>(maximumHTMLBytes));
    return @{
      @"found" : @(result.found),
      @"matchedHeadword" : string(result.matched_headword),
      @"html" : string(result.html),
      @"htmlTruncated" : @(result.html_truncated),
      @"caseFallback" : @(result.used_case_fallback),
      @"cacheHit" : @(result.cache_hit),
      @"milliseconds" : @(result.milliseconds)
    };
  } catch (const std::exception &exception) {
    _storage->error = exception.what();
    return @{ @"found" : @NO, @"error" : string(_storage->error) };
  }
}

@end
