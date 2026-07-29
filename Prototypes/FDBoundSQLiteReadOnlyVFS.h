#pragma once

#include <sqlite3.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace localdict::prototype {

struct FDBoundFileIdentity {
  dev_t device = 0;
  ino_t inode = 0;
  mode_t type = 0;
  uid_t owner = 0;
  nlink_t link_count = 0;
  off_t size = 0;

  bool operator==(const FDBoundFileIdentity &other) const;
};

class FDBoundDirectoryCapability {
 public:
  static FDBoundDirectoryCapability OpenAt(
      int parent_fd, const std::string &component,
      uid_t expected_owner = geteuid());
  static FDBoundDirectoryCapability OpenAt(
      const FDBoundDirectoryCapability &parent,
      const std::string &component, uid_t expected_owner = geteuid());

  FDBoundDirectoryCapability(FDBoundDirectoryCapability &&other) noexcept;
  FDBoundDirectoryCapability &operator=(
      FDBoundDirectoryCapability &&other) noexcept;
  ~FDBoundDirectoryCapability();

  FDBoundDirectoryCapability(const FDBoundDirectoryCapability &) = delete;
  FDBoundDirectoryCapability &operator=(
      const FDBoundDirectoryCapability &) = delete;

  bool NameStillMatches() const;
  int descriptor() const;

 private:
  struct NameBinding;

  FDBoundDirectoryCapability(
      int descriptor, std::shared_ptr<NameBinding> binding);

  int descriptor_ = -1;
  std::shared_ptr<NameBinding> binding_;

  friend class FDBoundReadOnlyFileCapability;
};

class FDBoundReadOnlyFileCapability {
 public:
  static FDBoundReadOnlyFileCapability OpenAt(
      const FDBoundDirectoryCapability &directory,
      const std::string &component, uid_t expected_owner = geteuid());

  FDBoundReadOnlyFileCapability(
      FDBoundReadOnlyFileCapability &&other) noexcept;
  FDBoundReadOnlyFileCapability &operator=(
      FDBoundReadOnlyFileCapability &&other) noexcept;
  ~FDBoundReadOnlyFileCapability();

  FDBoundReadOnlyFileCapability(
      const FDBoundReadOnlyFileCapability &) = delete;
  FDBoundReadOnlyFileCapability &operator=(
      const FDBoundReadOnlyFileCapability &) = delete;

  bool NameStillMatches() const;
  const FDBoundFileIdentity &identity() const;
  bool valid() const;

  // Synthetic fault injection. Production code must not depend on this prototype.
  void CloseDescriptorForTesting();

 private:
  FDBoundReadOnlyFileCapability(
      int descriptor, FDBoundFileIdentity identity,
      std::shared_ptr<const FDBoundDirectoryCapability::NameBinding> binding);

  int descriptor_ = -1;
  FDBoundFileIdentity identity_;
  std::shared_ptr<const FDBoundDirectoryCapability::NameBinding> binding_;

  friend class FDBoundRegisteredToken;
};

class FDBoundRegisteredToken {
 public:
  explicit FDBoundRegisteredToken(
      const FDBoundReadOnlyFileCapability &capability);
  FDBoundRegisteredToken(FDBoundRegisteredToken &&other) noexcept;
  FDBoundRegisteredToken &operator=(
      FDBoundRegisteredToken &&other) noexcept;
  ~FDBoundRegisteredToken();

  FDBoundRegisteredToken(const FDBoundRegisteredToken &) = delete;
  FDBoundRegisteredToken &operator=(
      const FDBoundRegisteredToken &) = delete;

  const std::string &value() const;
  void Cancel();

 private:
  std::string token_;
};

struct FDBoundVFSStatistics {
  std::size_t registry_entries = 0;
  std::size_t active_connections = 0;
  std::uint64_t consumed_tokens = 0;
  std::uint64_t rejected_names = 0;
  std::uint64_t rejected_flags = 0;
  std::uint64_t open_failures = 0;
  std::uint64_t closed_files = 0;
  std::uint64_t bytes_read = 0;
};

const char *FDBoundReadOnlyVFSName();
int EnsureFDBoundReadOnlyVFSRegistered();
int ShutdownFDBoundReadOnlyVFS();
FDBoundVFSStatistics FDBoundReadOnlyVFSStatistics();

// Synthetic fault injection: closes the registry-owned duplicate while leaving
// the one-shot token present so xOpen must detect and consume the invalid entry.
bool InvalidateFDBoundRegisteredDescriptorForTesting(
    const std::string &token);

}  // namespace localdict::prototype
