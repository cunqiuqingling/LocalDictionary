#include "FDBoundSQLiteReadOnlyVFS.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <unordered_map>
#include <utility>

#include <sys/time.h>
#include <unistd.h>

namespace localdict::prototype {
namespace {

constexpr char kVFSName[] = "localdict_fd_readonly_prototype_v1";
constexpr char kTokenPrefix[] = "/localdict-fd-vfs-prototype-";
constexpr std::size_t kRandomTokenBytes = 32;
constexpr std::size_t kTokenLength =
    sizeof(kTokenPrefix) - 1 + kRandomTokenBytes * 2;

struct RegistryEntry {
  int descriptor = -1;
  FDBoundFileIdentity identity;
};

struct RegistryState {
  std::mutex mutex;
  std::unordered_map<std::string, RegistryEntry> entries;
  std::size_t active_connections = 0;
  std::uint64_t consumed_tokens = 0;
  std::uint64_t rejected_names = 0;
  std::uint64_t rejected_flags = 0;
  std::uint64_t open_failures = 0;
  std::uint64_t closed_files = 0;
  std::uint64_t bytes_read = 0;
};

RegistryState &Registry() {
  static RegistryState state;
  return state;
}

void CloseOnce(int &descriptor) {
  if (descriptor < 0) return;
  const int owned = descriptor;
  descriptor = -1;
  (void)close(owned);
}

int DuplicateCloseOnExec(int descriptor) {
  const int duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
  if (duplicate < 0) {
    throw std::system_error(errno, std::generic_category(),
                            "cannot duplicate file descriptor");
  }
  return duplicate;
}

void ValidateComponent(const std::string &component) {
  if (component.empty() || component == "." || component == ".." ||
      component.find('/') != std::string::npos ||
      component.find('\\') != std::string::npos ||
      component.find('\0') != std::string::npos) {
    throw std::invalid_argument("unsafe path component");
  }
}

FDBoundFileIdentity IdentityFromStat(const struct stat &value) {
  return {value.st_dev,
          value.st_ino,
          static_cast<mode_t>(value.st_mode & S_IFMT),
          value.st_uid,
          value.st_nlink,
          value.st_size};
}

FDBoundFileIdentity DescriptorIdentity(int descriptor) {
  struct stat value {};
  if (fstat(descriptor, &value) != 0) {
    throw std::system_error(errno, std::generic_category(), "fstat failed");
  }
  return IdentityFromStat(value);
}

FDBoundFileIdentity EntryIdentity(int parent_fd,
                                  const std::string &component) {
  struct stat value {};
  if (fstatat(parent_fd, component.c_str(), &value, AT_SYMLINK_NOFOLLOW) != 0) {
    throw std::system_error(errno, std::generic_category(), "fstatat failed");
  }
  return IdentityFromStat(value);
}

bool SameObject(const FDBoundFileIdentity &left,
                const FDBoundFileIdentity &right) {
  if (left.device != right.device || left.inode != right.inode ||
      left.type != right.type || left.owner != right.owner) {
    return false;
  }
  if (left.type == S_IFREG) {
    return left.link_count == right.link_count && left.size == right.size;
  }
  return true;
}

void ValidateDirectoryIdentity(const FDBoundFileIdentity &identity,
                               uid_t expected_owner) {
  if (identity.type != S_IFDIR || identity.owner != expected_owner) {
    throw std::runtime_error("unsafe directory identity");
  }
}

void ValidateFileIdentity(const FDBoundFileIdentity &identity,
                          uid_t expected_owner) {
  if (identity.type != S_IFREG || identity.owner != expected_owner ||
      identity.link_count != 1 || identity.size < 0) {
    throw std::runtime_error("unsafe regular-file identity");
  }
}

bool IsHex(unsigned char value) {
  return (value >= '0' && value <= '9') ||
         (value >= 'a' && value <= 'f');
}

bool IsTokenSyntax(const char *name) {
  if (!name) return false;
  const std::string value(name);
  if (value.size() != kTokenLength ||
      value.compare(0, sizeof(kTokenPrefix) - 1, kTokenPrefix) != 0) {
    return false;
  }
  return std::all_of(value.begin() + sizeof(kTokenPrefix) - 1, value.end(),
                     [](char character) {
                       return IsHex(static_cast<unsigned char>(character));
                     });
}

std::string NewToken() {
  static constexpr char kHex[] = "0123456789abcdef";
  std::array<unsigned char, kRandomTokenBytes> bytes {};
  arc4random_buf(bytes.data(), bytes.size());
  std::string value(kTokenPrefix);
  value.reserve(kTokenLength);
  for (unsigned char byte : bytes) {
    value.push_back(kHex[byte >> 4]);
    value.push_back(kHex[byte & 0x0f]);
  }
  return value;
}

void CancelRegistryToken(const std::string &token) {
  if (token.empty()) return;
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  const auto found = registry.entries.find(token);
  if (found == registry.entries.end()) return;
  CloseOnce(found->second.descriptor);
  registry.entries.erase(found);
}

bool RegistryContains(const char *token) {
  if (!token) return false;
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  return registry.entries.find(token) != registry.entries.end();
}

bool TakeRegistryEntry(const char *token, RegistryEntry &output) {
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  const auto found = registry.entries.find(token);
  if (found == registry.entries.end()) return false;
  output = found->second;
  registry.entries.erase(found);
  ++registry.consumed_tokens;
  return true;
}

void CountRejectedName() {
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  ++registry.rejected_names;
}

void CountRejectedFlags() {
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  ++registry.rejected_flags;
}

void CountOpenFailure() {
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  ++registry.open_failures;
}

struct FDBoundSQLiteFile {
  sqlite3_file base {};
  int descriptor = -1;
  int lock_level = SQLITE_LOCK_NONE;
  FDBoundFileIdentity identity;
  bool counted_connection = false;
};

int FileClose(sqlite3_file *file) {
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  if (owned->descriptor >= 0) {
    CloseOnce(owned->descriptor);
    auto &registry = Registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    if (owned->counted_connection && registry.active_connections > 0) {
      --registry.active_connections;
    }
    owned->counted_connection = false;
    ++registry.closed_files;
  }
  return SQLITE_OK;
}

int FileRead(sqlite3_file *file, void *buffer, int amount,
             sqlite3_int64 offset) {
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  if (owned->descriptor < 0 || !buffer || amount < 0 || offset < 0 ||
      offset > std::numeric_limits<off_t>::max()) {
    return SQLITE_IOERR_READ;
  }
  auto *bytes = static_cast<unsigned char *>(buffer);
  std::size_t completed = 0;
  while (completed < static_cast<std::size_t>(amount)) {
    const auto requested = static_cast<std::size_t>(amount) - completed;
    if (completed >
        static_cast<std::size_t>(
            std::numeric_limits<off_t>::max() -
            static_cast<off_t>(offset))) {
      return SQLITE_IOERR_READ;
    }
    const ssize_t count =
        pread(owned->descriptor, bytes + completed, requested,
              static_cast<off_t>(offset) +
                  static_cast<off_t>(completed));
    if (count > 0) {
      completed += static_cast<std::size_t>(count);
      continue;
    }
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) return SQLITE_IOERR_READ;
    std::memset(bytes + completed, 0,
                static_cast<std::size_t>(amount) - completed);
    {
      auto &registry = Registry();
      std::lock_guard<std::mutex> lock(registry.mutex);
      registry.bytes_read += completed;
    }
    return SQLITE_IOERR_SHORT_READ;
  }
  {
    auto &registry = Registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    registry.bytes_read += completed;
  }
  return SQLITE_OK;
}

int FileWrite(sqlite3_file *, const void *, int, sqlite3_int64) {
  return SQLITE_READONLY;
}

int FileTruncate(sqlite3_file *, sqlite3_int64) {
  return SQLITE_READONLY;
}

int FileSync(sqlite3_file *, int) { return SQLITE_READONLY; }

int FileSize(sqlite3_file *file, sqlite3_int64 *size) {
  if (!size) return SQLITE_IOERR_FSTAT;
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  struct stat value {};
  if (owned->descriptor < 0 || fstat(owned->descriptor, &value) != 0 ||
      value.st_size < 0) {
    return SQLITE_IOERR_FSTAT;
  }
  *size = static_cast<sqlite3_int64>(value.st_size);
  return SQLITE_OK;
}

int SetWholeFileLock(int descriptor, short type) {
  struct flock lock {};
  lock.l_type = type;
  lock.l_whence = SEEK_SET;
  lock.l_start = 0;
  lock.l_len = 0;
  if (fcntl(descriptor, F_SETLK, &lock) == 0) return SQLITE_OK;
  return errno == EACCES || errno == EAGAIN ? SQLITE_BUSY : SQLITE_IOERR_LOCK;
}

int FileLock(sqlite3_file *file, int requested) {
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  if (owned->descriptor < 0) return SQLITE_IOERR_LOCK;
  if (requested <= owned->lock_level) return SQLITE_OK;
  if (requested > SQLITE_LOCK_SHARED) return SQLITE_READONLY;
  const int result = SetWholeFileLock(owned->descriptor, F_RDLCK);
  if (result == SQLITE_OK) owned->lock_level = SQLITE_LOCK_SHARED;
  return result;
}

int FileUnlock(sqlite3_file *file, int requested) {
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  if (owned->descriptor < 0) return SQLITE_IOERR_UNLOCK;
  if (requested >= owned->lock_level) return SQLITE_OK;
  if (requested != SQLITE_LOCK_NONE) return SQLITE_READONLY;
  const int result = SetWholeFileLock(owned->descriptor, F_UNLCK);
  if (result == SQLITE_OK) owned->lock_level = SQLITE_LOCK_NONE;
  return result;
}

int FileCheckReservedLock(sqlite3_file *file, int *result) {
  if (!result) return SQLITE_IOERR_CHECKRESERVEDLOCK;
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  if (owned->descriptor < 0) return SQLITE_IOERR_CHECKRESERVEDLOCK;
  struct flock lock {};
  lock.l_type = F_WRLCK;
  lock.l_whence = SEEK_SET;
  lock.l_start = 0;
  lock.l_len = 0;
  if (fcntl(owned->descriptor, F_GETLK, &lock) != 0) {
    return SQLITE_IOERR_CHECKRESERVEDLOCK;
  }
  *result = lock.l_type == F_UNLCK ? 0 : 1;
  return SQLITE_OK;
}

int FileControl(sqlite3_file *file, int operation, void *argument) {
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  switch (operation) {
    case SQLITE_FCNTL_LOCKSTATE:
      if (!argument) return SQLITE_ERROR;
      *static_cast<int *>(argument) = owned->lock_level;
      return SQLITE_OK;
    case SQLITE_FCNTL_MMAP_SIZE:
      if (!argument) return SQLITE_ERROR;
      *static_cast<sqlite3_int64 *>(argument) = 0;
      return SQLITE_OK;
    case SQLITE_FCNTL_HAS_MOVED:
      if (!argument) return SQLITE_ERROR;
      *static_cast<int *>(argument) = 0;
      return SQLITE_OK;
    default:
      return SQLITE_NOTFOUND;
  }
}

int FileSectorSize(sqlite3_file *) { return 4096; }

int FileDeviceCharacteristics(sqlite3_file *) { return 0; }

const sqlite3_io_methods kReadOnlyMethods = {
    1,
    FileClose,
    FileRead,
    FileWrite,
    FileTruncate,
    FileSync,
    FileSize,
    FileLock,
    FileUnlock,
    FileCheckReservedLock,
    FileControl,
    FileSectorSize,
    FileDeviceCharacteristics,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};

bool FlagsAreReadOnlyMainDatabase(int flags) {
  constexpr int kRejected =
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_DELETEONCLOSE |
      SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_AUTOPROXY | SQLITE_OPEN_MEMORY |
      SQLITE_OPEN_MAIN_JOURNAL | SQLITE_OPEN_TEMP_DB |
      SQLITE_OPEN_TEMP_JOURNAL | SQLITE_OPEN_SUBJOURNAL |
      SQLITE_OPEN_SUPER_JOURNAL | SQLITE_OPEN_WAL;
  return (flags & SQLITE_OPEN_MAIN_DB) != 0 &&
         (flags & SQLITE_OPEN_READONLY) != 0 && (flags & kRejected) == 0;
}

int VFSOpen(sqlite3_vfs *, const char *name, sqlite3_file *file, int flags,
            int *output_flags) {
  auto *owned = reinterpret_cast<FDBoundSQLiteFile *>(file);
  std::memset(owned, 0, sizeof(*owned));
  owned->descriptor = -1;
  owned->base.pMethods = nullptr;

  if (!IsTokenSyntax(name)) {
    CountRejectedName();
    return SQLITE_CANTOPEN;
  }
  if (!FlagsAreReadOnlyMainDatabase(flags)) {
    CountRejectedFlags();
    return SQLITE_READONLY;
  }

  RegistryEntry entry;
  if (!TakeRegistryEntry(name, entry)) {
    CountOpenFailure();
    return SQLITE_CANTOPEN;
  }

  owned->descriptor = entry.descriptor;
  entry.descriptor = -1;
  try {
    const auto observed = DescriptorIdentity(owned->descriptor);
    ValidateFileIdentity(observed, entry.identity.owner);
    if (!SameObject(observed, entry.identity)) {
      throw std::runtime_error("registered fd identity changed");
    }
    owned->identity = observed;
  } catch (...) {
    CloseOnce(owned->descriptor);
    CountOpenFailure();
    return SQLITE_CANTOPEN;
  }

  owned->base.pMethods = &kReadOnlyMethods;
  owned->counted_connection = true;
  {
    auto &registry = Registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    ++registry.active_connections;
  }
  if (output_flags) {
    *output_flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_MAIN_DB;
  }
  return SQLITE_OK;
}

int VFSDelete(sqlite3_vfs *, const char *, int) { return SQLITE_READONLY; }

int VFSAccess(sqlite3_vfs *, const char *name, int, int *result) {
  if (!result) return SQLITE_IOERR_ACCESS;
  *result = IsTokenSyntax(name) && RegistryContains(name) ? 1 : 0;
  return SQLITE_OK;
}

int VFSFullPathname(sqlite3_vfs *, const char *name, int output_size,
                    char *output) {
  if (!IsTokenSyntax(name) || !output ||
      output_size <= static_cast<int>(std::strlen(name))) {
    CountRejectedName();
    return SQLITE_CANTOPEN;
  }
  std::memcpy(output, name, std::strlen(name) + 1);
  return SQLITE_OK;
}

void *VFSDLOpen(sqlite3_vfs *, const char *) { return nullptr; }

void VFSDLError(sqlite3_vfs *, int size, char *message) {
  if (size > 0 && message) {
    sqlite3_snprintf(size, message,
                     "dynamic loading disabled by fd-bound prototype VFS");
  }
}

void (*VFSDLSym(sqlite3_vfs *, void *, const char *))(void) {
  return nullptr;
}

void VFSDLClose(sqlite3_vfs *, void *) {}

int VFSRandomness(sqlite3_vfs *, int size, char *output) {
  if (size <= 0 || !output) return 0;
  arc4random_buf(output, static_cast<std::size_t>(size));
  return size;
}

int VFSSleep(sqlite3_vfs *, int microseconds) {
  if (microseconds <= 0) return 0;
  usleep(static_cast<useconds_t>(microseconds));
  return microseconds;
}

int VFSCurrentTime(sqlite3_vfs *, double *julian_day) {
  if (!julian_day) return SQLITE_ERROR;
  struct timeval now {};
  if (gettimeofday(&now, nullptr) != 0) return SQLITE_ERROR;
  const double unix_seconds =
      static_cast<double>(now.tv_sec) +
      static_cast<double>(now.tv_usec) / 1000000.0;
  *julian_day = unix_seconds / 86400.0 + 2440587.5;
  return SQLITE_OK;
}

int VFSGetLastError(sqlite3_vfs *, int size, char *message) {
  const int error = errno;
  if (size > 0 && message) {
    sqlite3_snprintf(size, message, "%s", std::strerror(error));
  }
  return error;
}

sqlite3_vfs &PrototypeVFS() {
  static sqlite3_vfs vfs = {
      1,
      static_cast<int>(sizeof(FDBoundSQLiteFile)),
      512,
      nullptr,
      kVFSName,
      nullptr,
      VFSOpen,
      VFSDelete,
      VFSAccess,
      VFSFullPathname,
      VFSDLOpen,
      VFSDLError,
      VFSDLSym,
      VFSDLClose,
      VFSRandomness,
      VFSSleep,
      VFSCurrentTime,
      VFSGetLastError,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
  };
  return vfs;
}

std::mutex &RegistrationMutex() {
  static std::mutex mutex;
  return mutex;
}

bool &Registered() {
  static bool registered = false;
  return registered;
}

}  // namespace

