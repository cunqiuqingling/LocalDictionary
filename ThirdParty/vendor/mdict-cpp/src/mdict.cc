/*
 * Copyright (c) 2025-Present
 * All rights reserved.
 *
 * This code is licensed under the BSD 3-Clause License.
 * See the LICENSE file for details.
 */

#include "include/mdict.h"

#include "RIPEMD128Adapter.h"

#include <encode/api.h>
#include <encode/base64.h>

#include <algorithm>
#ifdef MDICT_RESOURCE_TEST_OBSERVER
#include <atomic>
#endif
#include <cstring>
#include <filesystem>
#include <iostream>
#include <map>
#include <regex>
#include <stdexcept>
#include <utility>

#include "encode/char_decoder.h"
#include "encode/api.h"
#include "include/adler32.h"
#include "include/binutils.h"
#include "include/mdict_extern.h"
#include "include/xmlutils.h"
#include "include/zlib_wrapper.h"

const std::regex re_pattern("(\\s|:|\\.|,|-|_|'|\\(|\\)|#|<|>|!)");

namespace mdict {

namespace {

// MDict stores only the Header Adler-32 field in little-endian order. Header
// length and subsequent Key/Record checksum fields retain their own existing
// big-endian decoding paths.
uint32_t readLittleEndianUInt32(const uint8_t *bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

}  // namespace

#ifdef MDICT_RESOURCE_TEST_OBSERVER
namespace {
std::atomic<uint64_t> g_input_buffer_allocations{0};
std::atomic<uint64_t> g_key_block_info_input_buffer_allocations{0};
std::atomic<uint64_t> g_record_block_info_input_buffer_allocations{0};
std::atomic<uint64_t> g_output_buffer_allocations{0};
std::atomic<uint64_t> g_uncompress_calls{0};
std::atomic<uint64_t> g_key_items_live{0};
}  // namespace

void resetResourceTestObserver() noexcept {
  g_input_buffer_allocations.store(0, std::memory_order_relaxed);
  g_key_block_info_input_buffer_allocations.store(0,
                                                   std::memory_order_relaxed);
  g_record_block_info_input_buffer_allocations.store(
      0, std::memory_order_relaxed);
  g_output_buffer_allocations.store(0, std::memory_order_relaxed);
  g_uncompress_calls.store(0, std::memory_order_relaxed);
  g_key_items_live.store(0, std::memory_order_relaxed);
}

ResourceTestObserverSnapshot resourceTestObserverSnapshot() noexcept {
  return {g_input_buffer_allocations.load(std::memory_order_relaxed),
          g_key_block_info_input_buffer_allocations.load(
              std::memory_order_relaxed),
          g_record_block_info_input_buffer_allocations.load(
              std::memory_order_relaxed),
          g_output_buffer_allocations.load(std::memory_order_relaxed),
          g_uncompress_calls.load(std::memory_order_relaxed),
          g_key_items_live.load(std::memory_order_relaxed)};
}

void observeInputBufferAllocation() noexcept {
  g_input_buffer_allocations.fetch_add(1, std::memory_order_relaxed);
}
void observeKeyBlockInfoInputBufferAllocation() noexcept {
  g_key_block_info_input_buffer_allocations.fetch_add(
      1, std::memory_order_relaxed);
}
void observeRecordBlockInfoInputBufferAllocation() noexcept {
  g_record_block_info_input_buffer_allocations.fetch_add(
      1, std::memory_order_relaxed);
}
void observeOutputBufferAllocation() noexcept {
  g_output_buffer_allocations.fetch_add(1, std::memory_order_relaxed);
}
void observeUncompressCall() noexcept {
  g_uncompress_calls.fetch_add(1, std::memory_order_relaxed);
}
void observeKeyItemCreated() noexcept {
  g_key_items_live.fetch_add(1, std::memory_order_relaxed);
}
void observeKeyItemDestroyed() noexcept {
  g_key_items_live.fetch_sub(1, std::memory_order_relaxed);
}
#endif

namespace {
uint32_t validatedKeyBlockCompressionType(const uint8_t *prefix) {
  const uint32_t raw = static_cast<uint32_t>(prefix[0]) |
                       (static_cast<uint32_t>(prefix[1]) << 8) |
                       (static_cast<uint32_t>(prefix[2]) << 16) |
                       (static_cast<uint32_t>(prefix[3]) << 24);
  if (raw != 0 && raw != 1 && raw != 2) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  return raw;
}

uint32_t validatedRecordBlockCompressionType(const uint8_t *prefix) {
  const uint32_t raw = static_cast<uint32_t>(prefix[0]) |
                       (static_cast<uint32_t>(prefix[1]) << 8) |
                       (static_cast<uint32_t>(prefix[2]) << 16) |
                       (static_cast<uint32_t>(prefix[3]) << 24);
  if (raw != 0 && raw != 1 && raw != 2) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  return raw;
}
}  // namespace

// constructor (production defaults)
Mdict::Mdict(std::string fn) noexcept : filename(std::move(fn)) {
  if (endsWith(filename, ".mdd")) {
    this->filetype = MDDTYPE;
  } else {
    this->filetype = MDXTYPE;
  }
}

// constructor with explicit limits
Mdict::Mdict(std::string fn, ResourceLimits limits) noexcept
    : filename(std::move(fn)), limits_(limits) {
  if (endsWith(filename, ".mdd")) {
    this->filetype = MDDTYPE;
  } else {
    this->filetype = MDXTYPE;
  }
}

// constructor with additional files (production defaults)
Mdict::Mdict(std::string fn, std::string aff_fn, std::string dic_fn) noexcept
    : filename(std::move(fn)) {
  if (endsWith(filename, ".mdd")) {
    this->filetype = MDDTYPE;
  } else {
    this->filetype = MDXTYPE;
  }
  // aff_fn and dic_fn reserved for future use
  (void)aff_fn;
  (void)dic_fn;
}

// constructor with additional files and explicit limits
Mdict::Mdict(std::string fn, std::string aff_fn, std::string dic_fn,
             ResourceLimits limits) noexcept
    : filename(std::move(fn)), limits_(limits) {
  if (endsWith(filename, ".mdd")) {
    this->filetype = MDDTYPE;
  } else {
    this->filetype = MDXTYPE;
  }
  // aff_fn and dic_fn reserved for future use
  (void)aff_fn;
  (void)dic_fn;
}

// distructor
Mdict::~Mdict() {
  instream.close();
  for (auto *item : key_block_info_list) delete item;
  for (auto *item : key_list) delete item;
  for (auto *item : record_header) delete item;
  for (auto *item : key_data) delete item;
}

/**
 * transform word into comparable string
 * @param word
 * @return
 */
std::string _s(std::string word) {
  std::string s = std::regex_replace(word, re_pattern, "");
  std::transform(s.begin(), s.end(), s.begin(), ::tolower);
  return s;
}

/***************************************
 *             private part            *
 ***************************************/

/**
 * read header
 * D1b-3A-2A: validates header size against limits before allocation,
 * enforces checksum in both Debug and Release.
 */
void Mdict::read_header() {
  // -----------------------------------------
  // 1. [0:4] dictionary header length 4 byte
  // -----------------------------------------

  // header size buffer (RAII)
  std::vector<uint8_t> head_size_buf(4);
  readfile(0, 4, reinterpret_cast<char *>(head_size_buf.data()));

  // header byte size convert
  uint32_t header_bytes_size = be_bin_to_u32(head_size_buf.data());

  // D1b-3A-2A: validate header size before any large allocation.
  if (header_bytes_size == 0) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  if (header_bytes_size > limits_.maximumHeaderBytes) {
    throw ResourceException(ResourceErrorCode::headerTooLarge);
  }

  // Validate header + 4-byte size field + 4-byte checksum fits in file
  uint64_t headerEnd = checkedAddUInt64(static_cast<uint64_t>(header_bytes_size), 8ULL);
  if (headerEnd > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // assign key block start offset (now uint64_t)
  this->header_bytes_size = header_bytes_size;
  this->key_block_start_offset = checkedAddUInt64(header_bytes_size, 8ULL);
  /// passed

  // -----------------------------------------
  // 2. [4: header_bytes_size+4], header buffer
  // -----------------------------------------

  // header buffer — RAII via vector
  std::vector<uint8_t> head_buffer(checkedUInt64ToSizeT(header_bytes_size));
  readfile(4, header_bytes_size, reinterpret_cast<char *>(head_buffer.data()));
  /// passed

  // 3. adler32 checksum
  // -----------------------------------------

  // D1b-3A-2A: enforce header checksum in both Debug and Release.
  // MDX format: adler32 of the raw header bytes (UTF-16 XML) stored as
  // little-endian uint32 at offset header_bytes_size + 4.
  std::vector<uint8_t> head_checksum_buffer(4);
  readfile(header_bytes_size + 4, 4,
           reinterpret_cast<char *>(head_checksum_buffer.data()));

  uint32_t expected_checksum = readLittleEndianUInt32(head_checksum_buffer.data());
  uint32_t actual_checksum =
      adler32checksum(head_buffer.data(), header_bytes_size);
  if (actual_checksum != expected_checksum) {
    throw ResourceException(ResourceErrorCode::checksumMismatch);
  }

  // -----------------------------------------
  // 4. convert header buffer into utf16 text
  // -----------------------------------------

  // header text utf16

  std::string utf8_temp;
  if (!utf16_to_utf8_header(head_buffer.data(), header_bytes_size, utf8_temp)) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  unsigned char* utf8_buffer = reinterpret_cast<unsigned char*>(&utf8_temp[0]);
  int utf8_len = static_cast<int>(utf8_temp.size());

  this->header_buffer = std::move(utf8_temp);

  std::string header_text(reinterpret_cast<char*>(utf8_buffer), utf8_len);
  std::map<std::string, std::string> headinfo;
  parse_xml_header(header_text, headinfo);
  /// passed

  // -----------------------------------------
  // 6. handle header message, set flags
  // -----------------------------------------

  // encrypted flag
  // 0x00 - no encryption
  // 0x01 - encrypt record block
  // 0x02 - encrypt key info block
  if (headinfo.find("Encrypted") == headinfo.end() ||
      headinfo["Encrypted"].empty() || headinfo["Encrypted"] == "No") {
    this->encrypt = ENCRYPT_NO_ENC;
  } else if (headinfo["Encrypted"] == "Yes") {
    this->encrypt = ENCRYPT_RECORD_ENC;
  } else {
    std::string s = headinfo["Encrypted"];
    if (s.at(0) == '2') {
      this->encrypt = ENCRYPT_KEY_INFO_ENC;
    } else if (s.at(0) == '1') {
      this->encrypt = ENCRYPT_RECORD_ENC;
    } else {
      this->encrypt = ENCRYPT_NO_ENC;
    }
  }
  /// passed

  // -------- stylesheet ----------
  // stylesheet attribute if present takes from of:
  // style_number # 1-255
  // style_begin # or ''
  // style_end # or ''
  // TODO: splitstyle info

  // header_info['_stylesheet'] = {}
  // if header_tag.get('StyleSheet'):
  //   lines = header_tag['StyleSheet'].splitlines()
  //   for i in range(0, len(lines), 3):
  //        header_info['_stylesheet'][lines[i]] = (lines[i + 1], lines[i + 2])

  // ---------- version ------------
  // before version 2.0, number is 4 bytes integer
  // version 2.0 and above use 8 bytes
  std::string sver = headinfo["GeneratedByEngineVersion"];
  
  auto parse_version = [](const std::string& s, float fallback = 0.0f) -> float {
    float v = fallback;
    size_t i = 0;

    // skip leading whitespace
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
    if (i == s.size()) return fallback;

    // parse digits before decimal
    float int_part = 0;
    while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) {
        int_part = int_part * 10 + (s[i] - '0');
        ++i;
    }

    float frac_part = 0;
    if (i < s.size() && s[i] == '.') {
        ++i;
        float divisor = 10.0f;
        while (i < s.size() && std::isdigit(static_cast<unsigned char>(s[i]))) {
            frac_part += (s[i] - '0') / divisor;
            divisor *= 10.0f;
            ++i;
        }
    }

    v = int_part + frac_part;
    return v;
};

  // we fallback to less than 2.
  this->version = parse_version(sver, 0.0f); // default < 2.0
  

  if (this->version >= 2.0) {
    this->number_width = 8;
    this->number_format = NUMFMT_BE_8BYTESQ;
    this->key_block_info_start_offset = this->key_block_start_offset + 40 + 4;
  } else {
    this->number_format = NUMFMT_BE_4BYTESI;
    this->number_width = 4;
    this->key_block_info_start_offset = this->key_block_start_offset + 16;
  }

  // ---------- encoding ------------
  if (headinfo.find("Encoding") == headinfo.end() ||
      headinfo["Encoding"] == "" || headinfo["Encoding"] == "UTF-8") {
    this->encoding = ENCODING_UTF8;
  } else if (headinfo["Encoding"] == "GBK" ||
             headinfo["Encoding"] == "GB2312") {
    this->encoding = ENCODING_GB18030;
  } else if (headinfo["Encoding"] == "Big5" || headinfo["Encoding"] == "BIG5") {
    this->encoding = ENCODING_BIG5;
  } else if (headinfo["Encoding"] == "utf16" ||
             headinfo["Encoding"] == "utf-16" ||
             headinfo["Encoding"] == "UTF16" ||
             headinfo["Encoding"] == "UTF-16") {
    this->encoding = ENCODING_UTF16;
  } else {
    this->encoding = ENCODING_UTF8;
  }
  // FIX mdd
  if (this->filetype == "MDD") {
    this->encoding = ENCODING_UTF16;
  }
  /// passed
}

#ifdef MDICT_RESOURCE_TEST_OBSERVER
void Mdict::readHeaderForResourceTest() {
  limits_.validate();
  if (!std::filesystem::exists(filename)) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  instream = std::ifstream(filename, std::ios::binary);
  if (!instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  instream.seekg(0, std::ios::end);
  const std::streamoff end_pos = instream.tellg();
  if (end_pos < 0) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  actual_file_size_ = static_cast<uint64_t>(end_pos);
  instream.clear();
  instream.seekg(0, std::ios::beg);
  if (!instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  if (actual_file_size_ > limits_.maximumFileBytes) {
    throw ResourceException(ResourceErrorCode::fileTooLarge);
  }
  read_header();
}
#endif

/**
 * read key block header, key block header contains a serials number, including
 *
 * key block header info struct:
 * [0:8]/[0:4]   - number of key blocks
 * [8:16]/[4:8]  - number of entries
 * [16:24]/nil - key block info decompressed size (if version >= 2.0,
 * otherwise, this section does not exist)
 * [24:32]/[8:12] - key block info size
 * [32:40][12:16] - key block size
 * note: if version <2.0, the key info buffer size is 4 * 4
 *       otherwise, ths key info buffer size is 5 * 8
 * <2.0  the order of number is same
 */
void Mdict::read_key_block_header() {
  // key block header part
  uint64_t key_block_info_bytes_num = 0;
  if (this->version >= 2.0) {
    key_block_info_bytes_num = 8 * 5;  // 40
  } else {
    key_block_info_bytes_num = 4 * 4;  // 16
  }

  // Validate key_block_start_offset + header_bytes fits in file
  uint64_t headerEnd = checkedAddUInt64(this->key_block_start_offset, key_block_info_bytes_num);
  if (headerEnd > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // D1b-3A-2A-R1: RAII — key block header buffer
  std::vector<uint8_t> key_block_info_buffer(
      checkedUInt64ToSizeT(key_block_info_bytes_num));
  // read buffer
  this->readfile(this->key_block_start_offset, key_block_info_bytes_num,
                 reinterpret_cast<char *>(key_block_info_buffer.data()));
  /// PASSED

  // TODO key block info encrypted file not support yet
  if (this->encrypt == ENCRYPT_RECORD_ENC) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  // 1. [0:8]([0:4]) number of key blocks
  std::vector<uint8_t> key_block_nums_bytes(
      checkedUInt64ToSizeT(this->number_width));
  int eno = bin_slice(reinterpret_cast<char *>(key_block_info_buffer.data()),
                      static_cast<int>(key_block_info_bytes_num), 0,
                      this->number_width,
                      reinterpret_cast<char *>(key_block_nums_bytes.data()));
  if (eno != 0) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  /// passed

  uint64_t key_block_num = 0;
  if (this->number_width == 8)
    key_block_num = be_bin_to_u64(key_block_nums_bytes.data());
  else if (this->number_width == 4)
    key_block_num = be_bin_to_u32(key_block_nums_bytes.data());
  /// passed

  // D1b-3A-2A: validate key_block_num against limits
  if (key_block_num == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_num > limits_.maximumKeyBlockCount)
    throw ResourceException(ResourceErrorCode::keyBlockCountTooLarge);

  // 2. [8:16]  - number of entries
  std::vector<uint8_t> entries_num_bytes(
      checkedUInt64ToSizeT(this->number_width));
  eno = bin_slice(reinterpret_cast<char *>(key_block_info_buffer.data()),
                  static_cast<int>(key_block_info_bytes_num),
                  this->number_width, this->number_width,
                  reinterpret_cast<char *>(entries_num_bytes.data()));
  if (eno != 0) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  /// passed

  uint64_t entries_num = 0;
  if (this->number_width == 8)
    entries_num = be_bin_to_u64(entries_num_bytes.data());
  else if (this->number_width == 4)
    entries_num = be_bin_to_u32(entries_num_bytes.data());  // D1b-3A-2A: fixed — was assigning to key_block_num
  /// passed

  // D1b-3A-2A: validate entries_num against limits
  if (entries_num == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (entries_num > limits_.maximumEntryCount)
    throw ResourceException(ResourceErrorCode::entryCountTooLarge);

  int key_block_info_size_start_offset = 0;

  // 3. [16:24] - key block info decompressed size (if version >= 2.0,
  // otherwise, this section does not exist)
  if (this->version >= 2.0) {
    std::vector<uint8_t> key_block_info_decompress_size_bytes(
        checkedUInt64ToSizeT(this->number_width));
    eno = bin_slice(reinterpret_cast<char *>(key_block_info_buffer.data()),
                    static_cast<int>(key_block_info_bytes_num),
                    this->number_width * 2, this->number_width,
                    reinterpret_cast<char *>(key_block_info_decompress_size_bytes.data()));
    if (eno != 0) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    /// passed

    uint64_t key_block_info_decompress_size = 0;
    if (this->number_width == 8)
      key_block_info_decompress_size = be_bin_to_u64(
          key_block_info_decompress_size_bytes.data());
    else if (this->number_width == 4)
      key_block_info_decompress_size = be_bin_to_u32(
          key_block_info_decompress_size_bytes.data());

    // D1b-3A-2A: validate decompressed size
    if (key_block_info_decompress_size == 0)
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    if (key_block_info_decompress_size > limits_.maximumKeyBlockInfoDecompressedBytes)
      throw ResourceException(ResourceErrorCode::keyBlockInfoDecompressedTooLarge);

    this->key_block_info_decompress_size = key_block_info_decompress_size;
    /// passed

    // key block info size (number) start at 24 ([24:32])
    key_block_info_size_start_offset = this->number_width * 3;
  } else {
    // for version < 2.0, decompressed size is implicit (same as compressed)
    this->key_block_info_decompress_size = 0;
    // key block info size (number) start at 8 ([8:12])
    key_block_info_size_start_offset = this->number_width * 2;
  }

  // 4. [24:32] - key block info size
  std::vector<uint8_t> key_block_info_size_buffer(
      checkedUInt64ToSizeT(this->number_width));
  eno = bin_slice(reinterpret_cast<char *>(key_block_info_buffer.data()),
                  static_cast<int>(key_block_info_bytes_num),
                  key_block_info_size_start_offset, this->number_width,
                  reinterpret_cast<char *>(key_block_info_size_buffer.data()));
  if (eno != 0) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }

  uint64_t key_block_info_size = 0;
  if (this->number_width == 8)
    key_block_info_size =
        be_bin_to_u64(key_block_info_size_buffer.data());
  else if (this->number_width == 4)
    key_block_info_size =
        be_bin_to_u32(key_block_info_size_buffer.data());
  /// passed

  // D1b-3A-2A: validate info size
  if (key_block_info_size == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_info_size > limits_.maximumKeyBlockInfoCompressedBytes)
    throw ResourceException(ResourceErrorCode::keyBlockInfoCompressedTooLarge);

  // 5. [32:40] - key block size
  std::vector<uint8_t> key_block_size_buffer(
      checkedUInt64ToSizeT(this->number_width));
  eno = bin_slice(reinterpret_cast<char *>(key_block_info_buffer.data()),
                  static_cast<int>(key_block_info_bytes_num),
                  key_block_info_size_start_offset + this->number_width,
                  this->number_width,
                  reinterpret_cast<char *>(key_block_size_buffer.data()));
  if (eno != 0) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  /// passed

  uint64_t key_block_size = 0;
  if (this->number_width == 8)
    key_block_size =
        be_bin_to_u64(key_block_size_buffer.data());
  else if (this->number_width == 4)
    key_block_size =
        be_bin_to_u32(key_block_size_buffer.data());
  /// passed

  // D1b-3A-2A: validate total key block size
  if (key_block_size == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_size > limits_.maximumTotalKeyBlockCompressedBytes)
    throw ResourceException(ResourceErrorCode::totalKeyBlockCompressedTooLarge);

  // 6. [40:44] - 4bytes checksum (version >= 2.0 only)
  // skip checksum verification for key block header — not in scope

  this->key_block_num = key_block_num;
  this->entries_num = entries_num;
  this->key_block_info_size = key_block_info_size;
  this->key_block_size = key_block_size;
  if (this->version >= 2.0) {
    this->key_block_info_start_offset = checkedAddUInt64(this->key_block_start_offset, 44ULL);
  } else {
    this->key_block_info_start_offset = checkedAddUInt64(this->key_block_start_offset, 16ULL);
  }

  // D1b-3A-2A: validate that info_end is within actual file
  uint64_t infoEnd = checkedAddUInt64(this->key_block_info_start_offset, this->key_block_info_size);
  if (infoEnd > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
}

/**
 * read key block info
 *
 * it will decode the key block info, and set the key block info list
 * it contains:
 * first key
 * last key
 * comp size
 * decomp size
 * offset
 */
void Mdict::read_key_block_info() {
  read_key_block_info_metadata();

  // D1b-3A-2A-R1: pre-allocation EOF check
  uint64_t kbCompressedEnd = checkedAddUInt64(
      this->key_block_compressed_start_offset, this->key_block_size);
  if (kbCompressedEnd > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // RAII: full key-block compressed buffer
#ifdef MDICT_RESOURCE_TEST_OBSERVER
  observeInputBufferAllocation();
#endif
  std::vector<uint8_t> key_block_compressed_buffer(
      checkedUInt64ToSizeT(this->key_block_size));
  readfile(this->key_block_compressed_start_offset,
           this->key_block_size,
           reinterpret_cast<char *>(key_block_compressed_buffer.data()));

  uint64_t kb_len = this->key_block_size;
  int err =
      decode_key_block(key_block_compressed_buffer.data(), kb_len);
  if (err != 0) {
    throw ResourceException(ResourceErrorCode::checksumMismatch);
  }
}

void Mdict::read_key_block_info_metadata() {
  // D1b-3A-2A: validate key_block_info_size before allocation.
  if (this->key_block_info_size > limits_.maximumKeyBlockInfoCompressedBytes) {
    throw ResourceException(ResourceErrorCode::keyBlockInfoCompressedTooLarge);
  }

  // D1b-3A-2A-R1: pre-allocation EOF check
  uint64_t kbiEnd = checkedAddUInt64(
      this->key_block_info_start_offset, this->key_block_info_size);
  if (kbiEnd > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // RAII: key-block-info buffer
#ifdef MDICT_RESOURCE_TEST_OBSERVER
  observeKeyBlockInfoInputBufferAllocation();
#endif
  std::vector<uint8_t> key_block_info_buffer(
      checkedUInt64ToSizeT(this->key_block_info_size));
  readfile(this->key_block_info_start_offset, this->key_block_info_size,
           reinterpret_cast<char *>(key_block_info_buffer.data()));

  // ------------------------------------
  // decode key_block_info
  // ------------------------------------
  decode_key_block_info(reinterpret_cast<char *>(key_block_info_buffer.data()),
                        this->key_block_info_size,
                        this->key_block_num, this->entries_num);

  // D1b-3A-2A: fix I7 — keep as uint64_t (no uint32_t truncation).
  // key block compressed start offset = this->key_block_info_start_offset +
  // key_block_info_size
  this->key_block_compressed_start_offset =
      checkedAddUInt64(this->key_block_info_start_offset, this->key_block_info_size);
  this->record_block_info_offset =
      checkedAddUInt64(this->key_block_compressed_start_offset, this->key_block_size);
}

/**
 * use ripemd128 as decrypt key, and decrypt the key info data
 * @param data the data which needs to decrypt
 * @param k the decrypt key
 * @param data_len data length
 * @param key_len key length
 */
void fast_decrypt(byte *data, const byte *k, int data_len, int key_len) {
  const byte *key = k;
  //      putbytes((char*)data, 16, true);
  byte *b = data;
  byte previous = 0x36;

  for (int i = 0; i < data_len; ++i) {
    byte t = static_cast<byte>(((b[i] >> 4) | (b[i] << 4)) & 0xff);
    t = t ^ previous ^ ((byte)(i & 0xff)) ^ key[i % key_len];
    previous = b[i];
    b[i] = t;
  }
}

/**
 *
 * decrypt the data, this is a helper function to invoke the fast_decrypt
 * note: don't forget free comp_block !!
 *
 * @param comp_block compressed block buffer
 * @param comp_block_len compressed block buffer size
 * @return the decrypted compressed block
 */
byte *mdx_decrypt(byte *comp_block, const int comp_block_len) {
  byte *key_buffer = (byte *)calloc(8, sizeof(byte));
  if (!key_buffer)
    throw ResourceException(ResourceErrorCode::allocationFailed);
  memcpy(key_buffer, comp_block + 4 * sizeof(char), 4 * sizeof(char));
  key_buffer[4] = 0x95; // comp_block[4:8] + [0x95,0x36,0x00,0x00]
  key_buffer[5] = 0x36;

  byte key[LD_RIPEMD128_DIGEST_LENGTH];
  if (ld_ripemd128_digest(key_buffer, 8, key) != LD_RIPEMD128_OK) {
    std::free(key_buffer);
    throw ResourceException(ResourceErrorCode::checksumMismatch);
  }

  fast_decrypt(comp_block + 8 * sizeof(byte), key, comp_block_len - 8,
               LD_RIPEMD128_DIGEST_LENGTH);

  // finally
  std::free(key_buffer);
  return comp_block;
  /// passed
}

/**
 * split key block into key block list
 *
 * this is for key block (not key block info)
 *
 * D1b-3A-2A-R1: complete boundary validation rewrite.
 *   - Non-null / non-empty input enforced.
 *   - key_end_idx reset to SIZE_MAX each iteration (no stale value).
 *   - Missing delimiter throws malformedKeyBlockMetadata.
 *   - UTF-16 checks i+1 boundary; rejects trailing single byte.
 *   - Key length checked against maximumSingleKeyBytes before any allocation.
 *   - key_start_idx must strictly advance (infinite loop prevention).
 *   - All subtractions use checked arithmetic or equivalent pre-comparison.
 *   - UTF temporary buffers use std::vector<uint8_t> (RAII).
 *   - Malformed input rejected before creating key_list_item.
 *
 * @param key_block key block buffer (must be non-null)
 * @param key_block_len key block length in bytes (must be > 0)
 * @param block_id block index (unused; retained for signature compatibility)
 */
std::vector<std::unique_ptr<key_list_item>> Mdict::split_key_block_owned(
    unsigned char *key_block, uint64_t key_block_len, size_t block_id,
    uint64_t declared_entry_count, uint64_t remaining_global_entries) {
  (void)block_id;

  // --- validate input ---
  if (key_block == nullptr)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_len == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);

  size_t buf_len = checkedUInt64ToSizeT(key_block_len);
  std::vector<std::unique_ptr<key_list_item>> inner_key_list;
  inner_key_list.reserve(checkedUInt64ToSizeT(
      std::min(declared_entry_count, remaining_global_entries)));
  uint64_t parsed_entry_count = 0;

  size_t key_start_idx = 0;
  size_t num_width = static_cast<size_t>(this->number_width);
  size_t width = (this->encoding == 1 /* utf16 */) ? 2 : 1;

  while (key_start_idx < buf_len) {
    // --- read record_start ---
    // Validate remaining bytes >= number_width before reading
    if (key_start_idx + num_width > buf_len) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    uint64_t raw_record_start = 0;
    if (this->version >= 2.0) {
      raw_record_start = be_bin_to_u64(key_block + key_start_idx);
    } else {
      raw_record_start = be_bin_to_u32(key_block + key_start_idx);
    }

    // Checked conversion: uint64_t → unsigned long (for key_list_item)
    // TODO: migrate key_list_item::record_start to uint64_t in a future phase
    if (raw_record_start > static_cast<uint64_t>(std::numeric_limits<unsigned long>::max())) {
      throw ResourceException(ResourceErrorCode::numericConversionOverflow);
    }
    unsigned long record_start = static_cast<unsigned long>(raw_record_start);

    // --- find key delimiter ---
    size_t key_end_idx = SIZE_MAX;  // sentinel: not found

    size_t i = key_start_idx + num_width;
    // delimiter search must start within buffer
    if (i >= buf_len) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    while (i < buf_len) {
      if (this->encoding == 1 /* ENCODING_UTF16 */) {
        // Must have at least 2 bytes remaining for a UTF-16 unit
        if (i + 1 >= buf_len) {
          throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
        }
        // Check for 0x0000 delimiter (both bytes zero)
        if (key_block[i] == 0 && key_block[i + 1] == 0) {
          key_end_idx = i;
          break;
        }
        i += 2;
      } else {
        // UTF-8: delimiter is single null byte
        if (key_block[i] == 0) {
          key_end_idx = i;
          break;
        }
        i += 1;
      }
    }

    // --- delimiter not found ---
    if (key_end_idx == SIZE_MAX) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    // --- validate key boundaries ---
    // key_end_idx must be >= key_start_idx + number_width
    if (key_end_idx < key_start_idx + num_width) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    // key length in bytes (including the delimiter space, but we measure the text)
    uint64_t key_bytes = static_cast<uint64_t>(key_end_idx - key_start_idx - num_width);

    // --- maximumSingleKeyBytes check (before any allocation) ---
    if (key_bytes > limits_.maximumSingleKeyBytes) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    // --- decode key text ---
    std::string key_text;
    if (this->encoding == 1 /* ENCODING_UTF16 */) {
      // be_bin_to_utf16 returns hex string representation
      // Use size_t for key_bytes (already validated as <= maximumSingleKeyBytes)
      size_t key_len_st = checkedUInt64ToSizeT(key_bytes);
      std::string hex_input = be_bin_to_utf16(
          reinterpret_cast<const char *>(key_block),
          static_cast<unsigned long>(key_start_idx + num_width),
          static_cast<unsigned long>(key_len_st));

      // hex_to_bytes: each byte becomes 2 hex chars
      size_t hex_len = hex_input.length();
      size_t utf16le_buf_size = (hex_len / 2) + 1;

      std::vector<uint8_t> utf16le_bytes(utf16le_buf_size);
      ssize_t utf16_bytes_written =
          hex_to_bytes(hex_input.c_str(), utf16le_bytes.data(), utf16le_buf_size);
      if (utf16_bytes_written < 0) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }

      // Allocate UTF-8 buffer: each UTF-16 code unit can expand to at most 3 UTF-8 bytes
      size_t utf16_written_st = static_cast<size_t>(utf16_bytes_written);
      size_t utf8_buf_size = checkedMultiplyUInt64(
          static_cast<uint64_t>(utf16_written_st), 3ULL);
      utf8_buf_size = checkedAddUInt64(utf8_buf_size, 1ULL);

      std::vector<uint8_t> utf8_output(checkedUInt64ToSizeT(utf8_buf_size));
      ssize_t utf8_bytes_written =
          utf16le_to_utf8(utf16le_bytes.data(), utf16_written_st,
                          utf8_output.data(), utf8_buf_size);

      if (utf8_bytes_written < 0) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }

      key_text = std::string(reinterpret_cast<char *>(utf8_output.data()),
                             static_cast<size_t>(utf8_bytes_written));
    } else if (this->encoding == 0 /* ENCODING_UTF8 */) {
      size_t key_len_st = checkedUInt64ToSizeT(key_bytes);
      key_text = be_bin_to_utf8(
          reinterpret_cast<const char *>(key_block),
          static_cast<unsigned long>(key_start_idx + num_width),
          static_cast<unsigned long>(key_len_st));
    }

    // Count actual parsed entries before allocation.  The global resource cap
    // has priority over metadata mismatch so a malicious block cannot hide an
    // over-limit actual count behind an inaccurate declaration.
    uint64_t next_entry_count = checkedAddUInt64(parsed_entry_count, 1ULL);
    if (next_entry_count > remaining_global_entries) {
      throw ResourceException(ResourceErrorCode::entryCountTooLarge);
    }
    if (next_entry_count > declared_entry_count) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    // Ownership remains local until the whole block is validated.
    inner_key_list.push_back(
        std::make_unique<key_list_item>(record_start, key_text));
    parsed_entry_count = next_entry_count;

    // --- advance key_start_idx: must be strictly greater (infinite loop guard) ---
    size_t next_idx = key_end_idx + width;
    if (next_idx <= key_start_idx) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    key_start_idx = next_idx;
  }
  if (parsed_entry_count != declared_entry_count) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  return inner_key_list;
}

/**
 * decode key block info by block id use with reduce function
 * D1b-3A-2A-R1: type-0 UAF fixed — decompressed data always owned by vector.
 * Pre-allocation EOF check, RAII for all buffers, exact payload/checksum
 * validation for type-0.
 * @param block_id key_block id
 * @return return key list item
 */
std::vector<key_list_item *>
Mdict::decode_key_block_by_block_id(unsigned long block_id) {
  // ------------------------------------
  // decode key_block_compressed
  // ------------------------------------

  size_t idx = static_cast<size_t>(block_id);

  if (idx >= this->key_block_info_list.size()) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }

  uint64_t comp_size = this->key_block_info_list[idx]->key_block_comp_size;
  uint64_t decomp_size =
      this->key_block_info_list[idx]->key_block_decomp_size;
  uint64_t start_ofset =
      checkedAddUInt64(this->key_block_info_list[idx]->key_block_comp_accumulator,
                       this->key_block_compressed_start_offset);

  if (comp_size > limits_.maximumSingleKeyBlockCompressedBytes) {
    throw ResourceException(ResourceErrorCode::singleKeyBlockCompressedTooLarge);
  }
  if (decomp_size > limits_.maximumSingleKeyBlockDecompressedBytes) {
    throw ResourceException(ResourceErrorCode::singleKeyBlockDecompressedTooLarge);
  }
  if (decomp_size == 0) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }

  // A block must contain an 8-byte prefix and a non-empty payload.
  if (comp_size <= 8) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  uint64_t payloadLen = checkedSubtractUInt64(comp_size, 8ULL);

  // D1b-3A-2A-R1: pre-allocation EOF check
  uint64_t blockFileEnd = checkedAddUInt64(start_ofset, comp_size);
  if (blockFileEnd > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // RAII: input buffer
#ifdef MDICT_RESOURCE_TEST_OBSERVER
  observeInputBufferAllocation();
#endif
  std::vector<uint8_t> key_block_buffer(checkedUInt64ToSizeT(comp_size));
  readfile(start_ofset, comp_size, reinterpret_cast<char *>(key_block_buffer.data()));

  // Read 4 bytes comp type and 4 bytes Adler-32 from prefix
  uint32_t comp_type_raw =
      validatedKeyBlockCompressionType(key_block_buffer.data());
  uint32_t chksum = be_bin_to_u32(key_block_buffer.data() + 4);

  // RAII: decompressed data always owned by vector (never a pointer into input)
  std::vector<uint8_t> kb_uncompressed;

  if (comp_type_raw == 0) {
    // --- type 0: uncompressed ---
    // decomp_size must exactly equal payloadLen
    if (decomp_size != payloadLen) {
      throw ResourceException(ResourceErrorCode::decompressedSizeMismatch);
    }

    // Validate Adler-32 of the payload (bytes after 8-byte prefix)
    uint32_t actual_cs = adler32checksum(
        key_block_buffer.data() + 8,
        static_cast<uint32_t>(payloadLen));
    if (actual_cs != chksum) {
      throw ResourceException(ResourceErrorCode::checksumMismatch);
    }

    // Copy payload into owned vector
    kb_uncompressed.assign(key_block_buffer.begin() + 8, key_block_buffer.end());

  } else if (comp_type_raw == 1) {
    // TODO lzo decompress
    throw ResourceException(ResourceErrorCode::invalidCompressionType);

  } else if (comp_type_raw == 2) {
    // zlib compress
    // D1b-3A-2A: use bounded exact zlib decompression with payload length.
    kb_uncompressed =
        boundedExactZlibDecompress(key_block_buffer.data() + 8,
                                   checkedUInt64ToSizeT(payloadLen),
                                   checkedUInt64ToSizeT(decomp_size));

    uint32_t adler32cs =
        adler32checksum(kb_uncompressed.data(),
                        static_cast<uint32_t>(decomp_size));
    // D1b-3A-2A: runtime checksum validation (was assert).
    if (adler32cs != chksum) {
      throw ResourceException(ResourceErrorCode::checksumMismatch);
    }
  } else {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  auto owned = split_key_block_owned(
      kb_uncompressed.data(), decomp_size, idx,
      this->key_block_info_list[idx]->declared_entry_count,
      limits_.maximumEntryCount);
  std::vector<key_list_item *> result;
  result.reserve(owned.size());
  for (const auto &item : owned) result.push_back(item.get());
  for (auto &item : owned) item.release();
  return result;
}

/**
 * decode the key block decode function, will invoke split key block
 *
 * this is for key block (not key block info)
 * D1b-3A-2A-R1: type-0 exact payload/decomp/Adler-32 validation,
 * RAII for all buffers, decompressed output always owned by vector.
 *
 * @param key_block_buffer
 * @param kb_buff_len
 * @return
 */
int Mdict::decode_key_block(unsigned char *key_block_buffer,
                            unsigned long kb_buff_len) {
  size_t i = 0;
  uint64_t parsed_entry_count = 0;
  std::vector<std::unique_ptr<key_list_item>> parsed_items;
  parsed_items.reserve(checkedUInt64ToSizeT(this->entries_num));

  for (size_t idx = 0; idx < this->key_block_info_list.size(); idx++) {
    uint64_t comp_size =
        this->key_block_info_list[idx]->key_block_comp_size;
    uint64_t decomp_size =
        this->key_block_info_list[idx]->key_block_decomp_size;
    size_t start_ofset = i;

    if (comp_size <= 8) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    if (decomp_size == 0) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    // D1b-3A-2A: per-block limits.
    if (comp_size > limits_.maximumSingleKeyBlockCompressedBytes) {
      throw ResourceException(ResourceErrorCode::singleKeyBlockCompressedTooLarge);
    }
    if (decomp_size > limits_.maximumSingleKeyBlockDecompressedBytes) {
      throw ResourceException(ResourceErrorCode::singleKeyBlockDecompressedTooLarge);
    }

    uint64_t payloadLen = checkedSubtractUInt64(comp_size, 8ULL);
    size_t payloadLenSt = checkedUInt64ToSizeT(payloadLen);

    // Validate start_ofset + comp_size within buffer
    uint64_t blockEnd = checkedAddUInt64(static_cast<uint64_t>(start_ofset), comp_size);
    if (blockEnd > static_cast<uint64_t>(kb_buff_len)) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    const uint32_t comp_type_raw = validatedKeyBlockCompressionType(
        key_block_buffer + start_ofset);
    // 4 bytes adler checksum of decompressed key block
    uint32_t chksum =
        be_bin_to_u32(key_block_buffer + start_ofset + 4);

    // RAII: decompressed data always held by vector, never a raw pointer
    // into the caller's buffer.
    std::vector<uint8_t> kb_uncompressed;

    if (comp_type_raw == 0) {
      // --- type 0: uncompressed ---
      // payloadLen must be > 0 (guaranteed by comp_size >= 8 and subtraction)
      // decomp_size must exactly equal payloadLen
      if (decomp_size != payloadLen) {
        throw ResourceException(ResourceErrorCode::decompressedSizeMismatch);
      }

      // Validate Adler-32 of payload BEFORE constructing key list
      uint32_t actual_cs = adler32checksum(
          key_block_buffer + start_ofset + 8,
          static_cast<uint32_t>(payloadLen));
      if (actual_cs != chksum) {
        throw ResourceException(ResourceErrorCode::checksumMismatch);
      }

      // Copy payload into owned vector — no dangling pointer into caller buffer.
      kb_uncompressed.assign(
          key_block_buffer + start_ofset + 8,
          key_block_buffer + start_ofset + 8 + payloadLenSt);

    } else if (comp_type_raw == 1) {
      // TODO lzo decompress
      throw ResourceException(ResourceErrorCode::invalidCompressionType);

    } else if (comp_type_raw == 2) {
      // zlib compress
      // D1b-3A-2A: use bounded exact zlib decompression with payload length.
      kb_uncompressed =
          boundedExactZlibDecompress(key_block_buffer + start_ofset + 8,
                                     payloadLenSt,
                                     checkedUInt64ToSizeT(decomp_size));

      uint32_t adler32cs =
          adler32checksum(kb_uncompressed.data(),
                          static_cast<uint32_t>(decomp_size));
      // D1b-3A-2A: runtime checksum validation (was assert).
      if (adler32cs != chksum) {
        throw ResourceException(ResourceErrorCode::checksumMismatch);
      }
    } else {
      throw ResourceException(ResourceErrorCode::invalidCompressionType);
    }

    const uint64_t remaining = checkedSubtractUInt64(
        limits_.maximumEntryCount, parsed_entry_count);
    auto block_items = split_key_block_owned(
        kb_uncompressed.data(), decomp_size, idx,
        this->key_block_info_list[idx]->declared_entry_count, remaining);
    parsed_entry_count = checkedAddUInt64(
        parsed_entry_count, static_cast<uint64_t>(block_items.size()));
    if (parsed_entry_count > limits_.maximumEntryCount) {
      throw ResourceException(ResourceErrorCode::entryCountTooLarge);
    }
    if (parsed_entry_count > this->entries_num) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    for (auto &item : block_items) parsed_items.push_back(std::move(item));

    // next round — checked cumulative addition
    i = checkedUInt64ToSizeT(blockEnd);
    if (i > static_cast<size_t>(kb_buff_len)) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
  }

  // D1b-3A-2A: runtime validation (was assert).
  if (parsed_entry_count != this->entries_num) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }

  std::vector<key_list_item *> committed;
  committed.reserve(parsed_items.size());
  for (const auto &item : parsed_items) committed.push_back(item.get());
  for (auto &item : parsed_items) item.release();
  for (auto *item : key_list) delete item;
  key_list.swap(committed);
  /// passed

  this->record_block_info_offset = checkedAddUInt64(
      this->key_block_info_start_offset,
      checkedAddUInt64(this->key_block_info_size, this->key_block_size));
  /// passed

  return 0;
}

// note: kb_info_buff_len == key_block_info_compressed_size

/**
 * decode the record block
 * @param record_block_buffer
 * @param rb_len record block buffer length
 * @return
 */
int Mdict::read_record_block_header() {
  /**
   * record block info section
   * decode the record block info section
   * [0:8/4]    - record blcok number
   * [8:16/4:8] - num entries the key-value entries number
   * [16:24/8:12] - record block info size
   * [24:32/12:16] - record block size
   */
  const uint64_t summary_size = checkedMultiplyUInt64(
      4ULL, static_cast<uint64_t>(this->number_width));
  const uint64_t summary_end = checkedAddUInt64(record_block_info_offset,
                                                 summary_size);
  if (summary_end > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  std::vector<uint8_t> summary;
  try {
    summary.resize(checkedUInt64ToSizeT(summary_size));
  } catch (const std::bad_alloc &) {
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  readfile(record_block_info_offset, summary_size,
           reinterpret_cast<char *>(summary.data()));

  const auto read_number = [this](const uint8_t *bytes) -> uint64_t {
    return this->number_width == 8 ? be_bin_to_u64(bytes) : be_bin_to_u32(bytes);
  };
  const uint64_t parsed_block_count = read_number(summary.data());
  const uint64_t parsed_entry_count =
      read_number(summary.data() + static_cast<size_t>(number_width));
  const uint64_t parsed_info_size = read_number(
      summary.data() + static_cast<size_t>(2 * number_width));
  const uint64_t parsed_total_compressed = read_number(
      summary.data() + static_cast<size_t>(3 * number_width));

  if (parsed_block_count == 0 || parsed_entry_count != entries_num) {
    throw ResourceException(ResourceErrorCode::malformedRecordBlockMetadata);
  }
  if (parsed_block_count > limits_.maximumRecordBlockCount) {
    throw ResourceException(ResourceErrorCode::recordBlockCountTooLarge);
  }
  if (parsed_info_size > limits_.maximumRecordBlockInfoBytes) {
    throw ResourceException(ResourceErrorCode::recordBlockInfoTooLarge);
  }
  if (parsed_total_compressed > limits_.maximumTotalRecordBlockCompressedBytes) {
    throw ResourceException(ResourceErrorCode::totalRecordBlockCompressedTooLarge);
  }

  const uint64_t expected_shape = checkedMultiplyUInt64(
      checkedMultiplyUInt64(parsed_block_count, 2ULL),
      static_cast<uint64_t>(number_width));
  if (parsed_info_size != expected_shape) {
    throw ResourceException(ResourceErrorCode::malformedRecordBlockMetadata);
  }
  const uint64_t info_end = checkedAddUInt64(summary_end, parsed_info_size);
  if (info_end > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  std::vector<uint8_t> table;
  try {
#ifdef MDICT_RESOURCE_TEST_OBSERVER
    observeRecordBlockInfoInputBufferAllocation();
#endif
    table.resize(checkedUInt64ToSizeT(parsed_info_size));
  } catch (const std::bad_alloc &) {
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  readfile(summary_end, parsed_info_size, reinterpret_cast<char *>(table.data()));

  std::vector<std::unique_ptr<record_header_item>> parsed;
  try {
    parsed.reserve(checkedUInt64ToSizeT(parsed_block_count));
  } catch (const std::bad_alloc &) {
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  uint64_t comp_accumulator = 0;
  uint64_t decomp_accumulator = 0;
  uint64_t offset = 0;
  for (uint64_t block_id = 0; block_id < parsed_block_count; ++block_id) {
    const uint64_t compressed = read_number(table.data() + checkedUInt64ToSizeT(offset));
    offset = checkedAddUInt64(offset, static_cast<uint64_t>(number_width));
    const uint64_t decompressed = read_number(table.data() + checkedUInt64ToSizeT(offset));
    offset = checkedAddUInt64(offset, static_cast<uint64_t>(number_width));
    if (compressed < 8 || decompressed == 0) {
      throw ResourceException(ResourceErrorCode::malformedRecordBlockMetadata);
    }
    if (compressed > limits_.maximumSingleRecordBlockCompressedBytes) {
      throw ResourceException(ResourceErrorCode::singleRecordBlockCompressedTooLarge);
    }
    if (decompressed > limits_.maximumSingleRecordBlockDecompressedBytes) {
      throw ResourceException(ResourceErrorCode::singleRecordBlockDecompressedTooLarge);
    }
    const uint64_t next_comp = checkedAddUInt64(comp_accumulator, compressed);
    const uint64_t next_decomp = checkedAddUInt64(decomp_accumulator, decompressed);
    if (next_comp > limits_.maximumTotalRecordBlockCompressedBytes) {
      throw ResourceException(ResourceErrorCode::totalRecordBlockCompressedTooLarge);
    }
    if (next_decomp > limits_.maximumTotalRecordBlockDecompressedBytes) {
      throw ResourceException(ResourceErrorCode::totalRecordBlockDecompressedTooLarge);
    }
    parsed.push_back(std::make_unique<record_header_item>(
        block_id, compressed, decompressed, comp_accumulator, decomp_accumulator));
    comp_accumulator = next_comp;
    decomp_accumulator = next_decomp;
  }
  if (offset != parsed_info_size || comp_accumulator != parsed_total_compressed) {
    throw ResourceException(ResourceErrorCode::malformedRecordBlockMetadata);
  }

  std::vector<record_header_item *> committed;
  committed.reserve(parsed.size());
  for (const auto &item : parsed) committed.push_back(item.get());
  for (auto *item : record_header) delete item;
  record_header.swap(committed);
  for (auto &item : parsed) item.release();
  record_block_info_size = summary_size;
  record_block_number = parsed_block_count;
  record_block_entries_number = parsed_entry_count;
  record_block_header_size = parsed_info_size;
  record_block_size = parsed_total_compressed;
  record_block_offset = info_end;
  return 0;
}

std::vector<std::pair<std::string, std::string>>
Mdict::decode_record_block_by_rid(unsigned long rid /* record id */) {
  // key list index counter
  unsigned long i = 0l;

  const uint64_t idx = rid;
  if (idx >= record_header.size()) {
    throw ResourceException(ResourceErrorCode::offsetOutOfBounds);
  }

  //  for (int idx = 0; idx < this->record_header.size(); idx++) {
  uint64_t uncomp_size = record_header[idx]->decompressed_size;
  uint64_t decomp_accu = record_header[idx]->decompressed_size_accumulator;
  uint64_t previous_end = 0;
  uint64_t previous_uncomp_size = 0;
  if (idx > 0) {
    previous_end = record_header[idx - 1]->decompressed_size_accumulator;
    previous_uncomp_size = record_header[idx - 1]->decompressed_size;
  }

  const std::vector<uint8_t> record_block_uncompressed_v =
      readRecordBlockBytes(idx);
  unsigned char *record_block =
      const_cast<unsigned char *>(record_block_uncompressed_v.data());
  /**
   * 请注意，block 是会有很多个的，而每个block都可能会被压缩
   * 而 key_list中的 record_start,
   * key_text是相对每一个block而言的，end是需要每次解析的时候算出来的
   * 所有的record_start/length/end都是针对解压后的block而言的
   */

  std::vector<std::pair<std::string, std::string>> vec;

  while (i < this->key_list.size()) {
    // TODO OPTIMISE
    unsigned long record_start = key_list[i]->record_start;

    std::string key_text = key_list[i]->key_word;
    // start, skip the keys which not includes in record block
    if (record_start < decomp_accu) {
      i++;
      continue;
    }

    // end important: the condition should be lgt, because, the end bound will
    // be equal to uncompressed size
    // this part ensures the record match to key list bound
    if (record_start - decomp_accu >= uncomp_size) {
      break;
    }

    unsigned long upbound = uncomp_size; // - this->key_list[i]->record_start;
    unsigned long expect_end = 0;
    auto expect_start = this->key_list[i]->record_start - decomp_accu;
    if (i < this->key_list.size() - 1) {
      expect_end =
          this->key_list[i + 1]->record_start - this->key_list[i]->record_start;
      expect_start = this->key_list[i]->record_start - decomp_accu;
    } else {
      // 前一个的 end + size 等于当前这个的开始
      expect_end =
          this->record_block_size - (previous_end + previous_uncomp_size);
    }
    upbound = expect_end < upbound ? expect_end : upbound;

    std::string def;
    if (this->filetype == "MDD") {
      def = be_bin_to_utf16((char *)record_block, expect_start,
                            upbound /* to delete null character*/);
    } else {
      def = be_bin_to_utf8((char *)record_block, expect_start,
                           upbound /* to delete null character*/);
    }
    std::pair<std::string, std::string> vp(key_text, def);
    vec.push_back(vp);
    i++;
  }

  //  assert(size_counter == record_block_size);
  return vec;
}

// this function is used to decode the record block, it will read the record
// block from the file, avoid use this function
int Mdict::decode_record_block() {
  // Legacy full-record decoding is not used by the App, but preserving this
  // entry point must not retain an unbounded zlib path. Validate every block
  // through the single bounded decoder before returning to legacy callers.
  for (uint64_t idx = 0; idx < record_header.size(); ++idx) {
    (void)readRecordBlockBytes(idx);
  }
  return 0;

  // record block start offset: record_block_offset
  uint64_t record_offset = this->record_block_offset;

  uint64_t size_counter = 0l;

  // key list index counter
  unsigned long i = 0l;

  // record offset
  unsigned long offset = 0l;

  std::vector<uint8_t> record_block_uncompressed_v;
  unsigned char *record_block_uncompressed_b;
  uint64_t checksum = 0l;
  for (int idx = 0; idx < static_cast<int>(this->record_header.size()); idx++) {
    uint64_t comp_size = record_header[idx]->compressed_size;
    uint64_t uncomp_size = record_header[idx]->decompressed_size;
    char *record_block_cmp_buffer = (char *)calloc(comp_size, sizeof(char));
    this->readfile(record_offset, comp_size, record_block_cmp_buffer);
    //    putbytes(record_block_cmp_buffer, 8, true);
    // 4 bytes, compress type
    char *comp_type_b = (char *)calloc(4, sizeof(char));
    memcpy(comp_type_b, record_block_cmp_buffer, 4 * sizeof(char));
    //    putbytes(comp_type_b, 4, true);
    int comp_type = comp_type_b[0] & 0xff;
    // 4 bytes adler32 checksum
    char *checksum_b = (char *)calloc(4, sizeof(char));
    memcpy(checksum_b, record_block_cmp_buffer + 4, 4 * sizeof(char));
    checksum = be_bin_to_u32((unsigned char *)checksum_b);
    free(checksum_b);

    if (comp_type == 0 /* not compressed TODO*/) {
      throw std::runtime_error("uncompress block not support yet");
    } else {
      char *record_block_decrypted_buff;
      if (this->encrypt == ENCRYPT_RECORD_ENC /* record block encrypted */) {
        // TODO
        throw std::runtime_error("record encrypted not support yet");
      }
      record_block_decrypted_buff = record_block_cmp_buffer + 8 * sizeof(char);
      // decompress
      if (comp_type == 1 /* lzo */) {
        throw std::runtime_error("lzo compress not support yet");
      } else if (comp_type == 2) {
        // zlib compress
        record_block_uncompressed_v =
            zlib_mem_uncompress(record_block_decrypted_buff, comp_size);
        if (record_block_uncompressed_v.empty()) {
          throw std::runtime_error("record block decompress failed size == 0");
        }
        record_block_uncompressed_b = record_block_uncompressed_v.data();
        uint32_t adler32cs = adler32checksum(
            record_block_uncompressed_b, static_cast<uint32_t>(uncomp_size));
        assert(adler32cs == checksum);
        (void)checksum;        (void)adler32cs;
        assert(record_block_uncompressed_v.size() == uncomp_size);
      } else {
        throw std::runtime_error(
            "cannot determine the record block compress type");
      }
    }

    free(comp_type_b);
    free(record_block_cmp_buffer);
    //    free(record_block_uncompressed_b); /* ensure not free twice*/

    // unsigned char* record_block = record_block_uncompressed_b;
    /**
     * 请注意，block 是会有很多个的，而每个block都可能会被压缩
     * 而 key_list中的 record_start,
     * key_text是相对每一个block而言的，end是需要每次解析的时候算出来的
     * 所有的record_start/length/end都是针对解压后的block而言的
     */
    while (i < this->key_list.size()) {
      unsigned long record_start = key_list[i]->record_start;
      std::string key_text = key_list[i]->key_word;
      if (record_start - offset >= uncomp_size) {
        // overflow
        break;
      }
      unsigned long record_end;
      if (i < this->key_list.size() - 1) {
        record_end = this->key_list[i + 1]->record_start;
      } else {
        record_end = uncomp_size + offset;
      }

      this->key_data.push_back(new record(
          key_text, key_list[i]->record_start, this->encoding, record_offset,
          comp_size, uncomp_size, comp_type, (this->encrypt == 1),
          record_start - offset, record_end - offset));
      i++;
    }
    // offset += record_block.length
    offset += uncomp_size;
    size_counter += comp_size;
    record_offset += comp_size;

    //    break;
  }
  assert(size_counter == record_block_size);
  (void)size_counter;  return 0;
}

/**
 * decode the key block info
 * D1b-3A-2A-R1: validate buffer and length before any access.
 * External Adler-32 checksum for version >= 2 key-block-info.
 * Encrypted=2 decrypt length uses checkedUInt64ToInt.
 * @param key_block_info_buffer the key block info buffer
 * @param kb_info_buff_len the key block buffer length
 * @param key_block_num the key block number
 * @param entries_num the entries number
 * @return
 */
int Mdict::decode_key_block_info(char *key_block_info_buffer,
                                 uint64_t kb_info_buff_len,
                                 uint64_t key_block_num,
                                 uint64_t entries_num) {
  // D1b-3A-2A-R1: validate buffer and length BEFORE any memory access
  if (key_block_info_buffer == nullptr) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  if (kb_info_buff_len < 8) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }

  std::vector<std::unique_ptr<key_block_info>> parsed_block_info;
  parsed_block_info.reserve(checkedUInt64ToSizeT(key_block_num));

  byte *kb_info_decrypted = reinterpret_cast<byte *>(key_block_info_buffer);

  // key block info offset indicator
  size_t data_offset = 0;

  if (this->version >= 2.0) {
    // if version >= 2.0, use zlib compression
    // D1b-3A-2A-R1: read compression type AFTER length validation.

    // Read prefix: 4-byte compression type, 4-byte Adler-32
    uint32_t comp_type_raw =
        static_cast<uint32_t>(static_cast<unsigned char>(key_block_info_buffer[0])) |
        (static_cast<uint32_t>(static_cast<unsigned char>(key_block_info_buffer[1])) << 8) |
        (static_cast<uint32_t>(static_cast<unsigned char>(key_block_info_buffer[2])) << 16) |
        (static_cast<uint32_t>(static_cast<unsigned char>(key_block_info_buffer[3])) << 24);

    if ((comp_type_raw & 255) != 2 ||
        key_block_info_buffer[1] != 0 ||
        key_block_info_buffer[2] != 0 ||
        key_block_info_buffer[3] != 0) {
      throw ResourceException(ResourceErrorCode::invalidCompressionType);
    }

    // Read declared Adler-32 from prefix bytes 4..7
    uint32_t declared_checksum = be_bin_to_u32(
        reinterpret_cast<const unsigned char *>(key_block_info_buffer) + 4);

    uint64_t payloadLen = checkedSubtractUInt64(kb_info_buff_len, 8ULL);
    if (payloadLen == 0) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    if (this->encrypt == ENCRYPT_KEY_INFO_ENC) {
      kb_info_decrypted = mdx_decrypt(
          reinterpret_cast<byte *>(key_block_info_buffer),
          checkedUInt64ToInt(kb_info_buff_len));
    }

    // D1b-3A-2A: validate expected decompressed size.
    if (this->key_block_info_decompress_size == 0) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    if (this->key_block_info_decompress_size > limits_.maximumKeyBlockInfoDecompressedBytes) {
      throw ResourceException(ResourceErrorCode::keyBlockInfoDecompressedTooLarge);
    }

    // D1b-3A-2A: use bounded exact zlib decompression (payload only, after 8-byte prefix).
    // Pass payloadLen as sourceLen (already trimmed) and exact expected decompressed size.
    std::vector<uint8_t> decompress_buff =
        boundedExactZlibDecompress(kb_info_decrypted + 8,
                                   checkedUInt64ToSizeT(payloadLen),
                                   checkedUInt64ToSizeT(this->key_block_info_decompress_size));
    /// uncompress successed
    // boundedExactZlibDecompress already verified size == expected

    // D1b-3A-2A-R1: external Adler-32 check on decompressed result
    uint32_t actual_checksum = adler32checksum(
        decompress_buff.data(),
        static_cast<uint32_t>(this->key_block_info_decompress_size));
    if (actual_checksum != declared_checksum) {
      throw ResourceException(ResourceErrorCode::checksumMismatch);
    }

    // get key block info list
    uint64_t num_entries_counter = 0;
    // key number counter
    uint64_t counter = 0;

    // current block entries
    uint64_t current_entries = 0;

    uint64_t previous_start_offset = 0;

    int byte_width = 1;
    int text_term = 0;
    if (this->version >= 2.0) {
      byte_width = 2;
      text_term = 1;
    }

    uint64_t comp_acc = 0;
    uint64_t decomp_acc = 0;
    while (counter < this->key_block_num) {
      if (data_offset + static_cast<size_t>(this->number_width) > decompress_buff.size()) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      if (this->version >= 2.0) {
        auto bin_pointer =
            decompress_buff.data() + data_offset * sizeof(uint8_t);
        current_entries = be_bin_to_u64(bin_pointer);
      } else {
        auto bin_pointer =
            decompress_buff.data() + data_offset * sizeof(uint8_t);
        current_entries = be_bin_to_u32(bin_pointer);
      }
      num_entries_counter = checkedAddUInt64(num_entries_counter, current_entries);
      if (num_entries_counter > limits_.maximumEntryCount) {
        throw ResourceException(ResourceErrorCode::entryCountTooLarge);
      }
      if (num_entries_counter > entries_num) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }

      // move offset
      data_offset += static_cast<size_t>(this->number_width) * sizeof(uint8_t);

      // first key size
      uint64_t first_key_size = 0;

      if (data_offset + static_cast<size_t>(byte_width) > decompress_buff.size()) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      if (this->version >= 2.0) {
        first_key_size = be_bin_to_u16(decompress_buff.data() +
                                       data_offset * sizeof(uint8_t));
      } else {
        first_key_size = be_bin_to_u8(decompress_buff.data() +
                                      data_offset * sizeof(uint8_t));
      }
      data_offset += static_cast<size_t>(byte_width);

      // step_gap means first key start offset to first key end;
      uint64_t step_gap = 0;

      if (this->encoding == 1 /* encoding utf16 equals 1*/) {
        step_gap = (first_key_size + static_cast<uint64_t>(text_term)) * 2ULL;
      } else {
        step_gap = first_key_size + static_cast<uint64_t>(text_term);
      }

      // DECODE first CODE
      // Validate bounds before accessing
      if (data_offset + checkedUInt64ToSizeT(step_gap) > decompress_buff.size()) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      std::string first_key;
      if (this->filetype == "MDX") {
        first_key =
            be_bin_to_utf8((char *)(decompress_buff.data() + data_offset), 0,
                           static_cast<unsigned long>(step_gap) - text_term);
      } else {
        unsigned char *utf16_point =
            (unsigned char *)(decompress_buff.data() + data_offset);
        uint64_t utf16_len = step_gap - static_cast<uint64_t>(text_term);
        unsigned char *utf8_buff =
            (unsigned char *)calloc(checkedUInt64ToSizeT(utf16_len), sizeof(unsigned char));
        if (!utf8_buff) throw ResourceException(ResourceErrorCode::allocationFailed);
        utf16le_to_utf8(utf16_point, utf16_len - 1, utf8_buff, utf16_len);
        first_key = std::string(reinterpret_cast<char *>(utf8_buff), utf16_len);
        free(utf8_buff);
      }
      // move forward
      data_offset += checkedUInt64ToSizeT(step_gap);

      // the last key
      uint64_t last_key_size = 0;

      if (data_offset + static_cast<size_t>(byte_width) > decompress_buff.size()) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      if (this->version >= 2.0) {
        last_key_size = be_bin_to_u16(decompress_buff.data() +
                                      data_offset * sizeof(uint8_t));
      } else {
        last_key_size = be_bin_to_u8(decompress_buff.data() +
                                     data_offset * sizeof(uint8_t));
      }
      data_offset += static_cast<size_t>(byte_width);

      if (this->encoding == 1 /* ENCODING_UTF16 */) {
        step_gap = (last_key_size + static_cast<uint64_t>(text_term)) * 2ULL;
      } else {
        step_gap = last_key_size + static_cast<uint64_t>(text_term);
      }

      if (data_offset + checkedUInt64ToSizeT(step_gap) > decompress_buff.size()) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      std::string last_key;
      if (this->filetype == "MDX") {
        last_key =
            be_bin_to_utf8((char *)(decompress_buff.data() + data_offset), 0,
                           static_cast<unsigned long>(step_gap) - text_term);
      } else {
        unsigned char *utf16_point =
            (unsigned char *)(decompress_buff.data() + data_offset);
        uint64_t utf16_len = step_gap - static_cast<uint64_t>(text_term);
        unsigned char *utf8_buff =
            (unsigned char *)calloc(checkedUInt64ToSizeT(utf16_len), sizeof(unsigned char));
        if (!utf8_buff) throw ResourceException(ResourceErrorCode::allocationFailed);
        utf16le_to_utf8(utf16_point, utf16_len - 1, utf8_buff, utf16_len);
        last_key = std::string(reinterpret_cast<char *>(utf8_buff), utf16_len);
        free(utf8_buff);
      }

      // move forward
      data_offset += checkedUInt64ToSizeT(step_gap);

      // ------------
      // key block part
      // ------------

      if (data_offset + static_cast<size_t>(this->number_width) * 2 > decompress_buff.size()) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }

      uint64_t key_block_compress_size = 0;
      if (version >= 2.0) {
        key_block_compress_size =
            be_bin_to_u64(decompress_buff.data() + data_offset);
      } else {
        key_block_compress_size =
            be_bin_to_u32(decompress_buff.data() + data_offset);
      }

      data_offset += static_cast<size_t>(this->number_width);

      uint64_t key_block_decompress_size = 0;

      if (version >= 2.0) {
        key_block_decompress_size =
            be_bin_to_u64(decompress_buff.data() + data_offset);
      } else {
        key_block_decompress_size =
            be_bin_to_u32(decompress_buff.data() + data_offset);
      }

      // entries offset move forward
      data_offset += static_cast<size_t>(this->number_width);

      // D1b-3A-2A: per-block size validation
      if (key_block_compress_size <= 8 || key_block_decompress_size == 0) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      if (key_block_compress_size > limits_.maximumSingleKeyBlockCompressedBytes) {
        throw ResourceException(ResourceErrorCode::singleKeyBlockCompressedTooLarge);
      }
      if (key_block_decompress_size > limits_.maximumSingleKeyBlockDecompressedBytes) {
        throw ResourceException(ResourceErrorCode::singleKeyBlockDecompressedTooLarge);
      }

      const uint64_t next_comp_acc =
          checkedAddUInt64(comp_acc, key_block_compress_size);
      const uint64_t next_decomp_acc =
          checkedAddUInt64(decomp_acc, key_block_decompress_size);
      if (next_comp_acc > limits_.maximumTotalKeyBlockCompressedBytes) {
        throw ResourceException(ResourceErrorCode::totalKeyBlockCompressedTooLarge);
      }
      if (next_decomp_acc > limits_.maximumTotalKeyBlockDecompressedBytes) {
        throw ResourceException(ResourceErrorCode::totalKeyBlockDecompressedTooLarge);
      }

      parsed_block_info.push_back(std::make_unique<key_block_info>(
          first_key, last_key, previous_start_offset, key_block_compress_size,
          key_block_decompress_size, comp_acc, decomp_acc, current_entries));

      previous_start_offset = next_comp_acc;
      counter = checkedAddUInt64(counter, 1ULL);
      comp_acc = next_comp_acc;
      decomp_acc = next_decomp_acc;
    }

    // D1b-3A-2A: validate block count consistency.
    if (counter != this->key_block_num) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    // D1b-3A-2A: validate cumulative totals against header.
    if (comp_acc != this->key_block_size) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    if (comp_acc > limits_.maximumTotalKeyBlockCompressedBytes) {
      throw ResourceException(ResourceErrorCode::totalKeyBlockCompressedTooLarge);
    }
    if (decomp_acc > limits_.maximumTotalKeyBlockDecompressedBytes) {
      throw ResourceException(ResourceErrorCode::totalKeyBlockDecompressedTooLarge);
    }

    // D1b-3A-2A: strict entry count mismatch — throw instead of cerr warning.
    if (num_entries_counter != this->entries_num) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    if (data_offset != decompress_buff.size()) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }

    std::vector<key_block_info *> committed;
    committed.reserve(parsed_block_info.size());
    for (const auto &item : parsed_block_info) committed.push_back(item.get());
    for (auto *item : key_block_info_list) delete item;
    key_block_info_list.swap(committed);
    for (auto &item : parsed_block_info) item.release();

  } else {
    // doesn't compression
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  this->key_block_body_start =
      checkedAddUInt64(this->key_block_info_start_offset, this->key_block_info_size);
  /// passed
  return 0;
}

/**
 * read in the file from the file stream
 * D1b-3A-2A: bounded — validates offset+len against actual file size,
 * uses checked conversions, and verifies gcount() matches exactly.
 * @param offset the file start offset
 * @param len the byte length needs to read
 * @param buf the target buffer
 */
void Mdict::readfile(uint64_t offset, uint64_t len, char *buf) {
  // Validate offset + len does not exceed actual file size
  uint64_t endOffset = checkedAddUInt64(offset, len);
  if (endOffset > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  std::streamoff so = checkedUInt64ToStreamoff(offset);
  std::streamsize ss = checkedUInt64ToStreamSize(len);

  instream.seekg(so);
  if (!instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  instream.read(buf, ss);
  if (instream.gcount() != ss) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
}

/***************************************
 *             public part             *
 ***************************************/

/**
 * init the dictionary file
 */
void Mdict::init() {
  limits_.validate();
  if (!std::filesystem::exists(filename)) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  this->instream = std::ifstream(filename, std::ios::binary);
  if (!this->instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // Obtain the size from the opened stream, avoiding a separate stat-size
  // lookup.  This does not claim complete path/open TOCTOU hardening.
  this->instream.seekg(0, std::ios::end);
  std::streamoff endPos = this->instream.tellg();
  if (endPos < 0) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  this->actual_file_size_ = static_cast<uint64_t>(endPos);
  this->instream.clear();  // clear eofbit
  this->instream.seekg(0, std::ios::beg);
  if (!this->instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  if (this->actual_file_size_ > limits_.maximumFileBytes) {
    throw ResourceException(ResourceErrorCode::fileTooLarge);
  }

  /* indexing... */
  this->read_header();
  this->read_key_block_header();
  this->read_key_block_info();
  this->read_record_block_header();
  //  this->decode_record_block(); // don't use this function, it's too slow
}

void Mdict::initMetadataOnly() {
  limits_.validate();
  if (!std::filesystem::exists(filename)) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  this->instream = std::ifstream(filename, std::ios::binary);
  if (!this->instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  // Obtain the size from the opened stream, avoiding a separate stat-size
  // lookup.  This does not claim complete path/open TOCTOU hardening.
  this->instream.seekg(0, std::ios::end);
  std::streamoff endPos = this->instream.tellg();
  if (endPos < 0) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  this->actual_file_size_ = static_cast<uint64_t>(endPos);
  this->instream.clear();
  this->instream.seekg(0, std::ios::beg);
  if (!this->instream) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }

  if (this->actual_file_size_ > limits_.maximumFileBytes) {
    throw ResourceException(ResourceErrorCode::fileTooLarge);
  }

  this->read_header();
  if (this->version < 2.0) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  this->read_key_block_header();
  this->read_key_block_info_metadata();
  this->read_record_block_header();
}

uint64_t Mdict::recordStreamSize() const {
  if (record_header.empty()) return 0;
  const auto *last = record_header.back();
  return checkedAddUInt64(last->decompressed_size_accumulator,
                          last->decompressed_size);
}

std::vector<uint8_t> Mdict::readRecordBlockBytes(uint64_t block_id) {
  if (block_id >= record_header.size()) {
    throw ResourceException(ResourceErrorCode::offsetOutOfBounds);
  }
  const auto *header = record_header[block_id];
  if (encrypt == ENCRYPT_RECORD_ENC) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  const uint64_t comp_size = header->compressed_size;
  const uint64_t decomp_size = header->decompressed_size;
  if (comp_size < 8 || decomp_size == 0) {
    throw ResourceException(ResourceErrorCode::malformedRecordBlockMetadata);
  }
  if (comp_size > limits_.maximumSingleRecordBlockCompressedBytes) {
    throw ResourceException(ResourceErrorCode::singleRecordBlockCompressedTooLarge);
  }
  if (decomp_size > limits_.maximumSingleRecordBlockDecompressedBytes) {
    throw ResourceException(ResourceErrorCode::singleRecordBlockDecompressedTooLarge);
  }
  const uint64_t file_offset = checkedAddUInt64(
      record_block_offset, header->compressed_size_accumulator);
  const uint64_t file_end = checkedAddUInt64(file_offset, comp_size);
  if (file_end > actual_file_size_) {
    throw ResourceException(ResourceErrorCode::truncatedFile);
  }
  std::vector<uint8_t> compressed;
  try {
#ifdef MDICT_RESOURCE_TEST_OBSERVER
    observeInputBufferAllocation();
#endif
    compressed.resize(checkedUInt64ToSizeT(comp_size));
  } catch (const std::bad_alloc &) {
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  readfile(file_offset, comp_size, reinterpret_cast<char *>(compressed.data()));

  const uint32_t comp_type = validatedRecordBlockCompressionType(compressed.data());
  const uint32_t expected_checksum = be_bin_to_u32(compressed.data() + 4);
  const uint64_t payload_size = checkedSubtractUInt64(comp_size, 8ULL);
  std::vector<uint8_t> output;
  if (comp_type == 0) {
    if (payload_size != decomp_size) {
      throw ResourceException(ResourceErrorCode::decompressedSizeMismatch);
    }
    output.assign(compressed.begin() + 8, compressed.end());
  } else if (comp_type == 1) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  } else if (comp_type == 2) {
    output = boundedExactZlibDecompress(
        compressed.data() + 8, checkedUInt64ToSizeT(payload_size),
        checkedUInt64ToSizeT(decomp_size));
  } else {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  if (output.size() != checkedUInt64ToSizeT(decomp_size)) {
    throw ResourceException(ResourceErrorCode::decompressedSizeMismatch);
  }
  if (adler32checksum(output.data(), static_cast<uint32_t>(output.size())) !=
      expected_checksum) {
    throw ResourceException(ResourceErrorCode::checksumMismatch);
  }
  return output;
}

std::string Mdict::readRecordAt(uint64_t record_start, uint64_t record_end) {
  if (filetype != "MDX") {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  if (encoding != 0 /* ENCODING_UTF8 */) {
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }
  const uint64_t stream_size = recordStreamSize();
  if (record_end < record_start || record_start > stream_size ||
      record_end > stream_size) {
    throw ResourceException(ResourceErrorCode::offsetOutOfBounds);
  }
  const uint64_t requested_size = checkedSubtractUInt64(record_end, record_start);
  if (requested_size == 0) return {};
  if (requested_size > limits_.maximumRecordRangeBytes) {
    throw ResourceException(ResourceErrorCode::recordRangeTooLarge);
  }

  std::string result;
  try {
    result.reserve(checkedUInt64ToSizeT(requested_size));
  } catch (const std::bad_alloc &) {
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  uint64_t cursor = record_start;
  while (cursor < record_end) {
    const long located_block = reduce_record_block_offset(cursor);
    if (located_block < 0 ||
        static_cast<uint64_t>(located_block) >= record_header.size()) {
      throw ResourceException(ResourceErrorCode::offsetOutOfBounds);
    }
    const uint64_t block_id = static_cast<uint64_t>(located_block);
    const auto *header = record_header[block_id];
    const uint64_t block_start = header->decompressed_size_accumulator;
    const uint64_t block_end = checkedAddUInt64(
        block_start, header->decompressed_size);
    if (cursor < block_start || cursor >= block_end) {
      throw ResourceException(ResourceErrorCode::offsetOutOfBounds);
    }
    const auto bytes = readRecordBlockBytes(block_id);
    const uint64_t local_start = checkedSubtractUInt64(cursor, block_start);
    const uint64_t copy_end = std::min(record_end, block_end);
    const uint64_t local_end = checkedSubtractUInt64(copy_end, block_start);
    const uint64_t slice_size = checkedSubtractUInt64(local_end, local_start);
    const uint64_t next_returned = checkedAddUInt64(
        static_cast<uint64_t>(result.size()), slice_size);
    if (next_returned > limits_.maximumReturnedRecordBytes) {
      throw ResourceException(ResourceErrorCode::returnedRecordTooLarge);
    }
    result.append(reinterpret_cast<const char *>(bytes.data() + local_start),
                  checkedUInt64ToSizeT(slice_size));
    if (copy_end <= cursor) {
      throw ResourceException(ResourceErrorCode::offsetOutOfBounds);
    }
    cursor = copy_end;
  }
  return trim_nulls(result);
}

/**
 * find the key word includes in which block
 * @param phrase
 * @param start
 * @param end
 * @return
 */
long Mdict::reduce_key_info_block(
    std::string phrase, unsigned long start,
    unsigned long end) { // non-recursive reduce implements
  (void)start;
  for (size_t i = 0; i < end; ++i) {
    std::string first_key = this->key_block_info_list[i]->first_key;
    std::string last_key = this->key_block_info_list[i]->last_key;
    if (phrase.compare(first_key) >= 0 && phrase.compare(last_key) <= 0) {
      return i;
    }
  }
  return -1;
}

long Mdict::reduce_key_info_block_items_vector(
    std::vector<key_list_item *> wordlist,
    std::string phrase) { // non-recursive reduce implements
  unsigned long left = 0;
  unsigned long right = wordlist.size() - 1;
  unsigned long mid = 0;
  std::string word = _s(std::move(phrase));

  int comp = 0;
  while (left <= right) {
    mid = left + ((right - left) >> 1);
    // std::cout << "reduce1, mid = " << mid << ", left: " << left << ", right :
    // " <<  right << ", size: " << wordlist.size() << std::endl;
    if (mid >= wordlist.size()) {
      return -1;
    }
    comp = word.compare(_s(wordlist[mid]->key_word));
    if (comp == 0) {
      return mid;
    } else if (comp > 0) {
      left = mid + 1;
    } else {
      right = mid - 1;
    }
  }
  return -1;
}

/**
 *
 * @param wordlist
 * @param phrase
 * @return
 */
long Mdict::reduce_record_block_offset(
    unsigned long record_start) { // non-recursive reduce implements
  if (record_header.empty()) return -1;
  size_t left = 0;
  size_t right = record_header.size();
  // Upper-bound search: the selected block has the greatest start <= input.
  while (left < right) {
    const size_t mid = left + ((right - left) >> 1);
    if (record_start >= record_header[mid]->decompressed_size_accumulator) {
      left = mid + 1;
    } else {
      right = mid;
    }
  }
  if (left == 0) return -1;
  if (left - 1 > static_cast<size_t>(std::numeric_limits<long>::max())) {
    throw ResourceException(ResourceErrorCode::numericConversionOverflow);
  }
  return static_cast<long>(left - 1);
#if 0
  unsigned long mid = 0;
  while (left <= right) {
    mid = left + ((right - left) >> 1);
    if (record_start >=
        this->record_header[mid]->decompressed_size_accumulator) {
      left = mid + 1;
    } else if (record_start <
               this->record_header[mid]->decompressed_size_accumulator) {
      right = mid - 1;
    }
  }
  return left - 1;
#endif
}

std::string Mdict::reduce_particial_keys_vector(
    std::vector<std::pair<std::string, std::string>> &vec, std::string phrase) {
  unsigned int left = 0;
  unsigned int right = vec.size() - 1;
  unsigned int mid = 0;
  unsigned int result = 0;
  while (left < right) {
    mid = left + ((right - left) >> 1);
    const auto first_word = _s(phrase);
    const auto second_word = _s(vec[mid].first);
    if (first_word.compare(second_word) > 0) {
      left = mid + 1;
    } else if (first_word.compare(second_word) == 0) {
      left = mid;
      break;
    } else {
      right = mid > 1 ? mid - 1 : mid;
    }
  }
  result = left;

  return vec[result].second;
}

std::string Mdict::locate(const std::string resource_name,
                          mdict_encoding_t encoding) {
  // find key item in key list
  auto it = std::find_if(this->key_list.begin(), this->key_list.end(),
                         [&](const key_list_item *item) {
                           return item->key_word == resource_name;
                         });
  if (it != this->key_list.end()) {
    std::string key_word = (*it)->key_word;
    if (key_word == resource_name) {
      if ((*it)->record_start >= 0) {
        // reduce search the record block index by word record start offset
        unsigned long record_block_idx =
            reduce_record_block_offset((*it)->record_start);
        // decode recode by record index
        auto vec = decode_record_block_by_rid(record_block_idx);
        // reduce the definition by word
        std::string def = reduce_particial_keys_vector(vec, resource_name);

        auto treated_output = trim_nulls(def);

        if (encoding == MDICT_ENCODING_HEX) {
          return treated_output; // Return raw hex string
        } else {
          return base64_from_hex(
              treated_output); // Return base64 encoded string
        }
      }
      return std::string("");
    }
  }
  return std::string("");
}

std::string Mdict::lookup0(const std::string word) {
  try {

    auto it = std::find_if(
        this->key_list.begin(), this->key_list.end(),
        [&](const key_list_item *item) { return item->key_word == word; });
    if (it != this->key_list.end()) {
      std::string key_word = (*it)->key_word;
      if (key_word == word) {
        if ((*it)->record_start >= 0) {
          // reduce search the record block index by word record start offset
          unsigned long record_block_idx =
              reduce_record_block_offset((*it)->record_start);
          // decode recode by record index
          auto vec = decode_record_block_by_rid(record_block_idx);
          // reduce the definition by word
          std::string def = reduce_particial_keys_vector(vec, word);

          auto treated_output = trim_nulls(def);

          return treated_output;
        }
        return std::string("");
      }
    }
    return std::string("");

  
  } catch (std::exception &e) {
    std::cout << "lookup error: " << e.what() << std::endl;
  }
  return std::string();
}


/**
 * look the file by word
 * @param word the searching word
 * @return
 */
std::string Mdict::lookup(const std::string word) {
  try {

    // search word in key block info list
    long idx = this->reduce_key_info_block(_s(word), 0,
                                           this->key_block_info_list.size());
    if (idx >= 0) {
      // decode key block by block id
      std::vector<key_list_item *> tlist =
          this->decode_key_block_by_block_id(idx);
      // reduce word id from key list item vector to get the word index of key list
      long word_id = reduce_key_info_block_items_vector(tlist, word);
      if (word_id >= 0) {
        // reduce search the record block index by word record start offset
        unsigned long record_block_idx =
            reduce_record_block_offset(tlist[word_id]->record_start);
        // decode recode by record index
        auto vec = decode_record_block_by_rid(record_block_idx);
        // reduce the definition by word
        std::string def = reduce_particial_keys_vector(vec, word);
        return def;
      }
    }
  } catch (std::exception &e) {
    std::cout << "lookup error: " << e.what() << std::endl;
  }
  return std::string();
}

std::string Mdict::parse_definition(const std::string word,
                                    unsigned long record_start) {
  // reduce search the record block index by word record start offset
  unsigned long record_block_idx = reduce_record_block_offset(record_start);
  // decode recode by record index
  auto vec = decode_record_block_by_rid(record_block_idx);
  // reduce the definition by word
  std::string def = reduce_particial_keys_vector(vec, word);
  return def;
}

/**
 * look the file by word
 * @param word the searching word
 * @return
 */
std::vector<key_list_item *> Mdict::keyList() { return this->key_list; }

bool Mdict::endsWith(std::string const &fullString, std::string const &ending) {
  if (fullString.length() >= ending.length()) {
    return (0 == fullString.compare(fullString.length() - ending.length(),
                                    ending.length(), ending));
  } else {
    return false;
  }
}
} // namespace mdict
