#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LD_RIPEMD128_DIGEST_LENGTH 16

enum {
  LD_RIPEMD128_OK = 0,
  LD_RIPEMD128_INVALID_ARGUMENT = -1,
  LD_RIPEMD128_ALREADY_FINALIZED = -2,
  LD_RIPEMD128_INTERNAL_ERROR = -3
};

/* Opaque, naturally aligned storage for the project-local streaming wrapper. */
typedef union LDRIPEMD128Context {
  max_align_t alignment;
  unsigned char storage[128];
} LDRIPEMD128Context;

int ld_ripemd128_init(LDRIPEMD128Context *context);
int ld_ripemd128_update(LDRIPEMD128Context *context, const uint8_t *bytes,
                        size_t length);
int ld_ripemd128_final(LDRIPEMD128Context *context,
                       uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH]);
int ld_ripemd128_digest(const uint8_t *bytes, size_t length,
                        uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH]);

#ifdef __cplusplus
}
#endif