struct FDBoundDirectoryCapability::NameBinding {
  int parent_descriptor = -1;
  std::string component;
  FDBoundFileIdentity identity;
  std::shared_ptr<const NameBinding> ancestor;

  ~NameBinding() { CloseOnce(parent_descriptor); }

  bool Matches() const {
    if (ancestor && !ancestor->Matches()) return false;
    try {
      return SameObject(EntryIdentity(parent_descriptor, component), identity);
    } catch (...) {
      return false;
    }
  }
};

bool FDBoundFileIdentity::operator==(
    const FDBoundFileIdentity &other) const {
  return SameObject(*this, other);
}

FDBoundDirectoryCapability::FDBoundDirectoryCapability(
    int descriptor, std::shared_ptr<NameBinding> binding)
    : descriptor_(descriptor), binding_(std::move(binding)) {}

FDBoundDirectoryCapability FDBoundDirectoryCapability::OpenAt(
    int parent_fd, const std::string &component, uid_t expected_owner) {
  ValidateComponent(component);
  const int descriptor =
      openat(parent_fd, component.c_str(),
             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::system_error(errno, std::generic_category(),
                            "cannot open child directory");
  }
  try {
    const auto descriptor_identity = DescriptorIdentity(descriptor);
    ValidateDirectoryIdentity(descriptor_identity, expected_owner);
    if (!SameObject(descriptor_identity,
                    EntryIdentity(parent_fd, component))) {
      throw std::runtime_error("directory name rebind failed");
    }
    auto binding = std::make_shared<NameBinding>();
    binding->parent_descriptor = DuplicateCloseOnExec(parent_fd);
    binding->component = component;
    binding->identity = descriptor_identity;
    return FDBoundDirectoryCapability(descriptor, std::move(binding));
  } catch (...) {
    int owned = descriptor;
    CloseOnce(owned);
    throw;
  }
}

