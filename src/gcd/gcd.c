#include "gcd.h"

/*
 * Count trailing zeros of a nonzero x by binary search over the bit position.
 * RV32I has no ctz instruction, and a de Bruijn table would need a multiply.
 */
static unsigned ctz32(uint32_t x)
{
    unsigned n = 0;
    if (!(x & 0xFFFFu)) {
        n += 16;
        x >>= 16;
    }
    if (!(x & 0xFFu)) {
        n += 8;
        x >>= 8;
    }
    if (!(x & 0xFu)) {
        n += 4;
        x >>= 4;
    }
    if (!(x & 0x3u)) {
        n += 2;
        x >>= 2;
    }
    return n + (~x & 1u); /* one of the two low bits is set here */
}

/*
 * Binary GCD (Stein's algorithm), from the identities
 *   gcd(0, b) = b,  gcd(2a, 2b) = 2 gcd(a, b),
 *   gcd(2a, b) = gcd(a, b) for odd b,  gcd(a, b) = gcd(a, b - a) for b >= a.
 * The shared factors of two are counted once, then both operands are kept
 * odd, so b - a is even and at least one bit is shifted out per pass.
 */
uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    if (!a)
        return b;
    if (!b)
        return a;
    unsigned k = ctz32(a | b);
    a >>= ctz32(a);
    do {
        b >>= ctz32(b);
        if (a > b) {
            uint32_t t = a;
            a = b;
            b = t;
        }
        b -= a;
    } while (b);
    return a << k;
}
