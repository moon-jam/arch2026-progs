# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.
#
# Leaf function, no stack frame. Registers:
#   a0  a, odd inside the loop       a1  b
#   a2  k, shared factors of two     t0  value under ctz, t1 count, t2 scratch

    .text

# CTZ x, n: n = count of trailing zeros of nonzero x; x is clobbered.
# Binary search over the bit position, as in gcd.c.
    .macro  CTZ x, n
    li      \n, 0
    slli    t2, \x, 16          # low 16 bits zero? (0xFFFF does not fit andi)
    bnez    t2, 1f
    addi    \n, \n, 16
    srli    \x, \x, 16
1:
    andi    t2, \x, 0xFF
    bnez    t2, 2f
    addi    \n, \n, 8
    srli    \x, \x, 8
2:
    andi    t2, \x, 0xF
    bnez    t2, 3f
    addi    \n, \n, 4
    srli    \x, \x, 4
3:
    andi    t2, \x, 0x3
    bnez    t2, 4f
    addi    \n, \n, 2
    srli    \x, \x, 2
4:
    not     t2, \x
    andi    t2, t2, 1           # one of the two low bits is set
    add     \n, \n, t2
    .endm

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    beqz    a0, .Lret_b         # gcd(0, b) = b
    beqz    a1, .Lret           # gcd(a, 0) = a

    or      t0, a0, a1          # k = ctz(a | b)
    CTZ     t0, a2
    mv      t0, a0              # a >>= ctz(a)
    CTZ     t0, t1
    srl     a0, a0, t1
.Lloop:
    mv      t0, a1              # b >>= ctz(b)
    CTZ     t0, t1
    srl     a1, a1, t1
    bgeu    a1, a0, .Lnoswap    # if (a > b) swap; unsigned compare
    mv      t0, a0
    mv      a0, a1
    mv      a1, t0
.Lnoswap:
    sub     a1, a1, a0          # b -= a
    bnez    a1, .Lloop
    sll     a0, a0, a2          # restore the shared twos
.Lret:
    ret
.Lret_b:
    mv      a0, a1
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
