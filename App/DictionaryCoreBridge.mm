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
}  // namespace

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
