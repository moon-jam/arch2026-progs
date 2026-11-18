# BFloat16 narrowing, multiply and square root, hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)
# uint16_t bf16_sqrt_asm(uint16_t a)
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. All three are leaf functions with no stack frame. The 16-bit
# arguments arrive zero-extended. Tests: tests/tbf16.c.

    .equ    BF16_INF, 0x7F80
    .equ    BF16_QNAN, 0x7FC0

    .text

# bf16_from_f32_asm: keep the top 16 bits, rounded to nearest, ties to even.
#   a0  f32bits, then the result      t0, t1  scratch
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    slli    t0, a0, 1           # drop the sign: exponent in bits 31..24
    lui     t1, 0xFF000
    bgeu    t0, t1, 1f          # exponent 0xFF: Inf or NaN, no rounding
    srli    t0, a0, 16
    andi    t0, t0, 1           # bit 16 breaks the tie toward even
    add     a0, a0, t0
    li      t1, 0x7FFF          # one less than half of the dropped part
    add     a0, a0, t1
1:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# bf16_mul_asm: product with the contract's special cases, truncated.
#   a0  a, then the result            a1  b
#   a2  mantissa of a, shifted up     a3  mantissa of b, shifted down
#   a4  mantissa product              t4  result exponent
#   t0  exponent of a                 t1  exponent of b
#   t6  sign of the result (bit 15)   t2, t3  scratch
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    xor     t6, a0, a1
    srli    t6, t6, 15          # sign = XOR of the signs, kept in bit 15
    slli    t6, t6, 15
    srli    t0, a0, 7
    andi    t0, t0, 0xFF
    srli    t1, a1, 7
    andi    t1, t1, 0xFF
    li      t2, 254             # an exponent in 1..254 means a normal
    addi    t3, t0, -1          # operand: exponent 0 wraps to a huge value
    bgeu    t3, t2, .Lmul_a_odd # and 0xFF gives exactly 254
    andi    a2, a0, 0x7F
    ori     a2, a2, 0x80        # a is normal: restore its leading one
.Lmul_b_check:
    addi    t3, t1, -1
    bgeu    t3, t2, .Lmul_b_odd
    andi    a3, a1, 0x7F
    ori     a3, a3, 0x80        # b is normal too
.Lmul_prod:
    add     t4, t0, t1
    addi    t4, t4, -127        # both exponents carry the bias once

    blt     t2, t4, .Lmul_inf   # t2 is 254 on both paths
    slti    t3, t4, -6          # even a carry leaves a zero fraction
    bnez    t3, .Lmul_zero

    li      a4, 0               # 8 x 8 bit product by shift and add
    li      t3, 1               # the normalized multiplier ends with a known 1
1:
    andi    t0, a3, 1
    beqz    t0, 2f
    add     a4, a4, a2
2:
    slli    a2, a2, 1
    srli    a3, a3, 1
    bne     a3, t3, 1b
    add     a4, a4, a2          # the leading one always contributes

    srli    t3, a4, 15          # product in [2^14, 2^16): one bit to fix
    beqz    t3, 3f
    beq     t4, t2, .Lmul_inf   # only a carry from 254 can overflow now
    srli    a4, a4, 1
    addi    t4, t4, 1
3:
    srli    a4, a4, 7           # truncate to 7 fraction bits
    andi    a4, a4, 0x7F
    blez    t4, .Lmul_sub
    slli    t4, t4, 7
    or      a0, t6, t4
    or      a0, a0, a4
    ret

.Lmul_a_odd:                    # a is zero, subnormal, Inf or NaN
    beq     t3, t2, .Lmul_a_special   # exponent 0xFF: a is checked first
    li      t4, 0xFF            # a has exponent 0, so b's Inf or NaN
    beq     t1, t4, .Lmul_b_special   # comes before a's zero
    andi    a2, a0, 0x7F
    beqz    a2, .Lmul_zero      # a is zero
    slli    t3, a1, 17
    beqz    t3, .Lmul_zero      # b is zero
    li      t0, 1               # a is subnormal: shift it up until bit 7