FDBoundDirectoryCapability FDBoundDirectoryCapability::OpenAt(
    const FDBoundDirectoryCapability &parent,
    const std::string &component, uid_t expected_owner) {
  auto child = OpenAt(parent.descriptor_, component, expected_owner);
  child.binding_->ancestor = parent.binding_;
  return child;
}

FDBoundDirectoryCapability::FDBoundDirectoryCapability(
    FDBoundDirectoryCapability &&other) noexcept
    : descriptor_(std::exchange(other.descriptor_, -1)),
      binding_(std::move(other.binding_)) {}

FDBoundDirectoryCapability &FDBoundDirectoryCapability::operator=(
    FDBoundDirectoryCapability &&other) noexcept {
  if (this == &other) return *this;
  CloseOnce(descriptor_);
  descriptor_ = std::exchange(other.descriptor_, -1);
  binding_ = std::move(other.binding_);
  return *this;
}

FDBoundDirectoryCapability::~FDBoundDirectoryCapability() {
  CloseOnce(descriptor_);
}

bool FDBoundDirectoryCapability::NameStillMatches() const {
  return descriptor_ >= 0 && binding_ && binding_->Matches();
}

int FDBoundDirectoryCapability::descriptor() const {
  return descriptor_;
}

FDBoundReadOnlyFileCapability::FDBoundReadOnlyFileCapability(
    int descriptor, FDBoundFileIdentity identity,
    std::shared_ptr<const FDBoundDirectoryCapability::NameBinding> binding)
    : descriptor_(descriptor),
      identity_(identity),
      binding_(std::move(binding)) {}

