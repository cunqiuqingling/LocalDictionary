#pragma once

#include <cstdint>
#include <exception>
#include <functional>
#include <memory>
#include <string>

#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace localdict {

struct MDictSourceIdentity {
  dev_t device = 0;
  ino_t inode = 0;
  mode_t type = 0;
  uid_t owner = 0;
  nlink_t link_count = 0;
  off_t size = 0;
  time_t modified_seconds = 0;
  long modified_nanoseconds = 0;

  bool operator==(const MDictSourceIdentity &other) const;
};

struct MDictSourceHashObservation {
  std::uint64_t pread_calls = 0;
  std::uint64_t bytes_read = 0;
};

class MDictSourceHashCancelled final : public std::exception {
 public:
  const char *what() const noexcept override {
    return "source hashing cancelled";
  }
};

using MDictSourceCancellationCheck = std::function<bool()>;

class MDictDirectoryCapability {
 public:
  static MDictDirectoryCapability OpenRoot(
      const std::string &root_path, uid_t expected_owner = geteuid());
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
      int descriptor, MDictSourceIdentity identity,
      std::shared_ptr<NameBinding> binding);

  int descriptor_ = -1;
  MDictSourceIdentity identity_;
  std::shared_ptr<NameBinding> binding_;

  friend class MDictSourceCapability;
};

class MDictSourceCapability {
 public:
  static MDictSourceCapability OpenAt(
      const MDictDirectoryCapability &directory,
      const std::string &component, uid_t expected_owner = geteuid(),
      const MDictSourceCancellationCheck &cancellation_check = {});
  static MDictSourceCapability OpenManagedRelative(
      const std::string &managed_root_path,
      const std::string &relative_path,
      uid_t expected_owner = geteuid(),
      const MDictSourceCancellationCheck &cancellation_check = {});

  MDictSourceCapability(MDictSourceCapability &&other) noexcept;
  MDictSourceCapability &operator=(
      MDictSourceCapability &&other) noexcept;
  ~MDictSourceCapability();

  MDictSourceCapability(const MDictSourceCapability &) = delete;
  MDictSourceCapability &operator=(
      const MDictSourceCapability &) = delete;

  bool NameStillMatches() const;
  bool valid() const;
  bool ValidForPublication() const;
  int borrowedDescriptor() const;
  const MDictSourceIdentity &identity() const;
  const std::string &sha256() const;
  const std::string &sourceName() const;
  MDictSourceHashObservation hashObservation() const;

#if defined(LOCALDICTIONARY_SOURCE_CAPABILITY_TESTING)
  void CloseDescriptorForTesting();
#endif

 private:
  MDictSourceCapability(
      int descriptor, MDictSourceIdentity identity, std::string sha256,
      std::string source_name,
      MDictSourceHashObservation hash_observation,
      std::shared_ptr<const MDictDirectoryCapability::NameBinding> binding);

  int descriptor_ = -1;
  MDictSourceIdentity identity_;
  std::string sha256_;
  std::string source_name_;
  MDictSourceHashObservation hash_observation_;
  std::shared_ptr<const MDictDirectoryCapability::NameBinding> binding_;
};

}  // namespace localdict
