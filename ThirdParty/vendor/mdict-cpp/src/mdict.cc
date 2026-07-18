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

  // header size buffer
  char *head_size_buf = (char *)std::calloc(4, sizeof(char));
  if (!head_size_buf) throw ResourceException(ResourceErrorCode::allocationFailed);
  readfile(0, 4, head_size_buf);

  // header byte size convert
  uint32_t header_bytes_size =
      be_bin_to_u32((const unsigned char *)head_size_buf);
  std::free(head_size_buf);

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

  // header buffer — use checked size_t conversion
  unsigned char *head_buffer =
      (unsigned char *)std::calloc(checkedUInt64ToSizeT(header_bytes_size),
                                   sizeof(unsigned char));
  if (!head_buffer) throw ResourceException(ResourceErrorCode::allocationFailed);
  readfile(4, header_bytes_size, (char *)head_buffer);
  /// passed

  // 3. adler32 checksum
  // -----------------------------------------

  // D1b-3A-2A: enforce header checksum in both Debug and Release.
  // MDX format: adler32 of the raw header bytes (UTF-16 XML) stored as
  // big-endian uint32 at offset header_bytes_size + 4.
  char *head_checksum_buffer = (char *)std::calloc(4, sizeof(char));
  if (!head_checksum_buffer) {
    std::free(head_buffer);
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  readfile(header_bytes_size + 4, 4, head_checksum_buffer);

  uint32_t expected_checksum =
      be_bin_to_u32((const unsigned char *)head_checksum_buffer);
  std::free(head_checksum_buffer);

  uint32_t actual_checksum =
      adler32checksum(head_buffer, header_bytes_size);
  if (actual_checksum != expected_checksum) {
    std::free(head_buffer);
    throw ResourceException(ResourceErrorCode::checksumMismatch);
  }

  // -----------------------------------------
  // 4. convert header buffer into utf16 text
  // -----------------------------------------

  // header text utf16

  std::string utf8_temp;
  if (!utf16_to_utf8_header(head_buffer, header_bytes_size, utf8_temp)) {
    std::free(head_buffer);
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  std::free(head_buffer);

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
  if (headinfo.find("Encoding") != headinfo.end() ||
      headinfo["Encoding"] == "" || headinfo["Encoding"] == "UTF-8") {
    this->encoding = ENCODING_UTF8;
  } else if (headinfo["Encoding"] == "GBK" ||
             headinfo["Encoding"] == "GB2312") {
    this->encoding = ENCODING_GB18030;
  } else if (headinfo["Encoding"] == "Big5" || headinfo["Encoding"] == "BIG5") {
    this->encoding = ENCODING_BIG5;
  } else if (headinfo["Encoding"] == "utf16" ||
             headinfo["Encoding"] == "utf-16") {
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

  // key block info buffer
  char *key_block_info_buffer = (char *)calloc(
      checkedUInt64ToSizeT(key_block_info_bytes_num), sizeof(char));
  if (!key_block_info_buffer)
    throw ResourceException(ResourceErrorCode::allocationFailed);
  // read buffer
  this->readfile(this->key_block_start_offset, key_block_info_bytes_num,
                 key_block_info_buffer);
  /// PASSED

  // TODO key block info encrypted file not support yet
  if (this->encrypt == ENCRYPT_RECORD_ENC) {
    if (key_block_info_buffer)
      std::free(key_block_info_buffer);
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  // 1. [0:8]([0:4]) number of key blocks
  char *key_block_nums_bytes =
      (char *)calloc(checkedUInt64ToSizeT(this->number_width), sizeof(char));
  if (!key_block_nums_bytes) {
    std::free(key_block_info_buffer);
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  int eno = bin_slice(key_block_info_buffer, static_cast<int>(key_block_info_bytes_num), 0,
                      this->number_width, key_block_nums_bytes);
  if (eno != 0) {
    if (key_block_info_buffer)
      std::free(key_block_info_buffer);
    if (key_block_nums_bytes)
      std::free(key_block_nums_bytes);
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  /// passed

  uint64_t key_block_num = 0;
  if (this->number_width == 8)
    key_block_num = be_bin_to_u64((const unsigned char *)key_block_nums_bytes);
  else if (this->number_width == 4)
    key_block_num = be_bin_to_u32((const unsigned char *)key_block_nums_bytes);
  if (key_block_nums_bytes)
    std::free(key_block_nums_bytes);
  /// passed

  // D1b-3A-2A: validate key_block_num against limits
  if (key_block_num == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_num > limits_.maximumKeyBlockCount)
    throw ResourceException(ResourceErrorCode::keyBlockCountTooLarge);

  // 2. [8:16]  - number of entries
  char *entries_num_bytes =
      (char *)calloc(checkedUInt64ToSizeT(this->number_width), sizeof(char));
  if (!entries_num_bytes) {
    std::free(key_block_info_buffer);
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  eno = bin_slice(key_block_info_buffer, static_cast<int>(key_block_info_bytes_num),
                  this->number_width, this->number_width, entries_num_bytes);
  if (eno != 0) {
    if (key_block_info_buffer)
      std::free(key_block_info_buffer);
    if (entries_num_bytes)
      std::free(entries_num_bytes);
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  /// passed

  uint64_t entries_num = 0;
  if (this->number_width == 8)
    entries_num = be_bin_to_u64((const unsigned char *)entries_num_bytes);
  else if (this->number_width == 4)
    entries_num = be_bin_to_u32((const unsigned char *)entries_num_bytes);  // D1b-3A-2A: fixed — was assigning to key_block_num
  if (entries_num_bytes)
    std::free(entries_num_bytes);
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
    char *key_block_info_decompress_size_bytes =
        (char *)calloc(checkedUInt64ToSizeT(this->number_width), sizeof(char));
    if (!key_block_info_decompress_size_bytes) {
      std::free(key_block_info_buffer);
      throw ResourceException(ResourceErrorCode::allocationFailed);
    }
    eno = bin_slice(key_block_info_buffer, static_cast<int>(key_block_info_bytes_num),
                    this->number_width * 2, this->number_width,
                    key_block_info_decompress_size_bytes);
    if (eno != 0) {
      if (key_block_info_buffer)
        std::free(key_block_info_buffer);
      if (key_block_info_decompress_size_bytes)
        std::free(key_block_info_decompress_size_bytes);
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    /// passed

    uint64_t key_block_info_decompress_size = 0;
    if (this->number_width == 8)
      key_block_info_decompress_size = be_bin_to_u64(
          (const unsigned char *)key_block_info_decompress_size_bytes);
    else if (this->number_width == 4)
      key_block_info_decompress_size = be_bin_to_u32(
          (const unsigned char *)key_block_info_decompress_size_bytes);

    // D1b-3A-2A: validate decompressed size
    if (key_block_info_decompress_size == 0)
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    if (key_block_info_decompress_size > limits_.maximumKeyBlockInfoDecompressedBytes)
      throw ResourceException(ResourceErrorCode::keyBlockInfoDecompressedTooLarge);

    this->key_block_info_decompress_size = key_block_info_decompress_size;
    if (key_block_info_decompress_size_bytes)
      std::free(key_block_info_decompress_size_bytes);
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
  char *key_block_info_size_buffer =
      (char *)calloc(checkedUInt64ToSizeT(this->number_width), sizeof(char));
  if (!key_block_info_size_buffer) {
    std::free(key_block_info_buffer);
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  eno = bin_slice(key_block_info_buffer, static_cast<int>(key_block_info_bytes_num),
                  key_block_info_size_start_offset, this->number_width,
                  key_block_info_size_buffer);
  if (eno != 0) {
    if (key_block_info_buffer != nullptr)
      std::free(key_block_info_buffer);
    if (key_block_info_size_buffer != nullptr)
      std::free(key_block_info_size_buffer);
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }

  uint64_t key_block_info_size = 0;
  if (this->number_width == 8)
    key_block_info_size =
        be_bin_to_u64((const unsigned char *)key_block_info_size_buffer);
  else if (this->number_width == 4)
    key_block_info_size =
        be_bin_to_u32((const unsigned char *)key_block_info_size_buffer);
  if (key_block_info_size_buffer != nullptr)
    std::free(key_block_info_size_buffer);
  /// passed

  // D1b-3A-2A: validate info size
  if (key_block_info_size == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_info_size > limits_.maximumKeyBlockInfoCompressedBytes)
    throw ResourceException(ResourceErrorCode::keyBlockInfoCompressedTooLarge);

  // 5. [32:40] - key block size
  char *key_block_size_buffer =
      (char *)calloc(checkedUInt64ToSizeT(this->number_width), sizeof(char));
  if (!key_block_size_buffer) {
    std::free(key_block_info_buffer);
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  eno = bin_slice(key_block_info_buffer, static_cast<int>(key_block_info_bytes_num),
                  key_block_info_size_start_offset + this->number_width,
                  this->number_width, key_block_size_buffer);
  if (eno != 0) {
    if (key_block_info_buffer)
      std::free(key_block_info_buffer);
    if (key_block_size_buffer)
      std::free(key_block_size_buffer);
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  /// passed

  uint64_t key_block_size = 0;
  if (this->number_width == 8)
    key_block_size =
        be_bin_to_u64((const unsigned char *)key_block_size_buffer);
  else if (this->number_width == 4)
    key_block_size =
        be_bin_to_u32((const unsigned char *)key_block_size_buffer);
  if (key_block_size_buffer)
    std::free(key_block_size_buffer);
  /// passed

  // D1b-3A-2A: validate total key block size
  if (key_block_size == 0)
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  if (key_block_size > limits_.maximumTotalKeyBlockCompressedBytes)
    throw ResourceException(ResourceErrorCode::totalKeyBlockCompressedTooLarge);

  // 6. [40:44] - 4bytes checksum (version >= 2.0 only)
  // skip checksum verification for key block header — not in scope

  // free key block info buffer
  if (key_block_info_buffer != nullptr)
    std::free(key_block_info_buffer);

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

  // D1b-3A-2A: fix I1 — use checked size_t conversion for calloc.
  char *key_block_compressed_buffer =
      (char *)calloc(checkedUInt64ToSizeT(this->key_block_size), sizeof(char));
  if (!key_block_compressed_buffer)
    throw ResourceException(ResourceErrorCode::allocationFailed);

  readfile(this->key_block_compressed_start_offset,
           this->key_block_size, key_block_compressed_buffer);

  uint64_t kb_len = this->key_block_size;
  int err =
      decode_key_block((unsigned char *)key_block_compressed_buffer, kb_len);
  if (err != 0) {
    std::free(key_block_compressed_buffer);
    throw ResourceException(ResourceErrorCode::checksumMismatch);
  }

  if (key_block_compressed_buffer != nullptr)
    std::free(key_block_compressed_buffer);
}

void Mdict::read_key_block_info_metadata() {
  // D1b-3A-2A: validate key_block_info_size before allocation.
  if (this->key_block_info_size > limits_.maximumKeyBlockInfoCompressedBytes) {
    throw ResourceException(ResourceErrorCode::keyBlockInfoCompressedTooLarge);
  }

  // start at this->key_block_info_start_offset
  char *key_block_info_buffer = (char *)calloc(
      checkedUInt64ToSizeT(this->key_block_info_size), sizeof(char));
  if (!key_block_info_buffer)
    throw ResourceException(ResourceErrorCode::allocationFailed);

  readfile(this->key_block_info_start_offset, this->key_block_info_size,
           key_block_info_buffer);

  // ------------------------------------
  // decode key_block_info
  // ------------------------------------
  decode_key_block_info(key_block_info_buffer, this->key_block_info_size,
                        this->key_block_num, this->entries_num);

  // D1b-3A-2A: fix I7 — keep as uint64_t (no uint32_t truncation).
  // key block compressed start offset = this->key_block_info_start_offset +
  // key_block_info_size
  this->key_block_compressed_start_offset =
      checkedAddUInt64(this->key_block_info_start_offset, this->key_block_info_size);
  this->record_block_info_offset =
      checkedAddUInt64(this->key_block_compressed_start_offset, this->key_block_size);

  if (key_block_info_buffer != nullptr)
    std::free(key_block_info_buffer);
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
 * @param key_block key block buffer
 * @param key_block_len key block length
 */
std::vector<key_list_item *> Mdict::split_key_block(unsigned char *key_block,
                                                    unsigned long key_block_len,
                                                    unsigned long block_id) {
  (void)block_id;
  size_t key_start_idx = 0;
  size_t key_end_idx = 0;
  std::vector<key_list_item *> inner_key_list;

  while (key_start_idx < key_block_len) {
    // # the corresponding record's offset in record block
    unsigned long record_start = 0;
    size_t width = 0;
    if (this->version >= 2.0) {
      record_start = be_bin_to_u64(key_block + key_start_idx);
    } else {
      record_start = be_bin_to_u32(key_block + key_start_idx);
    }

    if (this->encoding == 1 /* utf16 */) {
      width = 2;
    } else {
      width = 1;
    }

    // key text ends with '\x00'
    // version >= 2.0 delimiter == '0x0000'
    // else delimiter == '0x00'  (< 2.0)
    size_t i = key_start_idx + static_cast<size_t>(number_width);
    if (i >= key_block_len) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    while (i < key_block_len) {
      if (encoding == 1 /*ENCODING_UTF16*/) {
        if ((key_block[i] & 0x0f) == 0 &&        /* delimiter = '0000' */
            ((key_block[i] & 0xf0) >> 4) == 0 && /* delimiter = '0000' */
            ((key_block[i + 1] & 0x0f) == 0) &&
            (((key_block[i + 1] & 0xf0) >> 4) == 0)) {
          key_end_idx = i;
          break;
        }
      } else {
        if ((key_block[i] & 0xf0) >> 4 == 0 && /* delimiter == '0' */
            (key_block[i] & 0x0f) >> 0 == 0) {
          key_end_idx = i;
          break;
        }
      }

      i += width;
    }
    /// passed

    if (key_end_idx >= key_block_len) {
      key_end_idx = key_block_len;
    }

    std::string key_text = "";
    if (this->encoding == 1 /* ENCODING_UTF16 */) {
      std::string hex_input = be_bin_to_utf16(
          (const char *)key_block, static_cast<unsigned long>(key_start_idx + static_cast<size_t>(this->number_width)),
          static_cast<unsigned long>(key_end_idx - key_start_idx -
                                     static_cast<size_t>(this->number_width)));

      size_t utf16le_buf_size =
          (hex_input.length() / 2) +
          1;
      unsigned char *utf16le_bytes = (unsigned char *)malloc(utf16le_buf_size);
      if (!utf16le_bytes) {
        throw ResourceException(ResourceErrorCode::allocationFailed);
      }

      ssize_t utf16_bytes_written =
          hex_to_bytes(hex_input.c_str(), utf16le_bytes, utf16le_buf_size);
      if (utf16_bytes_written < 0) {
        free(utf16le_bytes);
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }

      size_t utf8_buf_size = ((size_t)utf16_bytes_written * 3) + 1;
      unsigned char *utf8_output = (unsigned char *)malloc(utf8_buf_size);
      if (!utf8_output) {
        free(utf16le_bytes);
        throw ResourceException(ResourceErrorCode::allocationFailed);
      }

      ssize_t utf8_bytes_written =
          utf16le_to_utf8(utf16le_bytes, (size_t)utf16_bytes_written,
                          utf8_output, utf8_buf_size);

      if (utf8_bytes_written < 0) {
        free(utf16le_bytes);
        free(utf8_output);
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }

      key_text = std::string(reinterpret_cast<char *>(utf8_output),
                             static_cast<size_t>(utf8_bytes_written));
      free(utf16le_bytes);
      free(utf8_output);

    } else if (this->encoding == 0 /* ENCODING_UTF8 */) {
      key_text = be_bin_to_utf8(
          (const char *)key_block, static_cast<unsigned long>(key_start_idx + static_cast<size_t>(this->number_width)),
          static_cast<unsigned long>(key_end_idx - key_start_idx -
                                     static_cast<size_t>(this->number_width)));
    }
    inner_key_list.push_back(new key_list_item(record_start, key_text));

    key_start_idx = key_end_idx + width;
  }
  return inner_key_list;
}

/**
 * decode key block info by block id use with reduce function
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

  // D1b-3A-2A: validate comp_size >= 8 (includes 8-byte prefix).
  if (comp_size < 8) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
  uint64_t payloadLen = checkedSubtractUInt64(comp_size, 8ULL);

  char *key_block_buffer =
      (char *)calloc(checkedUInt64ToSizeT(comp_size), sizeof(unsigned char));
  if (!key_block_buffer)
    throw ResourceException(ResourceErrorCode::allocationFailed);

  readfile(start_ofset, comp_size, key_block_buffer);

  // 4 bytes comp type
  char *key_block_comp_type = (char *)calloc(4, sizeof(char));
  if (!key_block_comp_type) {
    std::free(key_block_buffer);
    throw ResourceException(ResourceErrorCode::allocationFailed);
  }
  memcpy(key_block_comp_type, key_block_buffer, 4 * sizeof(char));
  // 4 bytes adler checksum of decompressed key block
  uint32_t chksum =
      be_bin_to_u32((unsigned char *)key_block_buffer + 4 * sizeof(char));

  unsigned char *key_block = nullptr;
  std::vector<uint8_t> kb_uncompressed;

  if ((key_block_comp_type[0] & 255) == 0) {
    // none compressed
    key_block = (unsigned char *)(key_block_buffer + 8 * sizeof(char));
  } else if ((key_block_comp_type[0] & 255) == 1) {
    // TODO lzo decompress
    std::free(key_block_comp_type);
    std::free(key_block_buffer);
    throw ResourceException(ResourceErrorCode::invalidCompressionType);

  } else if ((key_block_comp_type[0] & 255) == 2) {
    // zlib compress
    // D1b-3A-2A: use bounded exact zlib decompression with payload length.
    kb_uncompressed =
        boundedExactZlibDecompress(key_block_buffer + 8 * sizeof(char),
                                   checkedUInt64ToSizeT(payloadLen),
                                   checkedUInt64ToSizeT(decomp_size));
    key_block = kb_uncompressed.data();

    uint32_t adler32cs =
        adler32checksum(key_block, static_cast<uint32_t>(decomp_size));
    // D1b-3A-2A: runtime checksum validation (was assert).
    if (adler32cs != chksum) {
      std::free(key_block_comp_type);
      std::free(key_block_buffer);
      throw ResourceException(ResourceErrorCode::checksumMismatch);
    }
  } else {
    std::free(key_block_comp_type);
    std::free(key_block_buffer);
    throw ResourceException(ResourceErrorCode::invalidCompressionType);
  }

  std::free(key_block_comp_type);
  std::free(key_block_buffer);

  // split key
  std::vector<key_list_item *> tlist =
      split_key_block(key_block, decomp_size, idx);
  return tlist;
}

/**
 * decode the key block decode function, will invoke split key block
 *
 * this is for key block (not key block info)
 *
 * @param key_block_buffer
 * @param kb_buff_len
 * @return
 */
int Mdict::decode_key_block(unsigned char *key_block_buffer,
                            unsigned long kb_buff_len) {
  size_t i = 0;

  for (size_t idx = 0; idx < this->key_block_info_list.size(); idx++) {
    uint64_t comp_size =
        this->key_block_info_list[idx]->key_block_comp_size;
    uint64_t decomp_size =
        this->key_block_info_list[idx]->key_block_decomp_size;
    size_t start_ofset = i;

    // D1b-3A-2A: validate comp_size >= 8 (includes 8-byte prefix).
    if (comp_size < 8) {
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

    // 4 bytes comp type
    char *key_block_comp_type = (char *)calloc(4, sizeof(char));
    if (!key_block_comp_type)
      throw ResourceException(ResourceErrorCode::allocationFailed);
    memcpy(key_block_comp_type, key_block_buffer + start_ofset, 4 * sizeof(char));
    // 4 bytes adler checksum of decompressed key block
    uint32_t chksum =
        be_bin_to_u32(key_block_buffer + start_ofset + 4 * sizeof(char));

    unsigned char *key_block = nullptr;

    std::vector<uint8_t> kb_uncompressed;

    if ((key_block_comp_type[0] & 255) == 0) {
      // none compressed
      key_block = key_block_buffer + start_ofset + 8 * sizeof(char);
      // For uncompressed, decomp_size should match payload
    } else if ((key_block_comp_type[0] & 255) == 1) {
      // TODO lzo decompress
      std::free(key_block_comp_type);
      throw ResourceException(ResourceErrorCode::invalidCompressionType);

    } else if ((key_block_comp_type[0] & 255) == 2) {
      // zlib compress
      // D1b-3A-2A: use bounded exact zlib decompression with payload length.
      kb_uncompressed =
          boundedExactZlibDecompress(key_block_buffer + start_ofset + 8,
                                     checkedUInt64ToSizeT(payloadLen),
                                     checkedUInt64ToSizeT(decomp_size));
      key_block = kb_uncompressed.data();

      uint32_t adler32cs =
          adler32checksum(key_block, static_cast<uint32_t>(decomp_size));
      // D1b-3A-2A: runtime checksum validation (was assert).
      if (adler32cs != chksum) {
        std::free(key_block_comp_type);
        throw ResourceException(ResourceErrorCode::checksumMismatch);
      }
    } else {
      std::free(key_block_comp_type);
      throw ResourceException(ResourceErrorCode::invalidCompressionType);
    }

    std::free(key_block_comp_type);

    // split key
    std::vector<key_list_item *> tlist =
        split_key_block(key_block, decomp_size, idx);
    key_list.insert(key_list.end(), tlist.begin(), tlist.end());

    // next round — checked cumulative addition
    i = checkedAddUInt64(static_cast<uint64_t>(i), comp_size);
    if (i > kb_buff_len) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
  }

  // D1b-3A-2A: runtime validation (was assert).
  if (key_list.size() != this->entries_num) {
    throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
  }
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
  if (this->version >= 2.0) {
    record_block_info_size = 4 * 8;
  } else {
    record_block_info_size = 4 * 4;
  }

  char *record_info_buffer =
      (char *)calloc(record_block_info_size, sizeof(char));

  this->readfile(record_block_info_offset, record_block_info_size,
                 record_info_buffer);

  if (this->version >= 2.0) {
    record_block_number = be_bin_to_u64((unsigned char *)record_info_buffer);
    record_block_entries_number = be_bin_to_u64(
        (unsigned char *)record_info_buffer + number_width * sizeof(char));
    record_block_header_size = be_bin_to_u64(
        (unsigned char *)record_info_buffer + 2 * number_width * sizeof(char));
    record_block_size = be_bin_to_u64((unsigned char *)record_info_buffer +
                                      3 * number_width * sizeof(char));
  }

  free(record_info_buffer);
  assert(record_block_entries_number == entries_num);
  /// passed

  /**
   * record_block_header_list:
   * {
   *     compressed size
   *     decompressed size
   * }
   */

  char *record_header_buffer =
      (char *)calloc(record_block_header_size, sizeof(char));

  this->readfile(this->record_block_info_offset + record_block_info_size,
                 record_block_header_size, record_header_buffer);

  unsigned long comp_size = 0l;
  unsigned long uncomp_size = 0l;
  unsigned long size_counter = 0l;

  unsigned long comp_accu = 0l;
  unsigned long decomp_accu = 0l;

  for (unsigned long i = 0; i < record_block_number; ++i) {
    if (this->version >= 2.0) {
      comp_size =
          be_bin_to_u64((unsigned char *)(record_header_buffer + size_counter));
      size_counter += number_width;
      uncomp_size =
          be_bin_to_u64((unsigned char *)(record_header_buffer + size_counter));
      size_counter += number_width;

      this->record_header.push_back(new record_header_item(
          i, comp_size, uncomp_size, comp_accu, decomp_accu));
      // ensure after push
      comp_accu += comp_size;
      decomp_accu += uncomp_size;
    } else {
      // TODO
    }
  }

  free(record_header_buffer);
  assert(this->record_header.size() == this->record_block_number);
  assert(size_counter == this->record_block_header_size);

  record_block_offset = record_block_info_offset + record_block_info_size +
                        record_block_header_size;
  /// passed
  return 0;
}

std::vector<std::pair<std::string, std::string>>
Mdict::decode_record_block_by_rid(unsigned long rid /* record id */) {
  // record block start offset: record_block_offset
  uint64_t record_offset = this->record_block_offset;

  // key list index counter
  unsigned long i = 0l;

  std::vector<uint8_t> record_block_uncompressed_v;
  unsigned char *record_block_uncompressed_b;
  uint64_t checksum = 0l;

  unsigned long idx = rid;

  //  for (int idx = 0; idx < this->record_header.size(); idx++) {
  uint64_t comp_size = record_header[idx]->compressed_size;
  uint64_t uncomp_size = record_header[idx]->decompressed_size;
  uint64_t comp_accu = record_header[idx]->compressed_size_accumulator;
  uint64_t decomp_accu = record_header[idx]->decompressed_size_accumulator;
  uint64_t previous_end = 0;
  uint64_t previous_uncomp_size = 0;
  if (idx > 0) {
    previous_end = record_header[idx - 1]->decompressed_size_accumulator;
    previous_uncomp_size = record_header[idx - 1]->decompressed_size;
  }

  char *record_block_cmp_buffer = (char *)calloc(comp_size, sizeof(char));

  this->readfile(record_offset + comp_accu, comp_size, record_block_cmp_buffer);
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

  if (comp_type == 0 /* not compressed */) {
    if (comp_size < 8 || comp_size - 8 != uncomp_size) {
      throw std::runtime_error("invalid uncompressed record block size");
    }
    record_block_uncompressed_v.assign(
        reinterpret_cast<unsigned char *>(record_block_cmp_buffer + 8),
        reinterpret_cast<unsigned char *>(record_block_cmp_buffer + comp_size));
    record_block_uncompressed_b = record_block_uncompressed_v.data();
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
      uint32_t adler32cs = adler32checksum(record_block_uncompressed_b,
                                           static_cast<uint32_t>(uncomp_size));
      assert(record_block_uncompressed_v.size() == uncomp_size);
      assert(adler32cs == checksum);
    } else {
      throw std::runtime_error(
          "cannot determine the record block compress type");
    }
  }

  free(comp_type_b);
  free(record_block_cmp_buffer);
  //    free(record_block_uncompressed_b); /* ensure not free twice*/

  unsigned char *record_block = record_block_uncompressed_b;
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
  return 0;
}

/**
 * decode the key block info
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
  (void)key_block_num; (void)entries_num;
  char *kb_info_buff = key_block_info_buffer;

  // key block info offset indicator
  size_t data_offset = 0;

  if (this->version >= 2.0) {
    // if version >= 2.0, use zlib compression
    // D1b-3A-2A: runtime validation instead of assert.
    if (kb_info_buff[0] != 2 || kb_info_buff[1] != 0 ||
        kb_info_buff[2] != 0 || kb_info_buff[3] != 0) {
      throw ResourceException(ResourceErrorCode::invalidCompressionType);
    }

    // D1b-3A-2A: validate kb_info_buff_len >= 8 before subtracting prefix
    if (kb_info_buff_len < 8) {
      throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
    }
    uint64_t payloadLen = checkedSubtractUInt64(kb_info_buff_len, 8ULL);

    byte *kb_info_decrypted = (unsigned char *)key_block_info_buffer;
    if (this->encrypt == ENCRYPT_KEY_INFO_ENC) {
      kb_info_decrypted = mdx_decrypt((byte *)kb_info_buff,
                                       static_cast<int>(kb_info_buff_len));
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
      if (key_block_compress_size == 0 || key_block_decompress_size == 0) {
        throw ResourceException(ResourceErrorCode::malformedKeyBlockMetadata);
      }
      if (key_block_compress_size > limits_.maximumSingleKeyBlockCompressedBytes) {
        throw ResourceException(ResourceErrorCode::singleKeyBlockCompressedTooLarge);
      }
      if (key_block_decompress_size > limits_.maximumSingleKeyBlockDecompressedBytes) {
        throw ResourceException(ResourceErrorCode::singleKeyBlockDecompressedTooLarge);
      }

      key_block_info *kbinfo = new key_block_info(
          first_key, last_key, previous_start_offset, key_block_compress_size,
          key_block_decompress_size, comp_acc, decomp_acc);

      // adjust offset
      previous_start_offset = checkedAddUInt64(previous_start_offset, key_block_compress_size);
      key_block_info_list.push_back(kbinfo);

      // key block counter
      counter = checkedAddUInt64(counter, 1ULL);
      // D1b-3A-2A: fix I10 — checked cumulative addition.
      comp_acc = checkedAddUInt64(comp_acc, key_block_compress_size);
      decomp_acc = checkedAddUInt64(decomp_acc, key_block_decompress_size);
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

  // D1b-3A-2A: obtain actual file size from the same stream (TOCTOU-safe).
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

  // D1b-3A-2A: obtain actual file size from the same stream (TOCTOU-safe).
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
  return last->decompressed_size_accumulator + last->decompressed_size;
}

std::vector<uint8_t> Mdict::readRecordBlockBytes(uint64_t block_id) {
  if (block_id >= record_header.size()) {
    throw std::out_of_range("record block id out of range");
  }
  const auto *header = record_header[block_id];
  const uint64_t comp_size = header->compressed_size;
  if (comp_size < 8) throw std::runtime_error("invalid record block size");

  std::vector<uint8_t> compressed(comp_size);
  readfile(record_block_offset + header->compressed_size_accumulator,
           comp_size, reinterpret_cast<char *>(compressed.data()));

  const int comp_type = compressed[0] & 0xff;
  const uint32_t expected_checksum = be_bin_to_u32(compressed.data() + 4);
  std::vector<uint8_t> output;
  if (comp_type == 0) {
    output.assign(compressed.begin() + 8, compressed.end());
  } else if (comp_type == 1) {
    throw std::runtime_error("LZO record blocks are not supported");
  } else if (comp_type == 2) {
    output = zlib_mem_uncompress(compressed.data() + 8, comp_size - 8,
                                 header->decompressed_size);
  } else {
    throw std::runtime_error("unknown record block compression type");
  }

  if (output.size() != header->decompressed_size) {
    throw std::runtime_error("record block decompressed size mismatch");
  }
  if (adler32checksum(output.data(), static_cast<uint32_t>(output.size())) !=
      expected_checksum) {
    throw std::runtime_error("record block checksum mismatch");
  }
  return output;
}

std::string Mdict::readRecordAt(uint64_t record_start, uint64_t record_end) {
  if (filetype != "MDX") {
    throw std::runtime_error("readRecordAt is limited to MDX text records");
  }
  if (encoding != 0 /* ENCODING_UTF8 */) {
    throw std::runtime_error("phase 2 supports UTF-8 MDX records only");
  }
  const uint64_t stream_size = recordStreamSize();
  if (record_start >= record_end || record_end > stream_size) return {};

  std::string result;
  result.reserve(static_cast<size_t>(record_end - record_start));
  uint64_t cursor = record_start;
  while (cursor < record_end) {
    const uint64_t block_id = reduce_record_block_offset(cursor);
    const auto *header = record_header.at(block_id);
    const uint64_t block_start = header->decompressed_size_accumulator;
    const uint64_t block_end = block_start + header->decompressed_size;
    const auto bytes = readRecordBlockBytes(block_id);
    const uint64_t local_start = cursor - block_start;
    const uint64_t copy_end = std::min(record_end, block_end);
    const uint64_t local_end = copy_end - block_start;
    result.append(reinterpret_cast<const char *>(bytes.data() + local_start),
                  static_cast<size_t>(local_end - local_start));
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
  // TODO OPTIMISE
  unsigned long left = 0l;
  unsigned long right = this->record_header.size() - 1;
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
  return 0;
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
