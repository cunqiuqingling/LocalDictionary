/*
 * LocalDictionary's minimal LibTomCrypt compatibility header.
 *
 * This file intentionally exposes only the types and macros required by
 * LibTomCrypt v1.18.2 src/hashes/rmd128.c. The definitions are derived from
 * that release's tomcrypt.h, tomcrypt_cfg.h, tomcrypt_hash.h and
 * tomcrypt_macros.h. LibTomCrypt's original license is in ../LICENSE.
 */
#ifndef LOCALDICTIONARY_MINIMAL_TOMCRYPT_H
#define LOCALDICTIONARY_MINIMAL_TOMCRYPT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LTC_RIPEMD128

typedef uint32_t ulong32;
typedef uint64_t ulong64;

enum {
  CRYPT_OK = 0,
  CRYPT_NOP = 2,
  CRYPT_FAIL_TESTVECTOR = 5,
  CRYPT_INVALID_ARG = 16,
  CRYPT_HASH_OVERFLOW = 24
};

struct rmd128_state {
  ulong64 length;
  unsigned char buf[64];
  ulong32 curlen;
  ulong32 state[4];
};

typedef union Hash_state {
  struct rmd128_state rmd128;
} hash_state;

struct ltc_hash_descriptor {
  const char *name;
  unsigned char ID;
  unsigned long hashsize;
  unsigned long blocksize;
  unsigned long OID[16];
  unsigned long OIDlen;
  int (*init)(hash_state *hash);
  int (*process)(hash_state *hash, const unsigned char *in,
                 unsigned long inlen);
  int (*done)(hash_state *hash, unsigned char *out);
  int (*test)(void);
  int (*hmac_block)(const unsigned char *key, unsigned long keylen,
                    const unsigned char *in, unsigned long inlen,
                    unsigned char *out, unsigned long *outlen);
};

int rmd128_init(hash_state *md);
int rmd128_process(hash_state *md, const unsigned char *in,
                   unsigned long inlen);
int rmd128_done(hash_state *md, unsigned char *hash);
int rmd128_test(void);
extern const struct ltc_hash_descriptor rmd128_desc;

#define LTC_ARGCHK(condition)             \
  do {                                    \
    if (!(condition)) return CRYPT_INVALID_ARG; \
  } while (0)

#define XMEMCPY memcpy
#define MIN(x, y) (((x) < (y)) ? (x) : (y))

#define STORE32L(x, y)                                                    \
  do {                                                                    \
    (y)[3] = (unsigned char)(((x) >> 24) & 255);                          \
    (y)[2] = (unsigned char)(((x) >> 16) & 255);                          \
    (y)[1] = (unsigned char)(((x) >> 8) & 255);                           \
    (y)[0] = (unsigned char)((x) & 255);                                  \
  } while (0)

#define LOAD32L(x, y)                                                     \
  do {                                                                    \
    (x) = ((ulong32)((y)[3] & 255) << 24) |                              \
          ((ulong32)((y)[2] & 255) << 16) |                              \
          ((ulong32)((y)[1] & 255) << 8) |                               \
          ((ulong32)((y)[0] & 255));                                      \
  } while (0)

#define STORE64L(x, y)                                                    \
  do {                                                                    \
    (y)[7] = (unsigned char)(((x) >> 56) & 255);                          \
    (y)[6] = (unsigned char)(((x) >> 48) & 255);                          \
    (y)[5] = (unsigned char)(((x) >> 40) & 255);                          \
    (y)[4] = (unsigned char)(((x) >> 32) & 255);                          \
    (y)[3] = (unsigned char)(((x) >> 24) & 255);                          \
    (y)[2] = (unsigned char)(((x) >> 16) & 255);                          \
    (y)[1] = (unsigned char)(((x) >> 8) & 255);                           \
    (y)[0] = (unsigned char)((x) & 255);                                  \
  } while (0)

#define ROLc(x, y)                                                        \
  ((((ulong32)(x) << (ulong32)((y) & 31)) |                              \
    (((ulong32)(x) & 0xFFFFFFFFUL) >>                                    \
     (ulong32)((32 - ((y) & 31)) & 31))) &                               \
   0xFFFFFFFFUL)

#define HASH_PROCESS(func_name, compress_name, state_var, block_size)     \
  int func_name(hash_state *md, const unsigned char *in,                  \
                unsigned long inlen) {                                    \
    unsigned long n;                                                       \
    int err;                                                               \
    LTC_ARGCHK(md != NULL);                                                \
    LTC_ARGCHK(in != NULL);                                                \
    if (md->state_var.curlen > sizeof(md->state_var.buf)) {               \
      return CRYPT_INVALID_ARG;                                            \
    }                                                                      \
    if ((md->state_var.length + inlen) < md->state_var.length) {          \
      return CRYPT_HASH_OVERFLOW;                                          \
    }                                                                      \
    while (inlen > 0) {                                                    \
      if (md->state_var.curlen == 0 && inlen >= block_size) {             \
        if ((err = compress_name(md, (unsigned char *)in)) != CRYPT_OK) { \
          return err;                                                      \
        }                                                                  \
        md->state_var.length += block_size * 8;                            \
        in += block_size;                                                  \
        inlen -= block_size;                                               \
      } else {                                                             \
        n = MIN(inlen, (block_size - md->state_var.curlen));              \
        XMEMCPY(md->state_var.buf + md->state_var.curlen, in, (size_t)n); \
        md->state_var.curlen += n;                                         \
        in += n;                                                           \
        inlen -= n;                                                        \
        if (md->state_var.curlen == block_size) {                          \
          if ((err = compress_name(md, md->state_var.buf)) != CRYPT_OK) { \
            return err;                                                    \
          }                                                                \
          md->state_var.length += 8 * block_size;                          \
          md->state_var.curlen = 0;                                        \
        }                                                                  \
      }                                                                    \
    }                                                                      \
    return CRYPT_OK;                                                       \
  }

#ifdef __cplusplus
}
#endif

#endif
