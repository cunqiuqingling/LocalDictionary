#include "FDBoundMDictSource.h"
#include "Support/SyntheticMDictFixture.h"
#include "mdict.h"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <malloc/malloc.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

using localdict::prototype::MDictDirectoryCapability;
using localdict::prototype::MDictSourceCapability;
using localdict::testsupport::BuildSyntheticMDX;

class Harness {
 public:
  void Check(bool condition, const std::string &message) {
    ++assertions_;
    if (!condition) throw std::runtime_error(message);
  }

  template <typename Work>
  void ExpectThrow(Work work, const std::string &message) {
    bool threw = false;
    try {
      work();
    } catch (...) {
      threw = true;
    }
    Check(threw, message);
  }

  int assertions() const { return assertions_; }

 private:
  int assertions_ = 0;
};

class TemporaryDirectory {
 public:
  TemporaryDirectory() {
    std::string pattern =
        (std::filesystem::temp_directory_path() /
         "LocalDictionary-fd-mdict-prototype.XXXXXX")
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

void WriteBytes(const std::filesystem::path &path,
                const std::vector<std::uint8_t> &bytes) {
  std::ofstream output(path, std::ios::binary);
  if (!output) throw std::runtime_error("cannot create synthetic MDX");
  output.write(reinterpret_cast<const char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  if (!output) throw std::runtime_error("cannot write synthetic MDX");
}

std::string SHA256(const std::vector<std::uint8_t> &bytes) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] {};
  if (!CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest)) {
    throw std::runtime_error("test SHA-256 failed");
  }
  static constexpr char kHex[] = "0123456789abcdef";
  std::string result;
  result.reserve(CC_SHA256_DIGEST_LENGTH * 2);
  for (unsigned char byte : digest) {
    result.push_back(kHex[byte >> 4]);
    result.push_back(kHex[byte & 0x0f]);
  }
  return result;
}

