#include "miniz.h"

#include <stdio.h>
#include <string.h>

int main(void) {
  static const unsigned char input[] =
      "LocalDictionary miniz compatibility fixture. "
      "LocalDictionary miniz compatibility fixture.";
  unsigned char compressed[256];
  unsigned char output[sizeof(input)];
  mz_ulong compressed_length = sizeof(compressed);
  mz_ulong output_length = sizeof(output);

  if (mz_compress(compressed, &compressed_length, input, sizeof(input)) !=
      MZ_OK) {
    fputs("miniz compression setup failed\n", stderr);
    return 1;
  }
  if (mz_uncompress(output, &output_length, compressed, compressed_length) !=
      MZ_OK) {
    fputs("miniz decompression failed\n", stderr);
    return 1;
  }
  if (output_length != sizeof(input) ||
      memcmp(input, output, sizeof(input)) != 0) {
    fputs("miniz round trip mismatch\n", stderr);
    return 1;
  }

  output_length = sizeof(output);
  if (mz_uncompress(output, &output_length, compressed,
                    compressed_length / 2) == MZ_OK) {
    fputs("miniz accepted truncated input\n", stderr);
    return 1;
  }

  puts("miniz decompression smoke passed");
  return 0;
}
