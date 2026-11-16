#include "bf16.h"

#define BF16_SIGN 0x8000u
#define BF16_EXP 0x7F80u
#define BF16_INF 0x7F80u
#define BF16_QNAN 0x7FC0u
#define BF16_BIAS 127

/*
 * Narrow a binary32 pattern by keeping its top 16 bits. Adding 0x7FFF plus
 * bit 16 rounds to nearest, ties to even: the low half carries into the kept
 * half when it is above 0x8000, or exactly 0x8000 with an odd kept half.
 * Inf and NaN are returned as they are, so a NaN cannot round into Inf.
 */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    if (((f32bits >> 23) & 0xFFu) == 0xFFu)
        return (uint16_t) (f32bits >> 16);
    f32bits += 0x7FFFu + ((f32bits >> 16) & 1u);
    return (uint16_t) (f32bits >> 16);
}

/* Inf or NaN operand x, the other operand y: the result the contract asks. */
static uint16_t mul_special(uint16_t x, uint16_t y, uint16_t sign)
{
    if (x & 0x7Fu)
        return x; /* NaN is returned unchanged */
    if (!(y & 0x7FFFu))
        return BF16_QNAN; /* Inf times zero */
    return sign | BF16_INF;
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint16_t sign = (a ^ b) & BF16_SIGN;
    int32_t exp_a = (a >> 7) & 0xFF, exp_b = (b >> 7) & 0xFF;
    uint32_t mant_a = a & 0x7Fu, mant_b = b & 0x7Fu;

    if (exp_a == 0xFF)
        return mul_special(a, b, sign);
    if (exp_b == 0xFF)
        return mul_special(b, a, sign);
    if (!(a & 0x7FFFu) || !(b & 0x7FFFu))
        return sign; /* zero times a finite value */

    /* Restore the leading one; a denormal is shifted up until it has one. */
    int32_t exp_adjust = 0;
    if (exp_a) {
        mant_a |= 0x80u;
    } else {
        while (!(mant_a & 0x80u)) {
            mant_a <<= 1;
            exp_adjust--;
        }
        exp_a = 1;
    }
    if (exp_b) {
        mant_b |= 0x80u;
    } else {
        while (!(mant_b & 0x80u)) {
            mant_b <<= 1;
            exp_adjust--;
        }
        exp_b = 1;
    }

    /* 8 x 8 bits: the product is in [2^14, 2^16), one bit to renormalize. */
    uint32_t mant = mant_a * mant_b;
    int32_t exp = exp_a + exp_b - BF16_BIAS + exp_adjust;
    if (mant & 0x8000u) {
        mant = (mant >> 8) & 0x7Fu;
        exp++;
    } else {
        mant = (mant >> 7) & 0x7Fu;
    }

    if (exp >= 0xFF)
        return sign | BF16_INF;
    if (exp <= 0) {
        if (exp < -6)
            return sign;
        mant >>= 1 - exp;
        exp = 0;
    }
    return (uint16_t) (sign | ((uint32_t) exp << 7) | mant);
}

/*
 * sqrt(2^e * m) = 2^(e/2) * sqrt(m). An odd e is made even by doubling m, so
 * m lies in [128, 512) with 7 fraction bits, and the result significand is the
 * largest mid with mid * mid / 128 <= m, found by binary search over
 * [90, 256]. mid = 128 always qualifies and mid = 256 never does, so the
 * result is already in [128, 256), and the exponent stays in [64, 190]: the
 * contract's renormalization, overflow and underflow steps cannot trigger.
 */
uint16_t bf16_sqrt(uint16_t a)
{
    int32_t e = (a >> 7) & 0xFF;
    uint32_t m = a & 0x7Fu;

    if (e == 0xFF) {
        if (m)
            return a;                           /* NaN */
        return (a & BF16_SIGN) ? BF16_QNAN : a; /* -Inf, +Inf */
    }
    if (!(a & 0x7FFFu))
        return 0; /* +0 and -0 give +0 */
    if (a & BF16_SIGN)
        return BF16_QNAN; /* negative nonzero */
    if (!e)
        return 0; /* denormal */

    e -= BF16_BIAS;
    m |= 0x80u;
    if (e & 1) {
        m <<= 1;
        e--;
    }
    int32_t new_exp = e / 2 + BF16_BIAS; /* e is even: exact */

    uint32_t low = 90, high = 256, result = 128;
    while (low <= high) {
        uint32_t mid = (low + high) >> 1;
        if ((mid * mid) / 128 <= m) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return (uint16_t) (((uint32_t) new_exp << 7) | (result & 0x7Fu));
}
