#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "miniz/miniz.h"

namespace localdict::testsupport {

inline void AppendBE16(std::vector<std::uint8_t> &output,
                       std::uint16_t value) {
  output.push_back(static_cast<std::uint8_t>(value >> 8));
  output.push_back(static_cast<std::uint8_t>(value));
}

inline void AppendBE32(std::vector<std::uint8_t> &output,
                       std::uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) {
    output.push_back(static_cast<std::uint8_t>(value >> shift));
  }
}

inline void AppendLE32(std::vector<std::uint8_t> &output,
                       std::uint32_t value) {
  for (int shift = 0; shift <= 24; shift += 8) {
    output.push_back(static_cast<std::uint8_t>(value >> shift));
  }
}

inline void AppendBE64(std::vector<std::uint8_t> &output,
                       std::uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    output.push_back(static_cast<std::uint8_t>(value >> shift));
  }
}

inline std::uint32_t Adler(const std::vector<std::uint8_t> &input) {
  return static_cast<std::uint32_t>(
      mz_adler32(MZ_ADLER32_INIT, input.data(), input.size()));
}

inline std::vector<std::uint8_t> Compress(
    const std::vector<std::uint8_t> &input) {
  const mz_ulong capacity = mz_compressBound(input.size());
  std::vector<std::uint8_t> output(capacity);
  mz_ulong length = capacity;
  if (mz_compress(output.data(), &length, input.data(), input.size()) !=
      MZ_OK) {
    throw std::runtime_error("cannot compress synthetic MDict fixture");
  }
  output.resize(length);
  return output;
}

inline std::vector<std::uint8_t> BuildSyntheticMDXWithEntries(
    const std::vector<std::pair<std::string, std::string>> &entries,
    std::size_t trailing_padding = 0) {
  if (entries.size() < 2) {
    throw std::runtime_error("synthetic MDict needs at least two entries");
  }
  for (std::size_t index = 0; index < entries.size(); ++index) {
    if (entries[index].first.empty() || entries[index].first.size() > UINT16_MAX ||
        (index > 0 && entries[index - 1].first >= entries[index].first)) {
      throw std::runtime_error("invalid synthetic MDict headwords");
    }
  }
  const std::string xml =
      "<Dictionary GeneratedByEngineVersion=\"2.0\" "
      "RequiredEngineVersion=\"2.0\" Encrypted=\"No\" "
      "Encoding=\"UTF-8\"/>";
  std::vector<std::uint8_t> header;
  for (unsigned char character : xml) {
    header.push_back(character);
    header.push_back(0);
  }

  std::vector<std::uint8_t> key_raw;
  std::uint64_t record_offset = 0;
  for (const auto &entry : entries) {
    AppendBE64(key_raw, record_offset);
    key_raw.insert(key_raw.end(), entry.first.begin(), entry.first.end());
    key_raw.push_back(0);
    record_offset += static_cast<std::uint64_t>(entry.second.size() + 1);
  }

  const auto key_payload = Compress(key_raw);
  std::vector<std::uint8_t> key_block{2, 0, 0, 0};
  AppendBE32(key_block, Adler(key_raw));
  key_block.insert(key_block.end(), key_payload.begin(), key_payload.end());

  std::vector<std::uint8_t> key_info;
  AppendBE64(key_info, entries.size());
  AppendBE16(key_info, static_cast<std::uint16_t>(entries.front().first.size()));
  key_info.insert(key_info.end(), entries.front().first.begin(), entries.front().first.end());
  key_info.push_back(0);
  AppendBE16(key_info, static_cast<std::uint16_t>(entries.back().first.size()));
  key_info.insert(key_info.end(), entries.back().first.begin(), entries.back().first.end());
  key_info.push_back(0);
  AppendBE64(key_info, key_block.size());
  AppendBE64(key_info, key_raw.size());
  const auto key_info_payload = Compress(key_info);
  std::vector<std::uint8_t> key_info_block{2, 0, 0, 0};
  AppendBE32(key_info_block, Adler(key_info));
  key_info_block.insert(key_info_block.end(), key_info_payload.begin(),
                        key_info_payload.end());

  std::vector<std::uint8_t> record;
  for (const auto &entry : entries) {
    record.insert(record.end(), entry.second.begin(), entry.second.end());
    record.push_back(0);
  }
  const auto record_payload = Compress(record);
  std::vector<std::uint8_t> record_block{2, 0, 0, 0};
  AppendBE32(record_block, Adler(record));
  record_block.insert(record_block.end(), record_payload.begin(),
                      record_payload.end());

  std::vector<std::uint8_t> key_header;
  AppendBE64(key_header, 1);
  AppendBE64(key_header, entries.size());
  AppendBE64(key_header, key_info.size());
  AppendBE64(key_header, key_info_block.size());
  AppendBE64(key_header, key_block.size());

  std::vector<std::uint8_t> output;
  AppendBE32(output, static_cast<std::uint32_t>(header.size()));
  output.insert(output.end(), header.begin(), header.end());
  AppendLE32(output, Adler(header));
  output.insert(output.end(), key_header.begin(), key_header.end());
  AppendBE32(output, Adler(key_header));
  output.insert(output.end(), key_info_block.begin(), key_info_block.end());
  output.insert(output.end(), key_block.begin(), key_block.end());
  AppendBE64(output, 1);
  AppendBE64(output, entries.size());
  AppendBE64(output, 16);
  AppendBE64(output, record_block.size());
  AppendBE64(output, record_block.size());
  AppendBE64(output, record.size());
  output.insert(output.end(), record_block.begin(), record_block.end());
  output.insert(output.end(), trailing_padding, 0);
  return output;
}

inline std::vector<std::uint8_t> BuildSyntheticMDXWithHeadwords(
    const std::string &first_headword, const std::string &second_headword,
    const std::string &first_record, const std::string &second_record,
    std::size_t trailing_padding = 0) {
  return BuildSyntheticMDXWithEntries({
      {first_headword, first_record}, {second_headword, second_record}},
      trailing_padding);
}

inline std::vector<std::uint8_t> BuildSyntheticMDX(
    const std::string &first_record, const std::string &second_record,
    std::size_t trailing_padding = 0) {
  return BuildSyntheticMDXWithHeadwords(
      "aaa", "zzz", first_record, second_record, trailing_padding);
}

}  // namespace localdict::testsupport
