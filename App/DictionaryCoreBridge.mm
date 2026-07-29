#import "DictionaryCoreBridge.h"

#include "ManagedMDictSource.h"
#include "SQLiteDictionaryCore.h"

#include <memory>
#include <string>

class DictionaryBridgeStorage {
 public:
  std::unique_ptr<localdict::SQLiteDictionaryCore> core;
  std::string error;
};

struct ManagedSourceBridgeStorage {
  explicit ManagedSourceBridgeStorage(
      localdict::MDictSourceCapability source_value)
      : source(std::move(source_value)) {}

  localdict::MDictSourceCapability source;
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
  try {
    const auto result = _storage->core->lookup(
        utf8(query), static_cast<size_t>(maximumHTMLBytes));
    return @{
      @"found" : @(result.found),
      @"matchedHeadword" : string(result.matched_headword),
      @"html" : string(result.html),
      @"htmlTruncated" : @(result.html_truncated),
      @"caseFallback" : @(result.used_case_fallback),
      @"milliseconds" : @(result.milliseconds)
    };
  } catch (const std::exception &exception) {
    _storage->error = exception.what();
    return @{ @"found" : @NO, @"error" : string(_storage->error) };
  }
}

@end