int OpenDirectory(const std::filesystem::path &path) {
  const int descriptor =
      open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (descriptor < 0) throw std::runtime_error("cannot open test directory");
  return descriptor;
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

std::size_t HeapBytesInUse() {
  malloc_statistics_t statistics {};
  malloc_zone_statistics(malloc_default_zone(), &statistics);
  return statistics.size_in_use;
}

std::unique_ptr<mdict::Mdict> Parser(
    const MDictSourceCapability &capability) {
  return mdict::Mdict::fromFileDescriptor(
      capability.borrowedDescriptor(), mdict::MdictInputKind::mdx);
}

struct ParseSnapshot {
  std::string header;
  std::uint64_t entries = 0;
  std::size_t keys = 0;
  std::string first_record;
  std::string second_record;
  std::string first_lookup;
};

ParseSnapshot FullSnapshot(mdict::Mdict &dictionary,
                           std::size_t first_length,
                           std::size_t second_length) {
  dictionary.init();
  return {
      dictionary.headerXML(),
      dictionary.entryCount(),
      dictionary.keyList().size(),
      dictionary.readRecordAt(0, first_length),
      dictionary.readRecordAt(first_length + 1,
                              first_length + 1 + second_length),
      dictionary.lookup("aaa"),
  };
}

void CheckEquivalent(Harness &harness, const ParseSnapshot &left,
                     const ParseSnapshot &right,
                     const std::string &context) {
  harness.Check(left.header == right.header, context + " header mismatch");
  harness.Check(left.entries == right.entries,
                context + " entry count mismatch");
  harness.Check(left.keys == right.keys, context + " key count mismatch");
  harness.Check(left.first_record == right.first_record,
                context + " first record mismatch");
  harness.Check(left.second_record == right.second_record,
                context + " second record mismatch");
  harness.Check(left.first_lookup == right.first_lookup,
                context + " lookup mismatch");
}

struct BoundSource {
  MDictDirectoryCapability directory;
  MDictSourceCapability source;
};

BoundSource BindSource(int root_descriptor,
                       const std::string &directory_name,
                       const std::string &file_name = "dictionary.mdx") {
  auto directory =
      MDictDirectoryCapability::OpenAt(root_descriptor, directory_name);
  auto source = MDictSourceCapability::OpenAt(directory, file_name);
  return {std::move(directory), std::move(source)};
}

void TestPathAndFDBaseline(Harness &harness, int root_descriptor,
                           const std::filesystem::path &root) {
  const std::string first = "original-alpha";
  const std::string second = "original-omega";
  const auto bytes = BuildSyntheticMDX(first, second);
  std::filesystem::create_directory(root / "baseline");
  const auto path = root / "baseline/dictionary.mdx";
  WriteBytes(path, bytes);

  mdict::Mdict legacy(path.string());
  const auto legacy_snapshot =
      FullSnapshot(legacy, first.size(), second.size());
  harness.Check(legacy_snapshot.first_record == first,
                "legacy parser returned wrong first record");
  harness.Check(
      legacy_snapshot.first_lookup.size() >= first.size() &&
          legacy_snapshot.first_lookup.compare(0, first.size(), first) == 0,
      "legacy parser lookup returned wrong record");

  auto bound = BindSource(root_descriptor, "baseline");
  harness.Check(bound.directory.NameStillMatches(),
                "baseline directory is not name-bound");
  harness.Check(bound.source.NameStillMatches(),
                "baseline source is not name-bound");
  harness.Check(bound.source.valid(), "baseline source fd is invalid");
  harness.Check(bound.source.sha256() == SHA256(bytes),
                "capability SHA-256 does not match source bytes");
  harness.Check(bound.source.hashObservation().bytes_read == bytes.size(),
                "source hash did not read the complete bound fd");

  const auto descriptors_before = OpenDescriptorCount();
  ParseSnapshot fd_snapshot;
  mdict::MdictSourceReadStatistics read_statistics;
  {
    auto fd_parser = Parser(bound.source);
    harness.Check(OpenDescriptorCount() == descriptors_before + 1,
                  "parser did not own exactly one fd duplicate");
    fd_snapshot =
        FullSnapshot(*fd_parser, first.size(), second.size());
    read_statistics = fd_parser->sourceReadStatistics();
    harness.Check(read_statistics.read_calls > 0 &&
                      read_statistics.bytes_read > 0,
                  "fd parser did not report pread activity");
  }
  harness.Check(OpenDescriptorCount() == descriptors_before,
                "parser destruction did not restore fd count");
  harness.Check(bound.source.valid(),
                "parser destruction closed capability fd");
  CheckEquivalent(harness, legacy_snapshot, fd_snapshot,
                  "legacy/fd full parser");

  auto metadata = Parser(bound.source);
  metadata->initMetadataOnly();
  harness.Check(metadata->headerXML() == legacy_snapshot.header,
                "fd metadata-only header differs");
  harness.Check(metadata->entryCount() == legacy_snapshot.entries,
                "fd metadata-only entry count differs");
  harness.Check(metadata->keyList().empty(),
                "metadata-only fd parser decoded complete key list");
  harness.Check(metadata->sourceReadStatistics().read_calls > 0,
                "metadata-only fd parser did not use pread");
}

void TestLastRecordLookupBoundsRegression(
    Harness &harness, int root_descriptor,
    const std::filesystem::path &root) {
  const std::string first = "bounds---alpha";
  const std::string last = "bounds---omega";
  std::filesystem::create_directory(root / "lookup-last-bound");
  const auto path = root / "lookup-last-bound/dictionary.mdx";
  WriteBytes(path, BuildSyntheticMDX(first, last));

  mdict::Mdict legacy(path.string());
  legacy.init();
  const std::string legacy_last = legacy.lookup("zzz");
  harness.Check(legacy_last.size() == last.size() + 1,
                "last lookup length exceeded decompressed record bound");
  harness.Check(legacy_last.compare(0, last.size(), last) == 0,
                "last lookup content was truncated or crossed");
  harness.Check(legacy_last.back() == '\0',
                "last lookup lost its legal record terminator");

  auto bound = BindSource(root_descriptor, "lookup-last-bound");
  auto fd_parser = Parser(bound.source);
  fd_parser->init();
  const std::string fd_last = fd_parser->lookup("zzz");
  harness.Check(fd_last == legacy_last,
                "path/fd last lookup regression differs");
  harness.Check(
      fd_parser->readRecordAt(first.size() + 1,
                              first.size() + 1 + last.size()) == last,
      "last record range no longer returns exact legal content");
}

void ReplaceCanonical(const std::filesystem::path &directory,
                      const std::vector<std::uint8_t> &replacement) {
  const auto canonical = directory / "dictionary.mdx";
  const auto retained = directory / "retained.mdx";
  std::filesystem::rename(canonical, retained);
  WriteBytes(canonical, replacement);
}

void TestReplacementBeforeParser(Harness &harness, int root_descriptor,
                                 const std::filesystem::path &root) {
  const std::string original_first = "original-alpha";
  const std::string original_second = "original-omega";
  const std::string replaced_first = "replaced-alpha";
  const std::string replaced_second = "replaced-omega";
  const auto original =
      BuildSyntheticMDX(original_first, original_second);
  const auto replacement =
      BuildSyntheticMDX(replaced_first, replaced_second);
  harness.Check(original.size() == replacement.size(),
                "same-size replacement fixture differs in size");
  std::filesystem::create_directory(root / "replace-before");
  WriteBytes(root / "replace-before/dictionary.mdx", original);
  auto bound = BindSource(root_descriptor, "replace-before");
  ReplaceCanonical(root / "replace-before", replacement);
  harness.Check(!bound.source.NameStillMatches(),
                "source name rebind missed replacement before parser");
  harness.Check(bound.source.sha256() == SHA256(original),
                "bound digest switched to replacement");
  harness.Check(bound.source.sha256() != SHA256(replacement),
                "replacement fixture unexpectedly has original digest");

  auto parser = Parser(bound.source);
  const auto snapshot =
      FullSnapshot(*parser, original_first.size(), original_second.size());
  harness.Check(snapshot.first_record == original_first,
                "fd parser switched to pre-construction replacement");
  mdict::Mdict legacy(
      (root / "replace-before/dictionary.mdx").string());
  const auto legacy_snapshot =
      FullSnapshot(legacy, replaced_first.size(), replaced_second.size());
  harness.Check(legacy_snapshot.first_record == replaced_first,
                "legacy path parser did not follow replacement path");
}

void TestReplacementAfterParser(Harness &harness, int root_descriptor,
                                const std::filesystem::path &root) {
  const std::string original_first = "original-alpha";
  const std::string original_second = "original-omega";
  const auto original =
      BuildSyntheticMDX(original_first, original_second);
  const auto replacement =
      BuildSyntheticMDX("replaced-alpha", "replaced-omega");
  std::filesystem::create_directory(root / "replace-after");
  WriteBytes(root / "replace-after/dictionary.mdx", original);
  auto bound = BindSource(root_descriptor, "replace-after");
  auto parser = Parser(bound.source);
  ReplaceCanonical(root / "replace-after", replacement);
  harness.Check(!bound.source.NameStillMatches(),
                "source name rebind missed replacement after parser");
  const auto snapshot =
      FullSnapshot(*parser, original_first.size(), original_second.size());
  harness.Check(snapshot.first_record == original_first,
                "created fd parser switched to replacement");
}

void TestAncestorReplacement(Harness &harness, int root_descriptor,
                             const std::filesystem::path &root) {
  const std::string first = "ancestor-alpha";
  const std::string second = "ancestor-omega";
  std::filesystem::create_directories(root / "ancestor/leaf");
  WriteBytes(root / "ancestor/leaf/dictionary.mdx",
             BuildSyntheticMDX(first, second));
  auto ancestor =
      MDictDirectoryCapability::OpenAt(root_descriptor, "ancestor");
  auto leaf = MDictDirectoryCapability::OpenAt(ancestor, "leaf");
  auto source =
      MDictSourceCapability::OpenAt(leaf, "dictionary.mdx");
  std::filesystem::rename(root / "ancestor",
                          root / "ancestor-retained");
  std::filesystem::create_directories(root / "ancestor/leaf");
  WriteBytes(root / "ancestor/leaf/dictionary.mdx",
             BuildSyntheticMDX("new-root-alpha", "new-root-omega"));
  harness.Check(!ancestor.NameStillMatches(),
                "ancestor capability missed replacement");
  harness.Check(!leaf.NameStillMatches(),
                "leaf capability missed ancestor replacement");
  harness.Check(!source.NameStillMatches(),
                "source capability missed ancestor replacement");
  auto parser = Parser(source);
  harness.Check(
      FullSnapshot(*parser, first.size(), second.size()).first_record ==
          first,
      "ancestor replacement switched fd parser");
}

void TestUnsafeSources(Harness &harness, int root_descriptor,
                       const std::filesystem::path &root) {
  std::filesystem::create_directory(root / "unsafe");
  WriteBytes(root / "unsafe/dictionary.mdx",
             BuildSyntheticMDX("unsafe--alpha", "unsafe--omega"));
  auto directory =
      MDictDirectoryCapability::OpenAt(root_descriptor, "unsafe");
  if (symlink("dictionary.mdx",
              (root / "unsafe/linked.mdx").c_str()) != 0) {
    throw std::runtime_error("cannot create symlink fixture");
  }
  harness.ExpectThrow(
      [&] {
        auto ignored =
            MDictSourceCapability::OpenAt(directory, "linked.mdx");
        (void)ignored;
      },
      "symlink source was accepted");
  std::filesystem::create_directory(root / "unsafe/not-a-file");
  harness.ExpectThrow(
      [&] {
        auto ignored =
            MDictSourceCapability::OpenAt(directory, "not-a-file");
        (void)ignored;
      },
      "non-regular source was accepted");
  harness.ExpectThrow(
      [&] {
        auto ignored = MDictSourceCapability::OpenAt(
            directory, "dictionary.mdx",
            static_cast<uid_t>(geteuid() + 1));
        (void)ignored;
      },
      "owner mismatch was accepted");
  WriteBytes(root / "unsafe/hardlink-source.mdx",
             BuildSyntheticMDX("hardlink-alpha", "hardlink-omega"));
  if (link((root / "unsafe/hardlink-source.mdx").c_str(),
           (root / "unsafe/hardlink-alias.mdx").c_str()) != 0) {
    throw std::runtime_error("cannot create hard-link fixture");
  }
  harness.ExpectThrow(
      [&] {
        auto ignored = MDictSourceCapability::OpenAt(
            directory, "hardlink-source.mdx");
        (void)ignored;
      },
      "hard-linked source was accepted");

  const int writable =
      open((root / "unsafe/dictionary.mdx").c_str(),
           O_RDWR | O_CLOEXEC);
  if (writable < 0) throw std::runtime_error("cannot open writable fixture");
  harness.ExpectThrow(
      [&] {
        auto ignored = mdict::Mdict::fromFileDescriptor(
            writable, mdict::MdictInputKind::mdx);
        (void)ignored;
      },
      "fd parser accepted read-write descriptor");
  close(writable);

  const int closed =
      open((root / "unsafe/dictionary.mdx").c_str(),
           O_RDONLY | O_CLOEXEC);
  if (closed < 0) throw std::runtime_error("cannot open close fixture");
  close(closed);
  harness.ExpectThrow(
      [&] {
        auto ignored = mdict::Mdict::fromFileDescriptor(
            closed, mdict::MdictInputKind::mdx);
        (void)ignored;
      },
      "fd parser accepted a closed descriptor");

  auto early =
      MDictSourceCapability::OpenAt(directory, "dictionary.mdx");
  early.CloseDescriptorForTesting();
  early.CloseDescriptorForTesting();
  harness.Check(!early.valid(),
                "closed source capability still reports valid");
  harness.ExpectThrow(
      [&] {
        auto ignored = Parser(early);
        (void)ignored;
      },
      "closed capability created an fd parser");
}

void TestReadFailures(Harness &harness, int root_descriptor,
                      const std::filesystem::path &root) {
  const auto valid =
      BuildSyntheticMDX("readfail-alpha", "readfail-omega");
  std::filesystem::create_directory(root / "read-failures");
  const auto path = root / "read-failures/dictionary.mdx";
  WriteBytes(path, valid);
  const int writer = open(path.c_str(), O_RDWR | O_CLOEXEC);
  if (writer < 0) throw std::runtime_error("cannot open truncation writer");
  auto bound = BindSource(root_descriptor, "read-failures");
  auto parser = Parser(bound.source);
  parser->initMetadataOnly();

  char byte = 0;
  harness.ExpectThrow(
      [&] { parser->readfile(parser->actualFileBytes(), 1, &byte); },
      "fd reader accepted a read beyond EOF");
  harness.ExpectThrow(
      [&] {
        parser->readfile(std::numeric_limits<std::uint64_t>::max(), 2,
                         &byte);
      },
      "fd reader accepted offset/length overflow");
  static_assert(std::is_unsigned_v<decltype(parser->actualFileBytes())>,
                "MDict offsets must be unsigned");

  if (ftruncate(writer, static_cast<off_t>(valid.size() / 2)) != 0) {
    close(writer);
    throw std::runtime_error("cannot truncate source fixture");
  }
  close(writer);
  harness.ExpectThrow(
      [&] { (void)parser->readRecordAt(0, 5); },
      "short pread did not fail closed");
}

void TestMalformedAndFailureLifecycle(
    Harness &harness, int root_descriptor,
    const std::filesystem::path &root) {
  auto malformed =
      BuildSyntheticMDX("malform-alpha", "malform-omega");
  malformed.at(8) ^= 0x40;
  std::filesystem::create_directory(root / "malformed");
  WriteBytes(root / "malformed/dictionary.mdx", malformed);
  auto bound = BindSource(root_descriptor, "malformed");
  const auto baseline = OpenDescriptorCount();
  {
    auto parser = Parser(bound.source);
    harness.Check(OpenDescriptorCount() == baseline + 1,
                  "failed parser did not own one duplicate");
    harness.ExpectThrow([&] { parser->init(); },
                        "malformed fd MDX initialized");
  }
  harness.Check(OpenDescriptorCount() == baseline,
                "failed parser initialization leaked fd");
}

void TestIndependentAndConcurrent(
    Harness &harness, int root_descriptor,
    const std::filesystem::path &root) {
  std::filesystem::create_directory(root / "independent");
  const std::vector<std::string> values = {
      "source-a-alpha", "source-b-alpha", "source-c-alpha",
      "source-d-alpha",
  };
  for (std::size_t index = 0; index < values.size(); ++index) {
    WriteBytes(root / "independent" /
                   ("dictionary-" + std::to_string(index) + ".mdx"),
               BuildSyntheticMDX(values[index],
                                 "source-x-omega"));
  }
  auto directory =
      MDictDirectoryCapability::OpenAt(root_descriptor, "independent");
  std::vector<std::unique_ptr<MDictSourceCapability>> capabilities;
  for (std::size_t index = 0; index < values.size(); ++index) {
    capabilities.push_back(std::make_unique<MDictSourceCapability>(
        MDictSourceCapability::OpenAt(
            directory,
            "dictionary-" + std::to_string(index) + ".mdx")));
  }
  for (std::size_t index = 0; index < values.size(); ++index) {
    auto parser = Parser(*capabilities[index]);
    harness.Check(
        FullSnapshot(*parser, values[index].size(), 14).first_record ==
            values[index],
        "independent parser crossed source identity");
  }

  std::atomic<int> failures {0};
  std::vector<std::thread> threads;
  constexpr int kConcurrentParsers = 8;
  for (int index = 0; index < kConcurrentParsers; ++index) {
    threads.emplace_back([&] {
      try {
        auto parser = Parser(*capabilities[0]);
        const auto snapshot =
            FullSnapshot(*parser, values[0].size(), 14);
        if (snapshot.first_record != values[0]) ++failures;
      } catch (...) {
        ++failures;
      }
    });
  }
  for (auto &thread : threads) thread.join();
  harness.Check(failures.load() == 0,
                "concurrent fd parser duplicates crossed or failed");
}

struct PerformanceObservation {
  double capability_hash_ms = 0;
  double metadata_ms = 0;
  double full_init_ms = 0;
  double lookup_us = 0;
  std::uint64_t parser_read_calls = 0;
  std::uint64_t parser_read_bytes = 0;
  std::uint64_t hash_read_calls = 0;
  std::uint64_t hash_read_bytes = 0;
  std::size_t heap_delta = 0;
};

PerformanceObservation Observe(
    int root_descriptor, const std::string &directory_name,
    const std::filesystem::path &root, std::size_t padding) {
  const std::string first = "observe--alpha";
  const std::string second = "observe--omega";
  std::filesystem::create_directory(root / directory_name);
  WriteBytes(root / directory_name / "dictionary.mdx",
             BuildSyntheticMDX(first, second, padding));

  const auto hash_start = std::chrono::steady_clock::now();
  auto bound = BindSource(root_descriptor, directory_name);
  const auto hash_end = std::chrono::steady_clock::now();

  const auto metadata_start = std::chrono::steady_clock::now();
  {
    auto parser = Parser(bound.source);
    parser->initMetadataOnly();
  }
  const auto metadata_end = std::chrono::steady_clock::now();

  const std::size_t heap_before = HeapBytesInUse();
  const auto full_start = std::chrono::steady_clock::now();
  auto parser = Parser(bound.source);
  parser->init();
  const auto full_end = std::chrono::steady_clock::now();
  const std::size_t heap_during = HeapBytesInUse();
  const auto lookup_start = std::chrono::steady_clock::now();
  const std::string record =
      parser->readRecordAt(0, first.size());
  const auto lookup_end = std::chrono::steady_clock::now();
  if (record != first) {
    throw std::runtime_error("performance observation read wrong record");
  }
  const auto parser_statistics = parser->sourceReadStatistics();
  const auto hash_statistics = bound.source.hashObservation();
  return {
      std::chrono::duration<double, std::milli>(hash_end - hash_start)
          .count(),
      std::chrono::duration<double, std::milli>(
          metadata_end - metadata_start)
          .count(),
      std::chrono::duration<double, std::milli>(full_end - full_start)
          .count(),
      std::chrono::duration<double, std::micro>(
          lookup_end - lookup_start)
          .count(),
      parser_statistics.read_calls,
      parser_statistics.bytes_read,
      hash_statistics.pread_calls,
      hash_statistics.bytes_read,
      heap_during > heap_before ? heap_during - heap_before : 0,
  };
}

void TestPerformance(Harness &harness, int root_descriptor,
                     const std::filesystem::path &root,
                     PerformanceObservation &small,
                     PerformanceObservation &medium) {
  small = Observe(root_descriptor, "performance-small", root, 0);
  constexpr std::size_t kPadding = 8 * 1024 * 1024;
  medium =
      Observe(root_descriptor, "performance-medium", root, kPadding);
  harness.Check(medium.hash_read_bytes >= kPadding,
                "capability hash did not cover medium source");
  harness.Check(medium.parser_read_bytes < kPadding / 4,
                "fd parser appears to read the whole medium source");
  harness.Check(medium.heap_delta < kPadding / 4,
                "fd parser heap appears linear in medium source size");
  harness.Check(medium.parser_read_calls > 0,
                "medium fd parser made no pread calls");
}

}  // namespace

