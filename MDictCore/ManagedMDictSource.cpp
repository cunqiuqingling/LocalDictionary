#include "ManagedMDictSource.h"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <stdexcept>
#include <system_error>
#include <utility>
#include <vector>

#include <unistd.h>

namespace localdict {
namespace {

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
                            "cannot duplicate descriptor");
  }
  return duplicate;
}

void ValidateComponent(const std::string &component) {
  if (component.empty() || component == "." || component == ".." ||
      component.find('/') != std::string::npos ||
      component.find('\\') != std::string::npos ||
      component.find('\0') != std::string::npos) {
    throw std::invalid_argument("unsafe source component");
  }
}

std::vector<std::string> RelativeComponents(const std::string &relative_path) {
  if (relative_path.empty() || relative_path.front() == '/' ||
      relative_path.back() == '/' ||
      relative_path.find('\\') != std::string::npos ||
      relative_path.find('\0') != std::string::npos) {
    throw std::invalid_argument("unsafe managed source path");
  }
  std::vector<std::string> components;
  std::size_t start = 0;
  while (start < relative_path.size()) {
    const std::size_t separator = relative_path.find('/', start);
    const std::size_t end =
        separator == std::string::npos ? relative_path.size() : separator;
    const std::string component = relative_path.substr(start, end - start);
    ValidateComponent(component);
    components.push_back(component);
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  if (components.size() < 2 || components.front() != "Dictionaries") {
    throw std::invalid_argument("source is outside managed Dictionaries");
  }
  return components;
}

MDictSourceIdentity IdentityFromStat(const struct stat &value) {
  return {
      value.st_dev,
      value.st_ino,
      static_cast<mode_t>(value.st_mode & S_IFMT),
      value.st_uid,
      value.st_nlink,
      value.st_size,
      value.st_mtimespec.tv_sec,
      value.st_mtimespec.tv_nsec,
  };
}

MDictSourceIdentity DescriptorIdentity(int descriptor) {
  struct stat value {};
  if (fstat(descriptor, &value) != 0) {
    throw std::system_error(errno, std::generic_category(), "fstat failed");
  }
  return IdentityFromStat(value);
}

MDictSourceIdentity EntryIdentity(int parent_descriptor,
                                  const std::string &component) {
  struct stat value {};
  if (fstatat(parent_descriptor, component.c_str(), &value,
              AT_SYMLINK_NOFOLLOW) != 0) {
    throw std::system_error(errno, std::generic_category(), "fstatat failed");
  }
  return IdentityFromStat(value);
}

bool SameObject(const MDictSourceIdentity &left,
                const MDictSourceIdentity &right) {
  if (left.device != right.device || left.inode != right.inode ||
      left.type != right.type || left.owner != right.owner) {
    return false;
  }
  if (left.type == S_IFREG) {
    return left.link_count == right.link_count && left.size == right.size &&
           left.modified_seconds == right.modified_seconds &&
           left.modified_nanoseconds == right.modified_nanoseconds;
  }
  return true;
}

void ValidateDirectoryIdentity(const MDictSourceIdentity &identity,
                               uid_t expected_owner) {
  if (identity.type != S_IFDIR || identity.owner != expected_owner) {
    throw std::runtime_error("unsafe directory identity");
  }
}

void ValidateFileIdentity(const MDictSourceIdentity &identity,
                          uid_t expected_owner) {
  if (identity.type != S_IFREG || identity.owner != expected_owner ||
      identity.link_count != 1 || identity.size < 0) {
    throw std::runtime_error("unsafe source identity");
  }
}

void CheckCancellation(
    const MDictSourceCancellationCheck &cancellation_check) {
  if (cancellation_check && cancellation_check()) {
    throw MDictSourceHashCancelled();
  }
}

std::pair<std::string, MDictSourceHashObservation> HashDescriptor(
    int descriptor, const MDictSourceIdentity &identity,
    const MDictSourceCancellationCheck &cancellation_check) {
  CC_SHA256_CTX context {};
  if (CC_SHA256_Init(&context) != 1) {
    throw std::runtime_error("SHA-256 initialization failed");
  }
  std::array<unsigned char, 64 * 1024> buffer {};
  std::uint64_t offset = 0;
  MDictSourceHashObservation observation;
  const auto expected_size = static_cast<std::uint64_t>(identity.size);
  while (offset < expected_size) {
    CheckCancellation(cancellation_check);
    const std::size_t requested = static_cast<std::size_t>(
        std::min<std::uint64_t>(buffer.size(), expected_size - offset));
    if (offset >
        static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
      throw std::overflow_error("source offset exceeds off_t");
    }
    ++observation.pread_calls;
    const ssize_t count =
        pread(descriptor, buffer.data(), requested,
              static_cast<off_t>(offset));
    if (count > 0) {
      if (CC_SHA256_Update(&context, buffer.data(),
                           static_cast<CC_LONG>(count)) != 1) {
        throw std::runtime_error("SHA-256 update failed");
      }
      offset += static_cast<std::uint64_t>(count);
      observation.bytes_read += static_cast<std::uint64_t>(count);
      continue;
    }
    if (count < 0 && errno == EINTR) continue;
    throw std::runtime_error("short source read while hashing");
  }
  CheckCancellation(cancellation_check);

  std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest {};
  if (CC_SHA256_Final(digest.data(), &context) != 1) {
    throw std::runtime_error("SHA-256 finalization failed");
  }
  static constexpr char kHex[] = "0123456789abcdef";
  std::string hex;
  hex.reserve(digest.size() * 2);
  for (unsigned char byte : digest) {
    hex.push_back(kHex[byte >> 4]);
    hex.push_back(kHex[byte & 0x0f]);
  }
  return {std::move(hex), observation};
}

}  // namespace

