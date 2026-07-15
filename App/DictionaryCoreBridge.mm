#import "DictionaryCoreBridge.h"

#include "SQLiteDictionaryCore.h"

#include <memory>
#include <string>

class DictionaryBridgeStorage {
 public:
  std::unique_ptr<localdict::SQLiteDictionaryCore> core;
  std::string error;
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

- (void)dealloc {
  delete _storage;
}

- (BOOL)isReady { return _storage && _storage->core != nullptr; }

- (NSString *)lastError {
  return _storage ? string(_storage->error) : @"Dictionary core unavailable";
}

- (NSDictionary<NSString *, id> *)lookup:(NSString *)query {
  if (![self isReady]) {
    return @{ @"found" : @NO, @"error" : self.lastError };
  }
  try {
    const auto result = _storage->core->lookup(utf8(query));
    return @{
      @"found" : @(result.found),
      @"matchedHeadword" : string(result.matched_headword),
      @"html" : string(result.html),
      @"caseFallback" : @(result.used_case_fallback),
      @"milliseconds" : @(result.milliseconds)
    };
  } catch (const std::exception &exception) {
    _storage->error = exception.what();
    return @{ @"found" : @NO, @"error" : string(_storage->error) };
  }
}

@end
