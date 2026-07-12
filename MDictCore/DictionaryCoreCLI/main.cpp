#include "SQLiteDictionaryCore.h"

#include <libproc.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <unistd.h>

#include <algorithm>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

namespace {
uint64_t residentBytes() {
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
    return 0;
  }
  return info.resident_size;
}

struct IOBytes {
  uint64_t read = 0;
  uint64_t written = 0;
};

IOBytes ioBytes() {
  rusage_info_v4 info{};
  if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4,
                      reinterpret_cast<rusage_info_t *>(&info)) != 0) {
    return {};
  }
  return {info.ri_diskio_bytesread, info.ri_diskio_byteswritten};
}

uint64_t peakResidentBytes() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
  return static_cast<uint64_t>(usage.ru_maxrss);
}

std::string escape(const std::string &value) {
  std::string output;
  for (unsigned char c : value) {
    if (c == '\\') output += "\\\\";
    else if (c == '"') output += "\\\"";
    else if (c >= 0x20) output.push_back(static_cast<char>(c));
  }
  return output;
}

void usage(const char *program) {
  std::cerr << "Usage: " << program
            << " --dictionary <file.mdx> --index <file.sqlite> [--rebuild] "
               "<word> [word ...]\n";
}
}  // namespace

int main(int argc, char **argv) {
  std::string dictionary_path;
  std::string index_path;
  bool rebuild = false;
  std::vector<std::string> words;
  for (int i = 1; i < argc; ++i) {
    const std::string argument(argv[i]);
    if (argument == "--dictionary" && i + 1 < argc) {
      dictionary_path = argv[++i];
    } else if (argument == "--index" && i + 1 < argc) {
      index_path = argv[++i];
    } else if (argument == "--rebuild") {
      rebuild = true;
    } else {
      words.push_back(argument);
    }
  }
  if (dictionary_path.empty() || index_path.empty() || words.empty()) {
    usage(argv[0]);
    return 64;
  }

  try {
    const IOBytes io_before = ioBytes();
    localdict::SQLiteDictionaryCore core(dictionary_path, index_path);
    const auto opened = core.open(rebuild);
    const IOBytes io_after_open = ioBytes();
    std::cout << std::fixed << std::setprecision(3)
              << "{\"event\":\"open\",\"rebuilt\":"
              << (opened.rebuilt ? "true" : "false")
              << ",\"entries\":" << opened.entry_count
              << ",\"indexMilliseconds\":" << opened.index_milliseconds
              << ",\"startupMilliseconds\":" << opened.startup_milliseconds
              << ",\"rssBytes\":" << residentBytes()
              << ",\"diskReadBytes\":" << (io_after_open.read - io_before.read)
              << ",\"diskWriteBytes\":"
              << (io_after_open.written - io_before.written) << "}\n";

    size_t hits = 0;
    double total = 0;
    double slowest = 0;
    std::string slowest_word;
    for (const auto &word : words) {
      const auto result = core.lookup(word);
      if (result.found) ++hits;
      total += result.milliseconds;
      if (result.milliseconds > slowest) {
        slowest = result.milliseconds;
        slowest_word = word;
      }
      std::cout << "{\"event\":\"lookup\",\"word\":\"" << escape(word)
                << "\",\"normalized\":\"" << escape(result.normalized_query)
                << "\",\"found\":" << (result.found ? "true" : "false")
                << ",\"matched\":\"" << escape(result.matched_headword)
                << "\",\"caseFallback\":"
                << (result.used_case_fallback ? "true" : "false")
                << ",\"cacheHit\":" << (result.cache_hit ? "true" : "false")
                << ",\"bytes\":" << result.html.size()
                << ",\"milliseconds\":" << result.milliseconds << "}\n";
    }

    const IOBytes io_after = ioBytes();
    const auto cache = core.cacheStats();
    const uint64_t index_size = std::filesystem::file_size(index_path);
    std::cout << "{\"event\":\"summary\",\"tested\":" << words.size()
              << ",\"found\":" << hits << ",\"averageMilliseconds\":"
              << (total / static_cast<double>(words.size()))
              << ",\"slowestMilliseconds\":" << slowest
              << ",\"slowestWord\":\"" << escape(slowest_word)
              << "\",\"indexBytes\":" << index_size
              << ",\"rssBytes\":" << residentBytes()
              << ",\"peakRssBytes\":" << peakResidentBytes()
              << ",\"diskReadBytes\":" << (io_after.read - io_before.read)
              << ",\"diskWriteBytes\":" << (io_after.written - io_before.written)
              << ",\"cacheEntries\":" << cache.entries
              << ",\"cacheBytes\":" << cache.bytes
              << ",\"cacheMaximumEntries\":" << cache.maximum_entries
              << ",\"cacheMaximumBytes\":" << cache.maximum_bytes << "}\n";
    return hits == words.size() ? 0 : 2;
  } catch (const std::exception &error) {
    std::cerr << "mdict-core: " << error.what() << "\n";
    return 1;
  }
}

