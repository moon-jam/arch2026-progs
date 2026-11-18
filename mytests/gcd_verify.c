/*
 * Host-side check of gcd_u32 in src/gcd/gcd.c against Euclid's algorithm.
 *
 *   cc -O2 mytests/gcd_verify.c src/gcd/gcd.c -o build/gcd_verify
 *   build/gcd_verify
 *
 * It checks every pair of operands below 2^16, that is all 2^32 pairs.
 * Euclid's algorithm uses the remainder, which the host has, so it shares no
 * step with the binary algorithm under test.
 */
#include <stdint.h>
#include <stdio.h>
#include "../src/gcd/gcd.h"

static uint32_t euclid(uint32_t a, uint32_t b)
{
    while (b) {
        uint32_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

int main(void)
{
    uint64_t bad = 0;
    for (uint32_t a = 0; a < 65536; a++) {
        for (uint32_t b = 0; b < 65536; b++) {
            uint32_t got = gcd_u32(a, b), want = euclid(a, b);
            if (got != want && bad++ < 10)
                printf("gcd(%u, %u) = %u, expected %u\n", a, b, got, want);
        }
    }
    printf("gcd: all 2^32 pairs below 2^16 checked\n");
    printf(bad ? "FAIL: %llu mismatches\n" : "PASS: no mismatch\n",
           (unsigned long long) bad);
    return bad != 0;
}
