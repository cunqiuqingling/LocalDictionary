#include "RIPEMD128Adapter.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace mdict {
unsigned char *mdx_decrypt(unsigned char *comp_block, int comp_block_len);
}

static void reference_fast_decrypt(unsigned char *data, size_t length,
                                   const uint8_t key[16]) {
  unsigned char previous = 0x36;
  for (size_t index = 0; index < length; ++index) {
    unsigned char transformed =
        static_cast<unsigned char>(((data[index] >> 4) | (data[index] << 4)) &
                                   0xff);
    transformed = static_cast<unsigned char>(
        transformed ^ previous ^ static_cast<unsigned char>(index & 0xff) ^
        key[index % 16]);
    previous = data[index];
    data[index] = transformed;
  }
}

int main() {
  std::array<unsigned char, 40> actual{};
  for (size_t index = 0; index < actual.size(); ++index) {
    actual[index] = static_cast<unsigned char>((index * 29U + 7U) & 0xffU);
  }
  auto expected = actual;

  const uint8_t key_input[8] = {actual[4], actual[5], actual[6], actual[7],
                                0x95,      0x36,      0x00,      0x00};
  uint8_t key[LD_RIPEMD128_DIGEST_LENGTH];
  if (ld_ripemd128_digest(key_input, sizeof(key_input), key) !=
      LD_RIPEMD128_OK) {
    std::fputs("MDict key derivation failed\n", stderr);
    return 1;
  }
  reference_fast_decrypt(expected.data() + 8, expected.size() - 8, key);

  if (mdict::mdx_decrypt(actual.data(), static_cast<int>(actual.size())) !=
          actual.data() ||
      std::memcmp(actual.data(), expected.data(), actual.size()) != 0) {
    std::fputs("MDict decrypt boundary mismatch\n", stderr);
    return 1;
  }

  std::array<unsigned char, 8> empty_payload = {0, 0, 0, 0, 1, 2, 3, 4};
  const auto before = empty_payload;
  if (mdict::mdx_decrypt(empty_payload.data(),
                         static_cast<int>(empty_payload.size())) !=
          empty_payload.data() ||
      empty_payload != before) {
    std::fputs("MDict empty decrypt boundary failed\n", stderr);
    return 1;
  }

  std::puts("MDict decrypt boundary smoke passed");
  return 0;
}
