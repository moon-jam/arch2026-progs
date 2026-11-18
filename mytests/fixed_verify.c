/*
 * Host-side check of q_mul in src/fixed/fixed.c against the exact product.
 *
 *   cc -O2 mytests/fixed_verify.c src/fixed/fixed.c -o build/fixed_verify
 *   build/fixed_verify
 *
 * Two 32-bit operands give at most a 62-bit product, so int64_t holds it
 * exactly. The reference forms that product directly, which shares no step
 * with the 16-bit partial products of the code under test. The input space
 * has 2^64 pairs, so the check covers every pair of a set of edge values and
 * 2^32 random pairs. It also measures the largest error against the exact
 * product, in units of 2^-20, over the results that do not wrap.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include "../src/fixed/fixed.h"

/* floor(x / 2^20). C division rounds toward zero, so a negative x that is
 * not a multiple of 2^20 needs one more step down. Unlike >> on a negative
 * value, this is defined by the C standard.
 */
static int64_t floor_div_2_20(int64_t x)
{
    int64_t q = x / (1 << 20);
    return (x % (1 << 20) < 0) ? q - 1 : q;
}

/* The contract: the exact product plus 2^19, divided by 2^20 rounding toward
 * minus infinity (an arithmetic shift by 20), keeping the low 32 bits.
 */
static int32_t ref_qmul(int32_t a, int32_t b)
{
    int64_t q = floor_div_2_20((int64_t) a * b + (1 << 19));
    return (int32_t) (uint32_t) (uint64_t) q;
}

static uint64_t bad, checked;
static double worst_err;

static void check(int32_t a, int32_t b)
{
    int32_t got = q_mul(a, b), want = ref_qmul(a, b);
    checked++;
    if (got != want && bad++ < 10)
        printf("q_mul(%d, %d) = %d, expected %d\n", a, b, got, want);
    int64_t p = (int64_t) a * b;
    int64_t q = floor_div_2_20(p + (1 << 19)); /* before it wraps */
    if (q == (int32_t) q) {
        double err = fabs((double) (q * (1 << 20) - p)) / (1 << 20);
        if (err > worst_err)
            worst_err = err;
    }
}

int main(void)
{
    /* Edge values: zero, one unit, powers of two and their neighbors, half
     * a unit, the largest and smallest values, and both signs of each.
     */
    int32_t edge[200];
    int n = 0;
    edge[n++] = 0;
    edge[n++] = INT32_MAX;
    edge[n++] = INT32_MIN;
    for (int k = 0; k < 31; k++) {
        int32_t v = (int32_t) (1u << k);
        const int32_t list[] = {v, v - 1, v + 1};
        for (int i = 0; i < 3; i++) {
            edge[n++] = list[i];
            edge[n++] = -list[i];
        }
    }
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            check(edge[i], edge[j]);
    uint64_t edge_pairs = checked;

    uint32_t x = 0x9E3779B9u;
    for (uint64_t k = 0; k < (1ull << 32); k++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        uint32_t y = x * 2654435761u;
        check((int32_t) x, (int32_t) y);
    }

    printf(
        "q_mul: %llu edge pairs and 2^32 random pairs checked, "
        "worst error %.6f units of 2^-20\n",
        (unsigned long long) edge_pairs, worst_err);
    printf(bad ? "FAIL: %llu mismatches\n" : "PASS: no mismatch\n",
           (unsigned long long) bad);
    return bad != 0;
}