struct MDictDirectoryCapability::NameBinding {
  int parent_descriptor = -1;
  std::string component;
  MDictSourceIdentity identity;
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

bool MDictSourceIdentity::operator==(
    const MDictSourceIdentity &other) const {
  return SameObject(*this, other);
}

MDictDirectoryCapability::MDictDirectoryCapability(
    int descriptor, MDictSourceIdentity identity,
    std::shared_ptr<NameBinding> binding)
    : descriptor_(descriptor), identity_(identity), binding_(std::move(binding)) {}

MDictDirectoryCapability MDictDirectoryCapability::OpenRoot(
    const std::string &root_path, uid_t expected_owner) {
  if (root_path.empty()) {
    throw std::invalid_argument("managed root path is empty");
  }
  const int descriptor =
      open(root_path.c_str(),
           O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::system_error(errno, std::generic_category(),
                            "cannot open managed root");
  }
  try {
    const auto observed = DescriptorIdentity(descriptor);
    ValidateDirectoryIdentity(observed, expected_owner);
    return MDictDirectoryCapability(descriptor, observed, nullptr);
  } catch (...) {
    int owned = descriptor;
    CloseOnce(owned);
    throw;
  }
}

MDictDirectoryCapability MDictDirectoryCapability::OpenAt(
    int parent_fd, const std::string &component, uid_t expected_owner) {
  ValidateComponent(component);
  const int descriptor =
      openat(parent_fd, component.c_str(),
             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::system_error(errno, std::generic_category(),
                            "cannot open source directory");
  }
  try {
    const auto observed = DescriptorIdentity(descriptor);
    ValidateDirectoryIdentity(observed, expected_owner);
    if (!SameObject(observed, EntryIdentity(parent_fd, component))) {
      throw std::runtime_error("directory name rebind failed");
    }
    auto binding = std::make_shared<NameBinding>();
    binding->parent_descriptor = DuplicateCloseOnExec(parent_fd);
    binding->component = component;
    binding->identity = observed;
    return MDictDirectoryCapability(descriptor, observed, std::move(binding));
  } catch (...) {
    int owned = descriptor;
    CloseOnce(owned);
    throw;
  }
}

MDictDirectoryCapability MDictDirectoryCapability::OpenAt(
    const MDictDirectoryCapability &parent,
    const std::string &component, uid_t expected_owner) {
  if (!parent.NameStillMatches()) {
    throw std::runtime_error("parent directory capability is no longer bound");
  }
  auto child = OpenAt(parent.descriptor_, component, expected_owner);
  child.binding_->ancestor = parent.binding_;
  return child;
}

MDictDirectoryCapability::MDictDirectoryCapability(
    MDictDirectoryCapability &&other) noexcept
    : descriptor_(std::exchange(other.descriptor_, -1)),
      identity_(other.identity_),
      binding_(std::move(other.binding_)) {}

MDictDirectoryCapability &MDictDirectoryCapability::operator=(
    MDictDirectoryCapability &&other) noexcept {
  if (this == &other) return *this;
  CloseOnce(descriptor_);
  descriptor_ = std::exchange(other.descriptor_, -1);
  identity_ = other.identity_;
  binding_ = std::move(other.binding_);
  return *this;
}

MDictDirectoryCapability::~MDictDirectoryCapability() {
  CloseOnce(descriptor_);
}

bool MDictDirectoryCapability::NameStillMatches() const {
  if (descriptor_ < 0) return false;
  try {
    if (!SameObject(DescriptorIdentity(descriptor_), identity_)) return false;
  } catch (...) {
    return false;
  }
  return !binding_ || binding_->Matches();
}

int MDictDirectoryCapability::descriptor() const { return descriptor_; }

MDictSourceCapability::MDictSourceCapability(
    int descriptor, MDictSourceIdentity identity, std::string sha256,
    std::string source_name,
    MDictSourceHashObservation hash_observation,
    std::shared_ptr<const MDictDirectoryCapability::NameBinding> binding)
    : descriptor_(descriptor),
      identity_(identity),
      sha256_(std::move(sha256)),
      source_name_(std::move(source_name)),
      hash_observation_(hash_observation),
      binding_(std::move(binding)) {}

MDictSourceCapability MDictSourceCapability::OpenAt(
    const MDictDirectoryCapability &directory,
    const std::string &component, uid_t expected_owner,
    const MDictSourceCancellationCheck &cancellation_check) {
  ValidateComponent(component);
  CheckCancellation(cancellation_check);
  if (!directory.NameStillMatches()) {
    throw std::runtime_error("directory capability is no longer bound");
  }
  const int descriptor =
      openat(directory.descriptor_, component.c_str(),
             O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::system_error(errno, std::generic_category(),
                            "cannot open source file");
  }
  try {
    const auto observed = DescriptorIdentity(descriptor);
    ValidateFileIdentity(observed, expected_owner);
    if (!SameObject(observed,
                    EntryIdentity(directory.descriptor_, component))) {
      throw std::runtime_error("source name rebind failed");
    }
    auto [sha256, hash_observation] =
        HashDescriptor(descriptor, observed, cancellation_check);
    if (!SameObject(DescriptorIdentity(descriptor), observed)) {
      throw std::runtime_error("source identity changed while hashing");
    }
    auto binding = std::make_shared<MDictDirectoryCapability::NameBinding>();
    binding->parent_descriptor =
        DuplicateCloseOnExec(directory.descriptor_);
    binding->component = component;
    binding->identity = observed;
    binding->ancestor = directory.binding_;
    if (!binding->Matches()) {
      throw std::runtime_error("source binding changed while hashing");
    }
    return MDictSourceCapability(
        descriptor, observed, std::move(sha256), component,
        hash_observation, std::move(binding));
  } catch (...) {
    int owned = descriptor;
    CloseOnce(owned);
    throw;
  }
}

MDictSourceCapability MDictSourceCapability::OpenManagedRelative(
    const std::string &managed_root_path,
    const std::string &relative_path, uid_t expected_owner,
    const MDictSourceCancellationCheck &cancellation_check) {
  const auto components = RelativeComponents(relative_path);
  auto directory =
      MDictDirectoryCapability::OpenRoot(managed_root_path, expected_owner);
  for (std::size_t index = 0; index + 1 < components.size(); ++index) {
    directory = MDictDirectoryCapability::OpenAt(
        directory, components[index], expected_owner);
  }
  return OpenAt(directory, components.back(), expected_owner,
                cancellation_check);
}

MDictSourceCapability::MDictSourceCapability(
    MDictSourceCapability &&other) noexcept
    : descriptor_(std::exchange(other.descriptor_, -1)),
      identity_(other.identity_),
      sha256_(std::move(other.sha256_)),
      source_name_(std::move(other.source_name_)),
      hash_observation_(other.hash_observation_),
      binding_(std::move(other.binding_)) {}

MDictSourceCapability &MDictSourceCapability::operator=(
    MDictSourceCapability &&other) noexcept {
  if (this == &other) return *this;
  CloseOnce(descriptor_);
  descriptor_ = std::exchange(other.descriptor_, -1);
  identity_ = other.identity_;
  sha256_ = std::move(other.sha256_);
  source_name_ = std::move(other.source_name_);
  hash_observation_ = other.hash_observation_;
  binding_ = std::move(other.binding_);
  return *this;
}

MDictSourceCapability::~MDictSourceCapability() {
  CloseOnce(descriptor_);
}

bool MDictSourceCapability::NameStillMatches() const {
  return descriptor_ >= 0 && binding_ && binding_->Matches();
}

bool MDictSourceCapability::valid() const {
  if (descriptor_ < 0) return false;
  try {
    return SameObject(DescriptorIdentity(descriptor_), identity_);
  } catch (...) {
    return false;
  }
}

bool MDictSourceCapability::ValidForPublication() const {
  return valid() && NameStillMatches();
}

int MDictSourceCapability::borrowedDescriptor() const {
  return descriptor_;
}

const MDictSourceIdentity &MDictSourceCapability::identity() const {
  return identity_;
}

const std::string &MDictSourceCapability::sha256() const {
  return sha256_;
}

const std::string &MDictSourceCapability::sourceName() const {
  return source_name_;
}

MDictSourceHashObservation MDictSourceCapability::hashObservation() const {
  return hash_observation_;
}

#if defined(LOCALDICTIONARY_SOURCE_CAPABILITY_TESTING)
void MDictSourceCapability::CloseDescriptorForTesting() {
  CloseOnce(descriptor_);
}
#endif

}  // namespace localdict
