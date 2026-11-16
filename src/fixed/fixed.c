#include "fixed.h"

/*
 * Addition from logic: XOR adds without carries, AND shifted left by one
 * gives the carries. Each pass moves the pending carries up one position,
 * so the loop ends after at most 32 passes, when no carry is left.
 */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    *n = 0;
    while (b) {
        uint32_t c = (a & b) << 1;
        a = a ^ b;
        b = c;
        ++*n;
    }
    return a;
}

/* The bitwise model is op1(a, op1(~b, 1)); the budget asks for the plain
 * subtraction, which wraps modulo 2^32 the same way.
 */
uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

/* Halve each operand first so nothing overflows; when both are odd, the two
 * dropped halves add up to one.
 */
uint32_t op3(uint32_t a, uint32_t b)
{
    return (a >> 1) + (b >> 1) + (a & b & 1);
}

/*
 * Q11.20 multiply. A 64-bit product would make GCC call __muldi3, which the
 * runtime does not supply, so the product is built from four 16 x 16 partial
 * products (each a 32-bit multiply, __mulsi3). That gives the unsigned
 * product; for a negative operand, the other operand times 2^32 is
 * subtracted to make it signed. Only bits 20 to 51 of the rounded product
 * are kept, and those are the same for an arithmetic and a logical shift.
 */
int32_t q_mul(int32_t a, int32_t b)
{
    uint32_t ua = (uint32_t) a, ub = (uint32_t) b;
    uint32_t al = ua & 0xFFFFu, ah = ua >> 16;
    uint32_t bl = ub & 0xFFFFu, bh = ub >> 16;

    uint64_t p = (uint64_t) (al * bl);
    p += (uint64_t) (al * bh) << 16;
    p += (uint64_t) (ah * bl) << 16;
    p += (uint64_t) (ah * bh) << 32;
    if (a < 0)
        p -= (uint64_t) ub << 32;
    if (b < 0)
        p -= (uint64_t) ua << 32;

    p += 1u << 19; /* half a unit: ties round toward plus infinity */
    return (int32_t) (uint32_t) (p >> 20);
}