FDBoundReadOnlyFileCapability FDBoundReadOnlyFileCapability::OpenAt(
    const FDBoundDirectoryCapability &directory,
    const std::string &component, uid_t expected_owner) {
  ValidateComponent(component);
  if (!directory.NameStillMatches()) {
    throw std::runtime_error("directory capability is no longer bound");
  }
  const int descriptor =
      openat(directory.descriptor_, component.c_str(),
             O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::system_error(errno, std::generic_category(),
                            "cannot open read-only file");
  }
  try {
    const auto descriptor_identity = DescriptorIdentity(descriptor);
    ValidateFileIdentity(descriptor_identity, expected_owner);
    if (!SameObject(descriptor_identity,
                    EntryIdentity(directory.descriptor_, component))) {
      throw std::runtime_error("file name rebind failed");
    }
    auto binding =
        std::make_shared<FDBoundDirectoryCapability::NameBinding>();
    binding->parent_descriptor =
        DuplicateCloseOnExec(directory.descriptor_);
    binding->component = component;
    binding->identity = descriptor_identity;
    binding->ancestor = directory.binding_;
    return FDBoundReadOnlyFileCapability(
        descriptor, descriptor_identity, std::move(binding));
  } catch (...) {
    int owned = descriptor;
    CloseOnce(owned);
    throw;
  }
}

