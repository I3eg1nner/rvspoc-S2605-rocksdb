#include <stdio.h>
long test_zba(long a, long b){ long r; asm("sh3add %0,%1,%2":"=r"(r):"r"(a),"r"(b)); return r; }
long test_zbb(long a){ long r; asm("ctz %0,%1":"=r"(r):"r"(a)); return r; }
long test_zbs(long a){ long r; asm("bexti %0,%1,3":"=r"(r):"r"(a)); return r; }
long test_zicond(long a, long b){ long r; asm("czero.eqz %0,%1,%2":"=r"(r):"r"(a),"r"(b)); return r; }
long test_prefetch(void* p){ asm("prefetch.r 0(%0)"::"r"(p)); return 0; }
int main(int argc, char**argv){
  volatile long x=0x1234;
  switch(argv[1][0]){
    case 'a': printf("zba ok %ld\n", test_zba(x,x)); break;
    case 'b': printf("zbb ok %ld\n", test_zbb(x)); break;
    case 's': printf("zbs ok %ld\n", test_zbs(x)); break;
    case 'c': printf("zicond ok %ld\n", test_zicond(x,x)); break;
    case 'p': printf("prefetch ok %ld\n", test_prefetch((void*)&x)); break;
  }
  return 0;
}
