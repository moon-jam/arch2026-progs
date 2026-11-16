# Computer Architecture (Fall 2026) - Assignment 2

Contributed by <[`moon-jam`](https://github.com/moon-jam)>

[Repository](https://github.com/moon-jam/arch2026-progs)
[Assignment Description](https://hackmd.io/@sysprog/2026-arch-homework2)

## Environment and Measurement

| Item | Value |
|---|---|
| Compiler | `riscv-none-elf-gcc` 14.2.0 (xPack) |
| Flags | `-march=rv32i_zicsr -mabi=ilp32 -ffreestanding`, at `-O1`, `-O2`, `-O3`, `-Os` |
| Emulator | rv32emu `9dbff65`, system emulation with `ELF_LOADER`, no M, A, F or C extension |

The timing code comes with the harness ([`common/bench.h`](https://github.com/moon-jam/arch2026-progs/blob/fd2d7c17db223807c342e3f210c769d23d1865b1/common/bench.h), called from [`tests/mgcd.c`](https://github.com/moon-jam/arch2026-progs/blob/fd2d7c17db223807c342e3f210c769d23d1865b1/tests/mgcd.c) and the other test programs). It runs a loop that calls the function once for each of a fixed set of inputs and reads the cycle counter before and after. It then runs the same loop with the call replaced by a plain copy of the input, which measures the loop and the counter reads alone. The second count is subtracted from the first and divided by the number of calls, so the per-call figures below count only the function itself.

rv32emu has no timing model: its cycle counter goes up by one per executed instruction, so every cycle count in this report is really an instruction count, and stalls or cache misses do not show up. Code size is measured separately with `size -A`.

## Binary GCD (`gcd`)

Source: [`gcd.c`](https://github.com/moon-jam/arch2026-progs/blob/5b7c93f7017be62fdad03003bca8cb581bf3fecb/src/gcd/gcd.c), [`gcd.S` v1](https://github.com/moon-jam/arch2026-progs/blob/5733288a355b9e6a901e22d5e3207bf6f6152f80/src/gcd/gcd.S), [`gcd.S` optimized](https://github.com/moon-jam/arch2026-progs/blob/9d05c2dc5b5baad95a1e5a05f6c83aea8d7ac66d/src/gcd/gcd.S)

### Principle

RV32I has no divider, so Euclid's remainder is out. Stein's binary GCD needs only shifts and subtractions, from four identities:

1. $\gcd(0, b) = b$
2. $\gcd(2a, 2b) = 2 \gcd(a, b)$
3. $\gcd(2a, b) = \gcd(a, b)$ for odd $b$
4. $\gcd(a, b) = \gcd(a, b - a)$ for $b \ge a$

Count the shared factors of two, $k = \operatorname{ctz}(a \mid b)$, and make $a$ odd. Then loop: make $b$ odd, swap so that $a \le b$, and set $b \leftarrow b - a$, until $b = 0$. The answer is `a << k`. Odd minus odd is even, so each pass shifts out at least one bit, which bounds the loop to about 64 passes.

RV32I also has no ctz instruction. `ctz32` finds the lowest set bit by binary search: test the low 16 bits, then 8, 4, 2 and 1. Its input must be nonzero; `gcd_u32` returns early on a zero operand and leaves the loop when $b$ reaches zero.

### Assembly against GCC

The first version (v1) follows the C code line by line. Compared with GCC at `-O2`:

- **No stack frame.** GCC calls `ctz32` as a function for the first two counts, so it saves `ra` and `s0` to `s2` in a 16-byte frame. The assembly is a leaf function that uses only `a` and `t` registers.
- **ctz as a macro**, expanded where it is used, so there is no call.
- **One instruction for the 16-bit test.** `0xFFFF` does not fit the 12-bit immediate of `andi`; `slli t2, x, 16` is zero exactly when the low 16 bits are.

With these alone, v1 is already faster than every C build, 1.11x faster than the best one (`-O3`):

| | -O1 | -O2 | -O3 | -Os | asm v1 |
|---|---|---|---|---|---|
| per call | 165.4 | 158.5 | 154.2 | 167.9 | 137.1 |
| worst call | 704 | 668 | 688 | 705 | 594 |
| `.text` (bytes) | 240 | 352 | 372 | 236 | 308 |

Per call is the cost over the bench inputs, worst call is the most expensive call the tests found (budgets: 1500 for the assembly, 4000 for C), and none of the versions has data sections. v1 is larger than `-Os` because the macro is expanded three times, where `-Os` calls `ctz32`.

### Optimizations

**A. Shift loop instead of ctz in the loop.** After `b - a`, $b$ has at least one trailing zero. For random operands it has exactly one with probability 1/2, two with probability 1/4, and so on, so two on average. (On the first pass $b$ is still the input, which has no trailing zero with probability 1/2 and one on average.) v1 spends 14 to 22 instructions per pass on the copy, the count and the shift. A loop that shifts one bit at a time costs 4 per zero plus 2 for the final test, about 10 on average:

```diff
 .Lloop:
-    mv      t0, a1              # b >>= ctz(b)
-    CTZ     t0, t1
-    srl     a1, a1, t1
+    andi    t0, a1, 1           # while b is even: b >>= 1
+    bnez    t0, .Lodd
+    srli    a1, a1, 1
+    j       .Lloop
+.Lodd:
     bgeu    a1, a0, .Lnoswap
```

The loop is not faster on every input. A call with a single pass that shifts out 31 zeros, such as $a = 1$ and $b = $ `0x80000000`, costs $31 \times 4 + 2 = 126$ instructions in the loop, against at most 22 for v1. The total is bounded, though. $a$ and $b$ have at most 32 binary digits each, 64 together. Each shift drops one digit from $b$, while a subtraction or a swap never adds a digit, and at the end $a$ is at least 1 and keeps one digit. So a whole call shifts out at most 63 zeros, and since every pass after the first shifts out at least one, it runs at most 64 passes. The loop therefore costs at most $4 \times 63 + 2 \times 64 = 380$ instructions per call. It can lose to v1 only on calls with few passes and wins on average, and the measurements below show that it is better in the worst case as well.

**B. Swap without a temporary.** When $a > b$, the swap is followed by $b \leftarrow b - a$, so the pair that comes out is $(b, a - b)$. Two subtractions form it, in place of three moves and a subtraction:

```diff
     bgeu    a1, a0, .Lnoswap    # a > b: the new pair is (b, a - b)
-    mv      t0, a0
-    mv      a0, a1
-    mv      a1, t0
+    sub     a1, a0, a1          # a1 = a - b, nonzero and even
+    sub     a0, a0, a1          # a0 = a - (a - b) = b, no temporary
+    j       .Lloop
 .Lnoswap:
     sub     a1, a1, a0          # b -= a
```

### Results of the optimizations

| | asm v1 | + A | + A + B |
|---|---|---|---|
| per call | 137.1 | 125.5 | **120.9** |
| worst call | 594 | 450 | **446** |

The final version is 1.26x faster than the best C build (`-O3`), measured in the same ELF. It is also down to 236 bytes, as small as `-Os`, because the count is now expanded twice instead of three times. A gained more than estimated because the bench always passes an odd $b$, which the shift loop tests in 2 instructions where v1 spent at least 14.

### Verification

`make grade` passes `gcd` at all four levels (`gcd PASS 15.0/15`), including the cross-check of the assembly against the C version, and `make sanitize` reports nothing.

### Applications

Binary GCD suits processors without a fast divider. Its extended form computes modular inverses in public-key cryptography such as RSA key generation, often in constant-time variants that resist timing attacks.

## Arithmetic from Logic and Q11.20 Fixed Point (`fixed`)

Source: [`fixed.c`](https://github.com/moon-jam/arch2026-progs/blob/ee11889a07641734330212c2d143826a07784961/src/fixed/fixed.c), [`fixed.S`](https://github.com/moon-jam/arch2026-progs/blob/fbada8b25d7c93948eca00ac4e4d056c009e3f13/src/fixed/fixed.S)

### Principle

**op1** adds two words with logic only. For one bit, `a ^ b` is the sum without the carry and `a & b` is the carry, which belongs one position higher, so $a + b = (a \oplus b) + ((a \mathbin{\&} b) \ll 1)$. That is again an addition, so the loop repeats it until no carry is left. Each pass moves the pending carries up at least one position, so the loop ends within 32 passes. The pass count `*n` is part of the result, which is why op1 keeps the loop instead of a single `add`.

**op2** is $a - b$ modulo $2^{32}$. Building it from op1 as $a + (\lnot b + 1)$ would take two op1 calls, hundreds of instructions, against a budget of 40, so it is the plain subtraction, which wraps the same way.

**op3** is $\lfloor (a + b) / 2 \rfloor$ without overflow. Both operands are halved before the addition, and when both are odd the two dropped halves add up to one, which `a & b & 1` puts back:

$$\left\lfloor \frac{a + b}{2} \right\rfloor = \left\lfloor \frac{a}{2} \right\rfloor + \left\lfloor \frac{b}{2} \right\rfloor + (a \mathbin{\&} b \mathbin{\&} 1)$$

**q_mul** multiplies two Q11.20 values. A stored integer $A$ represents $A / 2^{20}$: one sign bit, 11 integer bits and 20 fraction bits, so the range is $[-2048, 2048)$ and the resolution $2^{-20} \approx 9.5 \times 10^{-7}$. The product of two values is

$$\frac{A}{2^{20}} \cdot \frac{B}{2^{20}} = \frac{AB}{2^{40}},$$

so the 64-bit product $AB$ is shifted right by 20 to return to Q11.20. Adding $2^{19}$, half a unit, before the shift turns truncation into rounding to nearest, and since the arithmetic shift rounds toward minus infinity, ties go toward plus infinity: $1.5 \to 2$ and $-1.5 \to -1$. The error against the exact product is therefore at most half a unit, $2^{-21}$, as long as the result fits the format. A result outside the format keeps its low 32 bits and wraps instead of saturating.

### Multiplying without M

Writing the 64-bit product with the `*` operator makes GCC call `__muldi3`, which the runtime does not supply, so the link fails. The C version splits each operand into 16-bit halves and adds four partial products,

$$ab = a_h b_h \cdot 2^{32} + (a_h b_l + a_l b_h) \cdot 2^{16} + a_l b_l,$$

where each partial product fits 32 bits and becomes a call to `__mulsi3`, which the runtime does supply. This gives the unsigned product. A negative operand stands for its value plus $2^{32}$ as an unsigned number, so the other operand times $2^{32}$ is subtracted once for each negative operand. Only bits 20 to 51 of the rounded product are returned, and those are the same for an arithmetic and a logical shift, so the shift needs no sign handling.

### Assembly against GCC

**op1.** The loop in the assembly takes 5 instructions per pass, with the test at the bottom:

```asm
1:
    and     t0, a0, a1          # carries, one position too low
    xor     a0, a0, a1          # sum without the carries
    slli    a1, t0, 1           # carries move up one position
    addi    t1, t1, 1
    bnez    a1, 1b
```

GCC at `-O2` takes 7 per pass, with two extra moves between registers. At `-Os` it takes 6, because the test sits at the top of the loop and each pass ends with a jump back.

**op2 and op3** are one subtraction and six instructions. GCC emits the same number of instructions, so the assembly can only match it.

**q_mul.** The C version spends most of its time in the four calls to `__mulsi3`, each a loop over the bits of its second operand. The assembly runs a single shift-and-add loop instead. It takes the magnitudes of both operands, picks the smaller one as the multiplier, and adds the 64-bit multiplicand to the product for each set bit, so the loop runs only as many passes as the smaller operand has bits. RV32I has no carry flag, so the carry out of the low word comes from `sltu`: an unsigned sum that is smaller than one of its terms has wrapped.

```asm
    add     t1, t1, a0          # product += multiplicand, 64 bits
    sltu    t0, t1, a0          # carry out of the low word
    add     t2, t2, a2
    add     t2, t2, t0
```

After the loop, the 64-bit product is negated when the signs differ, as $\lnot x + 1$ with the 1 carried into the high word only when the low word is zero. Then $2^{19}$ is added, loaded by a single `lui t0, 0x80` since its low 12 bits are zero, and bits 20 to 51 are combined into the result.

### Results

Cost per call over the bench inputs (instructions):

| | -O1 | -O2 | -O3 | -Os | asm | speedup |
|---|---|---|---|---|---|---|
| op1 | 27.2 | 27.2 | 29.4 | 24.6 | 22.1 | 1.11x |
| op2 | 4.0 | 4.0 | 5.8 | 4.0 | 4.0 | 1.00x |
| op3 | 9.0 | 9.0 | 10.8 | 9.0 | 9.0 | 1.00x |
| q_mul | 322.9 | 318.9 | 320.7 | 319.4 | 185.9 | 1.72x |

The speedup is against the best C build of each function. The worst calls found by the tests are 169, 6, 11 and 404 instructions for the assembly, within budgets of 600, 40, 40 and 1200. The whole assembly object is 232 bytes of `.text`, against 348 for the smallest C build (`-Os`), and none of the versions has data sections.

### Verification

`make grade` passes `fixed` at all four levels (`fixed PASS 15.0/15`), including the cross-check of the assembly against the C version and the tie cases of the contract, and `make sanitize` reports nothing.

### Applications

Fixed-point arithmetic is how processors without a floating-point unit handle fractions, in microcontrollers, digital signal processing and audio codecs. A Q format trades range for precision at a fixed point, so the format is chosen to fit the data, and the choice between wrapping and saturating on overflow matters: audio code usually saturates, because a wrapped sample turns into a loud click.
