// Reference side of the XXPH3 differential: force the scalar path.
// xxph3.h self-defines XXPH_INLINE_ALL (all static) - no symbol clash.
#define XXPH_VECTOR 0 /* XXPH_SCALAR */
#include "util/xxph3.h"

extern "C" {
unsigned long long RefXXPH3_64(const void* p, size_t n, unsigned long long s) {
  return XXPH3_64bits_withSeed(p, n, s);
}
unsigned long long RefXXPH3_64ns(const void* p, size_t n) {
  return XXPH3_64bits(p, n);
}
}
