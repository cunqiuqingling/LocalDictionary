#include "mdict.h"

#include <mach/mach.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <regex>
#include <set>
#include <string>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;

double milliseconds(Clock::time_point start, Clock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - start).count();
}

uint64_t residentBytes() {
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
    return 0;
  }
  return info.resident_size;
}

std::string jsonEscape(const std::string &input) {
  std::string output;
  output.reserve(input.size());
  for (unsigned char c : input) {
    switch (c) {
      case '\\': output += "\\\\"; break;
      case '"': output += "\\\""; break;
      case '\n': output += "\\n"; break;
      case '\r': output += "\\r"; break;
      case '\t': output += "\\t"; break;
      default:
        if (c >= 0x20) output.push_back(static_cast<char>(c));
    }
  }
  return output;
}

std::string preview(const std::string &html) {
  std::string text = std::regex_replace(html, std::regex("<[^>]*>"), " ");
  text = std::regex_replace(text, std::regex("&nbsp;|&#160;"), " ");
  text = std::regex_replace(text, std::regex("\\s+"), " ");
  if (text.size() > 220) text.resize(220);
  return text;
}

size_t countMatches(const std::string &value, const std::regex &pattern) {
  return static_cast<size_t>(
      std::distance(std::sregex_iterator(value.begin(), value.end(), pattern),
                    std::sregex_iterator()));
}

std::vector<std::string> resourceSamples(const std::string &html) {
  const std::regex attributePattern(
      "(?:src|href)\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
      std::regex::icase);
  const std::regex resourcePattern(
      "^(?:sound://|file://|/|\\\\)|\\.(?:css|js|png|jpe?g|gif|svg|mp3|wav|ogg|ttf|otf|woff2?)(?:$|[?#])",
      std::regex::icase);
  std::vector<std::string> samples;
  std::set<std::string> seen;
  for (auto it = std::sregex_iterator(html.begin(), html.end(), attributePattern);
       it != std::sregex_iterator() && samples.size() < 8; ++it) {
    const std::string value = (*it)[1].str();
    if (std::regex_search(value, resourcePattern) && seen.insert(value).second) {
      samples.push_back(value);
    }
  }
  return samples;
}

std::string jsonArray(const std::vector<std::string> &values) {
  std::string output = "[";
  for (size_t i = 0; i < values.size(); ++i) {
    if (i != 0) output += ',';
    output += '"' + jsonEscape(values[i]) + '"';
  }
  output += ']';
  return output;
}

std::string resolveEntry(mdict::Mdict &dictionary, const std::string &word,
                         int &redirects, std::string &terminalKey) {
  terminalKey = word;
  std::string html;
  const std::regex redirectPattern("^@@@LINK=([^\\r\\n]+)");
  std::set<std::string> visited;
  for (int depth = 0; depth < 8; ++depth) {
    if (!visited.insert(terminalKey).second) return {};
    html = dictionary.lookup(terminalKey);
    std::smatch match;
    if (!std::regex_search(html, match, redirectPattern)) return html;
    terminalKey = match[1].str();
    while (!terminalKey.empty() &&
           std::isspace(static_cast<unsigned char>(terminalKey.back()))) {
      terminalKey.pop_back();
    }
    ++redirects;
  }
  return {};
}

std::string normalizedResourceKey(std::string value) {
  std::replace(value.begin(), value.end(), '/', '\\');
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::vector<std::string> keySuggestions(mdict::Mdict &dictionary,
                                        const std::string &query) {
  std::vector<std::string> matches;
  const std::string normalizedQuery = normalizedResourceKey(query);
  const size_t separator = normalizedQuery.find_last_of('\\');
  const std::string basename = normalizedQuery.substr(
      separator == std::string::npos ? 0 : separator + 1);
  for (const auto *item : dictionary.keyList()) {
    if (item == nullptr) continue;
    const std::string normalized = normalizedResourceKey(item->key_word);
    const size_t itemSeparator = normalized.find_last_of('\\');
    const std::string itemBasename = normalized.substr(
        itemSeparator == std::string::npos ? 0 : itemSeparator + 1);
    if (normalized == normalizedQuery ||
        (!basename.empty() && itemBasename == basename)) {
      matches.push_back(item->key_word);
      if (matches.size() == 5) break;
    }
  }
  return matches;
}
}  // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::cerr << "Usage: mdict-validate <dictionary.mdx> <word> [word ...]\n";
    return 64;
  }

  const std::filesystem::path dictionaryPath(argv[1]);
  if (!std::filesystem::is_regular_file(dictionaryPath)) {
    std::cerr << "Dictionary does not exist: " << dictionaryPath << "\n";
    return 66;
  }

  const uint64_t rssBefore = residentBytes();
  std::string extension = dictionaryPath.extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  const bool isResourceArchive = extension == ".mdd";
  const auto initStart = Clock::now();
  mdict::Mdict dictionary(dictionaryPath.string());
  dictionary.init();
  const auto initEnd = Clock::now();
  const uint64_t rssAfterInit = residentBytes();

  std::cout << "{\"event\":\"init\",\"dictionary\":\""
            << jsonEscape(dictionaryPath.filename().string())
            << "\",\"milliseconds\":" << std::fixed << std::setprecision(3)
            << milliseconds(initStart, initEnd) << ",\"rssBeforeBytes\":"
            << rssBefore << ",\"rssAfterBytes\":" << rssAfterInit << "}\n";

  const std::regex imagePattern("<(img|svg)\\b", std::regex::icase);
  const std::regex audioPattern("sound://|<audio\\b|\\.(mp3|wav|ogg)",
                                std::regex::icase);
  const std::regex entryPattern("entry://|@@@LINK=", std::regex::icase);
  const std::regex scriptPattern("<script\\b|javascript:", std::regex::icase);

  int misses = 0;
  for (int index = 2; index < argc; ++index) {
    const std::string word(argv[index]);
    const auto lookupStart = Clock::now();
    int redirects = 0;
    std::string terminalKey;
    const std::string html = isResourceArchive
                                 ? dictionary.locate(word, MDICT_ENCODING_HEX)
                                 : resolveEntry(dictionary, word, redirects, terminalKey);
    if (isResourceArchive) terminalKey = word;
    const auto lookupEnd = Clock::now();
    if (html.empty()) ++misses;
    const auto suggestions = html.empty()
                                 ? keySuggestions(dictionary, word)
                                 : std::vector<std::string>{};

    std::cout << "{\"event\":\"lookup\",\"word\":\"" << jsonEscape(word)
              << "\",\"found\":" << (html.empty() ? "false" : "true")
              << ",\"bytes\":" << html.size() << ",\"milliseconds\":"
              << milliseconds(lookupStart, lookupEnd)
              << ",\"redirects\":" << redirects
              << ",\"terminalKey\":\"" << jsonEscape(terminalKey) << "\""
              << ",\"images\":" << countMatches(html, imagePattern)
              << ",\"audioRefs\":" << countMatches(html, audioPattern)
              << ",\"entryRefs\":" << countMatches(html, entryPattern)
              << ",\"scriptRefs\":" << countMatches(html, scriptPattern)
              << ",\"resourceSamples\":" << jsonArray(resourceSamples(html))
              << ",\"keySuggestions\":" << jsonArray(suggestions)
              << ",\"preview\":\"" << jsonEscape(preview(html)) << "\"}\n";
  }

  std::cout << "{\"event\":\"complete\",\"misses\":" << misses
            << ",\"rssBytes\":" << residentBytes() << "}\n";
  return misses == 0 ? 0 : 2;
}
