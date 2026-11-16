# Arithmetic from logic and Q11.20 fixed point, hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)
# uint32_t op2_asm(uint32_t a, uint32_t b)
# uint32_t op3_asm(uint32_t a, uint32_t b)
# int32_t  q_mul_asm(int32_t a, int32_t b)
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. All four are leaf functions with no stack frame.
# Tests: tests/tfixed.c.

    .text

# op1_asm: a + b by XOR and carries, *n = number of passes.
#   a0  a, the partial sum     a1  b, the pending carries
#   a2  n                      t0  scratch, t1 pass count
    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    li      t1, 0
    beqz    a1, 2f              # no carry at all: zero passes
1:
    and     t0, a0, a1          # carries, one position too low
    xor     a0, a0, a1          # sum without the carries
    slli    a1, t0, 1           # carries move up one position
    addi    t1, t1, 1
    bnez    a1, 1b
2:
    sw      t1, 0(a2)
    ret
    .size   op1_asm, .-op1_asm

# op2_asm: a - b modulo 2^32.
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1
    ret
    .size   op2_asm, .-op2_asm

# op3_asm: floor((a + b) / 2) without overflow.
#   (a >> 1) + (b >> 1) + (a & b & 1)
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and     t0, a0, a1
    andi    t0, t0, 1           # both odd: the two dropped halves make one
    srli    a0, a0, 1
    srli    a1, a1, 1
    add     a0, a0, a1
    add     a0, a0, t0
    ret
    .size   op3_asm, .-op3_asm

# q_mul_asm: Q11.20 product, (a * b + 2^19) >> 20, low 32 bits kept.
#
# The magnitudes are multiplied by shift-and-add over the bits of the smaller
# one, so the loop runs only as many passes as that operand has bits. The
# 64-bit product is negated when the signs differ, rounded, and bits 20 to 51
# are returned.
#   a0, a2  multiplicand, low and high word    a1  multiplier
#   t1, t2  product, low and high word         t6  sign of the result (bit 31)
#   t0      scratch
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    xor     t6, a0, a1          # the product is negative if the signs differ
    srai    t0, a0, 31          # |a| = (a ^ m) - m, m = a >> 31
    xor     a0, a0, t0
    sub     a0, a0, t0
    srai    t0, a1, 31          # |b| the same way
    xor     a1, a1, t0
    sub     a1, a1, t0
    bgeu    a0, a1, 1f          # multiplier = the smaller magnitude
    mv      t0, a0
    mv      a0, a1
    mv      a1, t0
1:
    li      a2, 0
    li      t1, 0
    li      t2, 0
    beqz    a1, .Lsign
.Lmul:
    andi    t0, a1, 1
    beqz    t0, 2f
    add     t1, t1, a0          # product += multiplicand, 64 bits
    sltu    t0, t1, a0          # carry out of the low word
    add     t2, t2, a2
    add     t2, t2, t0
2:
    srli    t0, a0, 31          # multiplicand <<= 1, 64 bits
    slli    a2, a2, 1
    or      a2, a2, t0
    slli    a0, a0, 1
    srli    a1, a1, 1
    bnez    a1, .Lmul
.Lsign:
    bgez    t6, 3f              # signs differ: negate the 64-bit product
    seqz    t0, t1              # -x = ~x + 1: the 1 carries into the high
    not     t2, t2              # word only when the low word is zero
    add     t2, t2, t0
    neg     t1, t1
3:
    lui     t0, 0x80            # + 2^19, half a unit
    add     t1, t1, t0
    sltu    t0, t1, t0          # carry out of the low word
    add     t2, t2, t0
    srli    t1, t1, 20          # bits 20 to 51 of the product
    slli    t2, t2, 12
    or      a0, t1, t2
    ret
    .size   q_mul_asm, .-q_mul_asm
