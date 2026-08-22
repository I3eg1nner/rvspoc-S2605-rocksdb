// RVV rig smoke test: verifies vsetvl/vlenb under each QEMU VLEN and
// that the cross toolchain accepts rv64gcv_zvbc. Pass criteria:
// vlenb printed = VLEN/8 (16/32/64) and vl_e8m1 = VLEN/8.
#include <riscv_vector.h>
#include <stdio.h>

int main(void) {
  unsigned long vlenb;
  __asm__("csrr %0, vlenb" : "=r"(vlenb));
  size_t vl = __riscv_vsetvl_e8m1(4096);
  // touch a zvbc instruction so the rig proves the extension compiles+executes
  vuint64m1_t a = __riscv_vmv_v_x_u64m1(0x1234567890abcdefUL, 1);
  vuint64m1_t b = __riscv_vclmul_vx_u64m1(a, 3, 1);
  unsigned long r = __riscv_vmv_x_s_u64m1_u64(b);
  printf("vlenb=%lu vl_e8m1=%zu vclmul=%lx\n", vlenb, vl, r);
  return 0;
}