4:                              # is set, lowering its exponent each time
    slli    a2, a2, 1
    addi    t0, t0, -1
    andi    t3, a2, 0x80
    beqz    t3, 4b
    j       .Lmul_b_check       # b may still be subnormal

.Lmul_b_odd:                    # a is normalized, b is zero, subnormal, Inf or NaN
    beq     t3, t2, .Lmul_b_special   # exponent 0xFF: Inf or NaN
    andi    a3, a1, 0x7F
    beqz    a3, .Lmul_zero      # b is zero
    li      t1, 1               # b is subnormal: shift it up the same way
5:
    slli    a3, a3, 1
    addi    t1, t1, -1
    andi    t3, a3, 0x80
    beqz    t3, 5b
    j       .Lmul_prod

.Lmul_sub:                      # exponent <= 0: subnormal or zero
    li      t2, 1
    sub     t2, t2, t4
    srl     a4, a4, t2          # shift the fraction right 1 - exponent
    or      a0, t6, a4
    ret
.Lmul_a_special:                # a is Inf or NaN
    andi    t3, a0, 0x7F
    bnez    t3, .Lmul_ret       # NaN a is returned unchanged
    slli    t3, a1, 17
    beqz    t3, .Lmul_qnan      # Inf times zero
    j       .Lmul_inf           # whatever b is, a NaN b included
.Lmul_b_special:                # b is Inf or NaN
    andi    t3, a1, 0x7F
    beqz    t3, 6f
    mv      a0, a1              # NaN b is returned unchanged
    ret
6:
    slli    t3, a0, 17
    beqz    t3, .Lmul_qnan
.Lmul_inf:
    li      t2, BF16_INF
    or      a0, t6, t2
    ret
.Lmul_qnan:
    li      a0, BF16_QNAN
    ret
.Lmul_zero:
    mv      a0, t6
.Lmul_ret:
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# bf16_sqrt_asm: the contract's result is the largest r with
# r * r / 128 <= m, which is the integer square root of 128 * (m + 1) - 1.
# That root is found digit by digit, one result bit per pass, with no
# multiply: try setting the next bit, and keep it if the square still fits.
#   a0  a, then the result            t0  exponent, then the new exponent
#   t1  mantissa m, then the radicand N   t2  result r
#   t3  bit under trial (a power of 4)    t4, t5  scratch
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t0, a0, 7
    andi    t0, t0, 0xFF
    andi    t1, a0, 0x7F
    li      t4, 0xFF
    bne     t0, t4, 1f
    bnez    t1, .Lsqrt_ret      # NaN is returned unchanged
    slli    t4, a0, 16
    bltz    t4, .Lsqrt_qnan     # -Inf
    ret                         # +Inf
1:
    slli    t4, a0, 17
    beqz    t4, .Lsqrt_zero     # +0 and -0 give +0
    slli    t4, a0, 16
    bltz    t4, .Lsqrt_qnan     # negative nonzero
    beqz    t0, .Lsqrt_zero     # subnormal gives +0

    addi    t0, t0, -127
    ori     t1, t1, 0x80        # restore the leading one: m in [128, 256)
    andi    t4, t0, 1
    beqz    t4, 2f
    slli    t1, t1, 1           # odd exponent: double m, now in [256, 512)
    addi    t0, t0, -1
2:
    srai    t0, t0, 1           # exponent is even: halve it exactly
    addi    t0, t0, 127

    slli    t1, t1, 7           # N = 128 * (m + 1) - 1 = 128 * m + 127
    addi    t1, t1, 127
    li      t2, 0
    li      t3, 1 << 14         # N < 2^16, so the root has 8 bits
3:
    add     t4, t2, t3          # trial value: r with the next bit set
    srli    t2, t2, 1
    bltu    t1, t4, 4f          # does the square still fit in N?
    sub     t1, t1, t4
    add     t2, t2, t3          # yes: keep the bit
4:
    srli    t3, t3, 2
    bnez    t3, 3b

    andi    t2, t2, 0x7F        # r is in [128, 256): drop the leading one
    slli    t0, t0, 7
    or      a0, t0, t2
.Lsqrt_ret:
    ret
.Lsqrt_qnan:
    li      a0, BF16_QNAN
    ret
.Lsqrt_zero:
    li      a0, 0
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
