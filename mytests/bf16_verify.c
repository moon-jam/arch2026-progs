/*
 * Host-side check of src/bf16/bf16.c against references built from exact
 * arithmetic in double, independent of the integer code under test.
 *
 *   cc -O2 mytests/bf16_verify.c src/bf16/bf16.c -lm -o build/bf16_verify
 *   build/bf16_verify
 *
 * It checks every input: all 2^32 pairs of bf16_mul, all 2^32 inputs of
 * bf16_from_f32 and all 65,536 inputs of bf16_sqrt. It also measures the
 * largest error of each routine against the exact result.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../src/bf16/bf16.h"

#define QNAN 0x7FC0u
#define INF 0x7F80u

static int is_nan(uint32_t x)
{
    return (x & 0x7F80u) == 0x7F80u && (x & 0x7Fu);
}

static int is_zero(uint32_t x)
{
    return !(x & 0x7FFFu);
}

/* Exact value of a finite bf16 pattern. */
static double value(uint32_t x)
{
    int e = (x >> 7) & 0xFF;
    double m = e ? (double) (0x80 | (x & 0x7F)) : (double) (x & 0x7F);
    double v = ldexp(m, (e ? e : 1) - 134);
    return (x & 0x8000u) ? -v : v;
}

static uint64_t bits_of(double d)
{
    uint64_t u;
    memcpy(&u, &d, sizeof u);
    return u;
}

/*
 * The contract's multiply, derived from the exact product. 8 x 8
 * significant bits fit a double exactly, and even the smallest product is a
 * normal double, so its exponent and its top 7 fraction bits are exactly the
 * exponent and the truncated fraction the contract describes.
 */
static uint16_t ref_mul(uint32_t a, uint32_t b)
{
    uint32_t sign = (a ^ b) & 0x8000u;
    if ((a & 0x7F80u) == 0x7F80u) {
        if (is_nan(a))
            return (uint16_t) a;
        return (uint16_t) (is_zero(b) ? QNAN : sign | INF);
    }
    if ((b & 0x7F80u) == 0x7F80u) {
        if (is_nan(b))
            return (uint16_t) b;
        return (uint16_t) (is_zero(a) ? QNAN : sign | INF);
    }
    if (is_zero(a) || is_zero(b))
        return (uint16_t) sign;

    uint64_t p = bits_of(fabs(value(a) * value(b)));
    int exp = (int) ((p >> 52) & 0x7FF) - 1023 + 127; /* bf16 bias */
    uint32_t frac = (uint32_t) (p >> 45) & 0x7F;      /* truncated */
    if (exp >= 0xFF)
        return (uint16_t) (sign | INF);
    if (exp <= 0) {
        if (exp < -6)
            return (uint16_t) sign;
        return (uint16_t) (sign | (frac >> (1 - exp)));
    }
    return (uint16_t) (sign | (uint32_t) exp << 7 | frac);
}

/* Narrowing by comparing the dropped half with half a unit. */
static uint16_t ref_from_f32(uint32_t f)
{
    uint32_t hi = f >> 16, lo = f & 0xFFFFu;
    if (((f >> 23) & 0xFF) == 0xFF)
        return (uint16_t) hi;
    if (lo > 0x8000u || (lo == 0x8000u && (hi & 1u)))
        hi++;
    return (uint16_t) hi;
}

/* The largest r with r * r / 128 <= m, from a double square root. */
static uint16_t ref_sqrt(uint32_t a)
{
    int e = (a >> 7) & 0xFF;
    if (e == 0xFF)
        return (uint16_t) (((a & 0x7F) || !(a & 0x8000u)) ? a : QNAN);
    if (is_zero(a))
        return 0;
    if (a & 0x8000u)
        return QNAN;
    if (!e)
        return 0;
    int ue = e - 127;
    uint32_t m = 0x80 | (a & 0x7F);
    if (ue & 1) {
        m <<= 1;
        ue--;
    }
    uint32_t r = (uint32_t) sqrt(128.0 * (m + 1) - 1);
    while (r * r / 128 > m)
        r--;
    while ((r + 1) * (r + 1) / 128 <= m)
        r++;
    return (uint16_t) ((uint32_t) (ue / 2 + 127) << 7 | (r & 0x7F));
}

/* Unit in the last place of a positive normal bf16 value. */
static double ulp(uint32_t x)
{
    return ldexp(1.0, (int) ((x >> 7) & 0xFF) - 134);
}

int main(void)
{
    uint64_t bad = 0;

    /* bf16_mul: every pair; error over the pairs with a normal result. */
    double mul_ulp = 0;
    for (uint64_t ab = 0; ab < (1ull << 32); ab++) {
        uint32_t a = (uint32_t) (ab >> 16), b = (uint32_t) ab & 0xFFFF;
        uint16_t got = bf16_mul((uint16_t) a, (uint16_t) b);
        if (got != ref_mul(a, b) && bad++ < 10)
            printf("mul(0x%04x, 0x%04x) = 0x%04x, expected 0x%04x\n", a, b, got,
                   ref_mul(a, b));
        uint32_t ge = (got >> 7) & 0xFF;
        if (ge >= 1 && ge <= 254 && !is_zero(a) && !is_zero(b)) {
            double err = fabs(value(a) * value(b) - value(got)) / ulp(got);
            if (err > mul_ulp)
                mul_ulp = err;
        }
    }
    printf("mul:      2^32 pairs checked, worst error %.4f ulp\n", mul_ulp);

    /* bf16_from_f32: every input; error over finite results. */
    double f32_ulp = 0;
    for (uint64_t i = 0; i < (1ull << 32); i++) {
        uint32_t f = (uint32_t) i;
        uint16_t got = bf16_from_f32(f);
        if (got != ref_from_f32(f) && bad++ < 10)
            printf("from_f32(0x%08x) = 0x%04x, expected 0x%04x\n", f, got,
                   ref_from_f32(f));
        uint32_t ge = (got >> 7) & 0xFF;
        if (((f >> 23) & 0xFF) != 0xFF && ge >= 1 && ge <= 254) {
            float fv;
            memcpy(&fv, &f, sizeof fv);
            double err = fabs((double) fv - value(got)) / ulp(got);
            if (err > f32_ulp)
                f32_ulp = err;
        }
    }
    printf("from_f32: 2^32 inputs checked, worst error %.4f ulp\n", f32_ulp);

    /* bf16_sqrt: every input; relative error over the positive normals. */
    double sqrt_rel = 0, sqrt_sum = 0;
    int n = 0;
    for (uint32_t a = 0; a < 65536; a++) {
        uint16_t got = bf16_sqrt((uint16_t) a);
        if (got != ref_sqrt(a) && bad++ < 10)
            printf("sqrt(0x%04x) = 0x%04x, expected 0x%04x\n", a, got,
                   ref_sqrt(a));
        if (a >= 0x0080 && a <= 0x7F7F) {
            double exact = sqrt(value(a));
            double rel = fabs(value(got) - exact) / exact;
            sqrt_sum += rel;
            n++;
            if (rel > sqrt_rel)
                sqrt_rel = rel;
        }
    }
    printf(
        "sqrt:     65536 inputs checked, worst relative error %.4f%%, "
        "mean %.4f%% over %d positive normals\n",
        100 * sqrt_rel, 100 * sqrt_sum / n, n);

    printf(bad ? "FAIL: %llu mismatches\n" : "PASS: no mismatch\n",
           (unsigned long long) bad);
    return bad != 0;
}
