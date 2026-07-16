#include "RIPEMD128Adapter.h"

#include <limits.h>
#include <string.h>

#include "tomcrypt.h"

typedef struct LDRIPEMD128InternalContext {
  hash_state state;
  uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH];
  uint8_t initialized;
  uint8_t finalized;
} LDRIPEMD128InternalContext;

_Static_assert(sizeof(LDRIPEMD128InternalContext) <=
                   sizeof(LDRIPEMD128Context),
               "LDRIPEMD128Context storage is too small");
_Static_assert(_Alignof(LDRIPEMD128InternalContext) <=
                   _Alignof(LDRIPEMD128Context),
               "LDRIPEMD128Context alignment is insufficient");

static LDRIPEMD128InternalContext *internal_context(
    LDRIPEMD128Context *context) {
  return (LDRIPEMD128InternalContext *)context->storage;
}

int ld_ripemd128_init(LDRIPEMD128Context *context) {
  if (context == NULL) return LD_RIPEMD128_INVALID_ARGUMENT;
  memset(context, 0, sizeof(*context));
  LDRIPEMD128InternalContext *internal = internal_context(context);
  if (rmd128_init(&internal->state) != CRYPT_OK) {
    return LD_RIPEMD128_INTERNAL_ERROR;
  }
  internal->initialized = 1;
  return LD_RIPEMD128_OK;
}

int ld_ripemd128_update(LDRIPEMD128Context *context, const uint8_t *bytes,
                        size_t length) {
  if (context == NULL || (bytes == NULL && length != 0)) {
    return LD_RIPEMD128_INVALID_ARGUMENT;
  }
  LDRIPEMD128InternalContext *internal = internal_context(context);
  if (!internal->initialized) return LD_RIPEMD128_INVALID_ARGUMENT;
  if (internal->finalized) return LD_RIPEMD128_ALREADY_FINALIZED;

  while (length != 0) {
    const unsigned long chunk =
        length > (size_t)ULONG_MAX ? ULONG_MAX : (unsigned long)length;
    if (rmd128_process(&internal->state, bytes, chunk) != CRYPT_OK) {
      return LD_RIPEMD128_INTERNAL_ERROR;
    }
    bytes += chunk;
    length -= chunk;
  }
  return LD_RIPEMD128_OK;
}

int ld_ripemd128_final(LDRIPEMD128Context *context,
                       uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH]) {
  if (context == NULL || digest == NULL) {
    return LD_RIPEMD128_INVALID_ARGUMENT;
  }
  LDRIPEMD128InternalContext *internal = internal_context(context);
  if (!internal->initialized) return LD_RIPEMD128_INVALID_ARGUMENT;
  if (!internal->finalized) {
    if (rmd128_done(&internal->state, internal->digest) != CRYPT_OK) {
      return LD_RIPEMD128_INTERNAL_ERROR;
    }
    internal->finalized = 1;
  }
  memcpy(digest, internal->digest, LD_RIPEMD128_DIGEST_LENGTH);
  return LD_RIPEMD128_OK;
}

int ld_ripemd128_digest(const uint8_t *bytes, size_t length,
                        uint8_t digest[LD_RIPEMD128_DIGEST_LENGTH]) {
  if (bytes == NULL && length != 0) return LD_RIPEMD128_INVALID_ARGUMENT;
  LDRIPEMD128Context context;
  int result = ld_ripemd128_init(&context);
  if (result == LD_RIPEMD128_OK) {
    result = ld_ripemd128_update(&context, bytes, length);
  }
  if (result == LD_RIPEMD128_OK) {
    result = ld_ripemd128_final(&context, digest);
  }
  memset(&context, 0, sizeof(context));
  return result;
}