int main() {
  try {
    Harness harness;
    TemporaryDirectory temporary;
    const auto root = temporary.path();
    const int root_descriptor = OpenDirectory(root);

    TestPathAndFDBaseline(harness, root_descriptor, root);
    TestLastRecordLookupBoundsRegression(harness, root_descriptor, root);
    TestReplacementBeforeParser(harness, root_descriptor, root);
    TestReplacementAfterParser(harness, root_descriptor, root);
    TestAncestorReplacement(harness, root_descriptor, root);
    TestUnsafeSources(harness, root_descriptor, root);
    TestReadFailures(harness, root_descriptor, root);
    TestMalformedAndFailureLifecycle(harness, root_descriptor, root);
    TestIndependentAndConcurrent(harness, root_descriptor, root);
    PerformanceObservation small;
    PerformanceObservation medium;
    TestPerformance(harness, root_descriptor, root, small, medium);

    close(root_descriptor);
    std::printf(
        "FDBoundMDictSourcePrototypeSmoke passed assertions=%d "
        "small_hash_ms=%.2f medium_hash_ms=%.2f "
        "small_metadata_ms=%.2f medium_metadata_ms=%.2f "
        "small_full_ms=%.2f medium_full_ms=%.2f "
        "small_lookup_us=%.2f medium_lookup_us=%.2f "
        "small_parser_pread_calls=%llu medium_parser_pread_calls=%llu "
        "small_parser_bytes=%llu medium_parser_bytes=%llu "
        "small_hash_pread_calls=%llu medium_hash_pread_calls=%llu "
        "small_hash_bytes=%llu medium_hash_bytes=%llu "
        "small_heap_delta=%zu medium_heap_delta=%zu "
        "extra_fd_per_parser=1\n",
        harness.assertions(), small.capability_hash_ms,
        medium.capability_hash_ms, small.metadata_ms, medium.metadata_ms,
        small.full_init_ms, medium.full_init_ms, small.lookup_us,
        medium.lookup_us,
        static_cast<unsigned long long>(small.parser_read_calls),
        static_cast<unsigned long long>(medium.parser_read_calls),
        static_cast<unsigned long long>(small.parser_read_bytes),
        static_cast<unsigned long long>(medium.parser_read_bytes),
        static_cast<unsigned long long>(small.hash_read_calls),
        static_cast<unsigned long long>(medium.hash_read_calls),
        static_cast<unsigned long long>(small.hash_read_bytes),
        static_cast<unsigned long long>(medium.hash_read_bytes),
        small.heap_delta, medium.heap_delta);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "FDBoundMDictSourcePrototypeSmoke failed: %s\n",
                 error.what());
    return 1;
  }
}