FDBoundReadOnlyFileCapability::FDBoundReadOnlyFileCapability(
    FDBoundReadOnlyFileCapability &&other) noexcept
    : descriptor_(std::exchange(other.descriptor_, -1)),
      identity_(other.identity_),
      binding_(std::move(other.binding_)) {}

FDBoundReadOnlyFileCapability &
FDBoundReadOnlyFileCapability::operator=(
    FDBoundReadOnlyFileCapability &&other) noexcept {
  if (this == &other) return *this;
  CloseOnce(descriptor_);
  descriptor_ = std::exchange(other.descriptor_, -1);
  identity_ = other.identity_;
  binding_ = std::move(other.binding_);
  return *this;
}

FDBoundReadOnlyFileCapability::~FDBoundReadOnlyFileCapability() {
  CloseOnce(descriptor_);
}

bool FDBoundReadOnlyFileCapability::NameStillMatches() const {
  return descriptor_ >= 0 && binding_ && binding_->Matches();
}

const FDBoundFileIdentity &
FDBoundReadOnlyFileCapability::identity() const {
  return identity_;
}

bool FDBoundReadOnlyFileCapability::valid() const {
  if (descriptor_ < 0) return false;
  try {
    return SameObject(DescriptorIdentity(descriptor_), identity_);
  } catch (...) {
    return false;
  }
}

