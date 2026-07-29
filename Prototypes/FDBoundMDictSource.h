#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace localdict::prototype {

struct MDictSourceIdentity {
  dev_t device = 0;
  ino_t inode = 0;
  mode_t type = 0;
  uid_t owner = 0;
  nlink_t link_count = 0;
  off_t size = 0;

  bool operator==(const MDictSourceIdentity &other) const;
};

struct MDictSourceHashObservation {
  std::uint64_t pread_calls = 0;
  std::uint64_t bytes_read = 0;
};

class MDictDirectoryCapability {
 public:
  static MDictDirectoryCapability OpenAt(
      int parent_fd, const std::string &component,
      uid_t expected_owner = geteuid());
  static MDictDirectoryCapability OpenAt(
      const MDictDirectoryCapability &parent,
      const std::string &component, uid_t expected_owner = geteuid());

  MDictDirectoryCapability(MDictDirectoryCapability &&other) noexcept;
  MDictDirectoryCapability &operator=(
      MDictDirectoryCapability &&other) noexcept;
  ~MDictDirectoryCapability();

  MDictDirectoryCapability(const MDictDirectoryCapability &) = delete;
  MDictDirectoryCapability &operator=(
      const MDictDirectoryCapability &) = delete;

  bool NameStillMatches() const;
  int descriptor() const;

 private:
  struct NameBinding;

  MDictDirectoryCapability(
      int descriptor, std::shared_ptr<NameBinding> binding);

  int descriptor_ = -1;
  std::shared_ptr<NameBinding> binding_;

  friend class MDictSourceCapability;
};

class MDictSourceCapability {
 public:
  static MDictSourceCapability OpenAt(
      const MDictDirectoryCapability &directory,
      const std::string &component, uid_t expected_owner = geteuid());

  MDictSourceCapability(MDictSourceCapability &&other) noexcept;
  MDictSourceCapability &operator=(
      MDictSourceCapability &&other) noexcept;
  ~MDictSourceCapability();

  MDictSourceCapability(const MDictSourceCapability &) = delete;
  MDictSourceCapability &operator=(const MDictSourceCapability &) = delete;

  bool NameStillMatches() const;
  bool valid() const;
  int borrowedDescriptor() const;
  const MDictSourceIdentity &identity() const;
  const std::string &sha256() const;
  MDictSourceHashObservation hashObservation() const;

  // Synthetic fault injection. Production code must not depend on this
  // prototype.
  void CloseDescriptorForTesting();

 private:
  MDictSourceCapability(
      int descriptor, MDictSourceIdentity identity, std::string sha256,
      MDictSourceHashObservation hash_observation,
      std::shared_ptr<const MDictDirectoryCapability::NameBinding> binding);

  int descriptor_ = -1;
  MDictSourceIdentity identity_;
  std::string sha256_;
  MDictSourceHashObservation hash_observation_;
  std::shared_ptr<const MDictDirectoryCapability::NameBinding> binding_;
};

}  // namespace localdict::prototype
