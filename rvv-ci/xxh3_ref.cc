// Reference side of the XXH3 differential: force the scalar path.
#define XXH_INLINE_ALL
#define XXH_VECTOR 0 /* XXH_SCALAR */
#include "util/xxhash.h"

extern "C" {
unsigned long long RefXXH3_64(const void* p, size_t n, unsigned long long s) {
  return XXH3_64bits_withSeed(p, n, s);
}
void RefXXH3_128(const void* p, size_t n, unsigned long long s,
                 unsigned long long out[2]) {
  XXH128_hash_t h = XXH3_128bits_withSeed(p, n, s);
  out[0] = h.low64;
  out[1] = h.high64;
}
}
