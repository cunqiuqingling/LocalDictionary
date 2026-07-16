#include "RIPEMD128Adapter.h"

#include <stdio.h>
#include <string.h>

typedef struct TestVector {
  const char *input;
  const char *expected;
} TestVector;

static void hex_digest(const uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH],
                       char output[LD_RIPEMD128_DIGEST_LENGTH * 2 + 1]) {
  static const char digits[] = "0123456789abcdef";
  for (size_t index = 0; index < LD_RIPEMD128_DIGEST_LENGTH; ++index) {
    output[index * 2] = digits[digest[index] >> 4];
    output[index * 2 + 1] = digits[digest[index] & 0x0f];
  }
  output[LD_RIPEMD128_DIGEST_LENGTH * 2] = '\0';
}

static int expect_digest(const char *input, const char *expected) {
  uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH];
  char actual[LD_RIPEMD128_DIGEST_LENGTH * 2 + 1];
  if (ld_ripemd128_digest((const uint8_t *)input, strlen(input), digest) !=
      LD_RIPEMD128_OK) {
    return 0;
  }
  hex_digest(digest, actual);
  return strcmp(actual, expected) == 0;
}

static int expect_segmented_matches_one_shot(void) {
  uint8_t input[257];
  for (size_t index = 0; index < sizeof(input); ++index) {
    input[index] = (uint8_t)((index * 37U + 11U) & 0xffU);
  }

  uint8_t one_shot[LD_RIPEMD128_DIGEST_LENGTH];
  uint8_t segmented[LD_RIPEMD128_DIGEST_LENGTH];
  if (ld_ripemd128_digest(input, sizeof(input), one_shot) !=
      LD_RIPEMD128_OK) {
    return 0;
  }

  LDRIPEMD128Context context;
  if (ld_ripemd128_init(&context) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&context, input, 1) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&context, input + 1, 63) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&context, input + 64, 129) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&context, input + 193, 64) != LD_RIPEMD128_OK ||
      ld_ripemd128_final(&context, segmented) != LD_RIPEMD128_OK) {
    return 0;
  }
  return memcmp(one_shot, segmented, sizeof(one_shot)) == 0;
}

static int expect_context_isolation_and_repeat_final(void) {
  const uint8_t first[] = {'a', 'b', 'c'};
  const uint8_t second[] = "message digest";
  LDRIPEMD128Context first_context;
  LDRIPEMD128Context second_context;
  uint8_t first_digest[LD_RIPEMD128_DIGEST_LENGTH];
  uint8_t first_repeat[LD_RIPEMD128_DIGEST_LENGTH];
  uint8_t second_digest[LD_RIPEMD128_DIGEST_LENGTH];

  if (ld_ripemd128_init(&first_context) != LD_RIPEMD128_OK ||
      ld_ripemd128_init(&second_context) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&first_context, first, 1) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&second_context, second, 7) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&first_context, first + 1, 2) != LD_RIPEMD128_OK ||
      ld_ripemd128_update(&second_context, second + 7,
                          sizeof(second) - 1 - 7) != LD_RIPEMD128_OK ||
      ld_ripemd128_final(&first_context, first_digest) != LD_RIPEMD128_OK ||
      ld_ripemd128_final(&second_context, second_digest) != LD_RIPEMD128_OK ||
      ld_ripemd128_final(&first_context, first_repeat) != LD_RIPEMD128_OK) {
    return 0;
  }
  if (memcmp(first_digest, first_repeat, sizeof(first_digest)) != 0) return 0;
  if (ld_ripemd128_update(&first_context, first, sizeof(first)) !=
      LD_RIPEMD128_ALREADY_FINALIZED) {
    return 0;
  }

  char first_hex[LD_RIPEMD128_DIGEST_LENGTH * 2 + 1];
  char second_hex[LD_RIPEMD128_DIGEST_LENGTH * 2 + 1];
  hex_digest(first_digest, first_hex);
  hex_digest(second_digest, second_hex);
  return strcmp(first_hex, "c14a12199c66e4ba84636b0f69144c77") == 0 &&
         strcmp(second_hex, "9e327b3d6e523062afc1132d7df9d1b8") == 0;
}

int main(void) {
  static const TestVector vectors[] = {
      {"", "cdf26213a150dc3ecb610f18f6b38b46"},
      {"a", "86be7afa339d0fc7cfc785e72f578d33"},
      {"abc", "c14a12199c66e4ba84636b0f69144c77"},
      {"message digest", "9e327b3d6e523062afc1132d7df9d1b8"},
      {"abcdefghijklmnopqrstuvwxyz", "fd2aa607f71dc8f510714922b371834e"},
  };

  if (LD_RIPEMD128_DIGEST_LENGTH != 16) {
    fputs("RIPEMD-128 digest length failed\n", stderr);
    return 1;
  }
  for (size_t index = 0; index < sizeof(vectors) / sizeof(vectors[0]);
       ++index) {
    if (!expect_digest(vectors[index].input, vectors[index].expected)) {
      fprintf(stderr, "RIPEMD-128 vector %zu failed\n", index);
      return 1;
    }
  }
  if (!expect_segmented_matches_one_shot()) {
    fputs("RIPEMD-128 segmented update failed\n", stderr);
    return 1;
  }
  if (!expect_context_isolation_and_repeat_final()) {
    fputs("RIPEMD-128 context isolation failed\n", stderr);
    return 1;
  }

  puts("RIPEMD-128 smoke passed");
  return 0;
}