void FDBoundReadOnlyFileCapability::CloseDescriptorForTesting() {
  CloseOnce(descriptor_);
}

FDBoundRegisteredToken::FDBoundRegisteredToken(
    const FDBoundReadOnlyFileCapability &capability) {
  if (!capability.valid() || !capability.NameStillMatches()) {
    throw std::runtime_error("cannot register an invalid capability");
  }
  RegistryEntry entry;
  entry.descriptor = DuplicateCloseOnExec(capability.descriptor_);
  try {
    entry.identity = DescriptorIdentity(entry.descriptor);
    if (!SameObject(entry.identity, capability.identity_)) {
      throw std::runtime_error("duplicate fd identity mismatch");
    }
    auto &registry = Registry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    do {
      token_ = NewToken();
    } while (registry.entries.find(token_) != registry.entries.end());
    registry.entries.emplace(token_, entry);
    entry.descriptor = -1;
  } catch (...) {
    CloseOnce(entry.descriptor);
    throw;
  }
}

FDBoundRegisteredToken::FDBoundRegisteredToken(
    FDBoundRegisteredToken &&other) noexcept
    : token_(std::move(other.token_)) {
  other.token_.clear();
}

FDBoundRegisteredToken &FDBoundRegisteredToken::operator=(
    FDBoundRegisteredToken &&other) noexcept {
  if (this == &other) return *this;
  Cancel();
  token_ = std::move(other.token_);
  other.token_.clear();
  return *this;
}

FDBoundRegisteredToken::~FDBoundRegisteredToken() { Cancel(); }

const std::string &FDBoundRegisteredToken::value() const {
  return token_;
}

void FDBoundRegisteredToken::Cancel() {
  if (token_.empty()) return;
  CancelRegistryToken(token_);
  token_.clear();
}

const char *FDBoundReadOnlyVFSName() { return kVFSName; }

int EnsureFDBoundReadOnlyVFSRegistered() {
  std::lock_guard<std::mutex> lock(RegistrationMutex());
  if (Registered()) return SQLITE_OK;
  const int result = sqlite3_vfs_register(&PrototypeVFS(), 0);
  if (result == SQLITE_OK) Registered() = true;
  return result;
}

int ShutdownFDBoundReadOnlyVFS() {
  std::lock_guard<std::mutex> registration_lock(RegistrationMutex());
  if (!Registered()) return SQLITE_OK;
  {
    auto &registry = Registry();
    std::lock_guard<std::mutex> registry_lock(registry.mutex);
    if (!registry.entries.empty() || registry.active_connections != 0) {
      return SQLITE_BUSY;
    }
  }
  const int result = sqlite3_vfs_unregister(&PrototypeVFS());
  if (result == SQLITE_OK) Registered() = false;
  return result;
}

FDBoundVFSStatistics FDBoundReadOnlyVFSStatistics() {
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  return {
      registry.entries.size(),
      registry.active_connections,
      registry.consumed_tokens,
      registry.rejected_names,
      registry.rejected_flags,
      registry.open_failures,
      registry.closed_files,
      registry.bytes_read,
  };
}

bool InvalidateFDBoundRegisteredDescriptorForTesting(
    const std::string &token) {
  auto &registry = Registry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  const auto found = registry.entries.find(token);
  if (found == registry.entries.end()) return false;
  CloseOnce(found->second.descriptor);
  return true;
}

}  // namespace localdict::prototype
