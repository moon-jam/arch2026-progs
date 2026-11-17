# Computer Architecture (Fall 2026) - Assignment 2

Contributed by <[`moon-jam`](https://github.com/moon-jam)>

[Repository](https://github.com/moon-jam/arch2026-progs)
[Assignment Description](https://hackmd.io/@sysprog/2026-arch-homework2)

## Environment and Measurement

| Item | Value |
|---|---|
| Compiler | `riscv-none-elf-gcc` 14.2.0 (xPack) |
| Flags | `-march=rv32i_zicsr -mabi=ilp32 -ffreestanding`, at `-O1`, `-O2`, `-O3`, `-Os` |
| Emulator | rv32emu [`9dbff65`](https://github.com/sysprog21/rv32emu/commit/9dbff65c4d6a40d64d3bbb38f4c5a20d6e885e24) (2026-11-10), system emulation with `ELF_LOADER`, no M, A, F or C extension |

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

## BFloat16 (`bf16`)

Source: [`bf16.c`](https://github.com/moon-jam/arch2026-progs/blob/dda9a203ed15b73f7c1f839c9f70210be06f05c4/src/bf16/bf16.c), [`bf16.S`](https://github.com/moon-jam/arch2026-progs/blob/9c256e0d6204810d7058f8d3a57521594f5aa554/src/bf16/bf16.S)

### Format

BFloat16 is the upper half of a 32-bit float. It has one sign bit, 8 exponent bits with a bias of 127, and 7 fraction bits. A normal value is

$$(-1)^S \times 1.F \times 2^{E - 127}.$$

Because the exponent is the same as in a 32-bit float, the range is the same, about $10^{\pm 38}$.

Two exponent values are special:

- Exponent `0xFF`: Inf if the fraction is zero, NaN otherwise.
- Exponent 0: zero if the fraction is zero, otherwise a subnormal value, which has no hidden leading one.

The code never uses a `float` in arithmetic. Every value is handled as its bit pattern.

### Converting binary32 to BF16 (`bf16_from_f32`)

The conversion keeps the upper 16 bits of the 32-bit float and rounds away the lower 16 bits. The rounding is done by one addition before the shift:

```c
f32bits += 0x7FFF + ((f32bits >> 16) & 1);
```

- If the lower half is less than `0x8000`, adding `0x7FFF` does not carry into the upper half, so the value is rounded down.
- If the lower half is more than `0x8000`, it carries, so the value is rounded up.
- If the lower half is exactly `0x8000`, it is a tie. Then bit 16, the last kept bit, decides: an odd value carries and becomes even, and an even value stays.

This is round to nearest, ties to even, so the error is at most half a unit in the last place. Inf and NaN are returned before the addition, so that a NaN cannot be rounded into Inf.

### Multiply (`bf16_mul`)

The multiply follows the contract step by step:

1. The sign of the result is the XOR of the two signs.
2. Special values are checked for `a` first, then for `b`. Because of this order, Inf times NaN gives Inf: once `a` is Inf, `b` is never looked at.
3. Zero times a finite value gives zero with the result's sign.
4. The hidden leading one is added back to each fraction. A subnormal operand has no leading one, so its fraction is shifted left until it has one, and its exponent goes down by one per shift.
5. The two 8-bit values are multiplied. The product is between $2^{14}$ and $2^{16}$, so at most one shift brings it back into place.
6. The extra fraction bits are cut off (truncated), not rounded. The error is therefore less than one unit in the last place.
7. The exponent is $E_a + E_b - 127$. Both exponents carry the bias of 127, so their sum carries it twice, and one is subtracted.
8. If the exponent reaches 255, the result is Inf. If it is 0 or less, the result becomes subnormal, or zero when it is too small.

### Square root (`bf16_sqrt`)

The square root splits the value into its exponent and its significand:

$$\sqrt{2^e \cdot m} = 2^{e/2} \cdot \sqrt{m}.$$

The exponent $e$ must be even to be halved. When it is odd, the significand is doubled and the exponent lowered by one, which keeps the same value. Here $m$ is the significand with the hidden leading one added back, `0x80 | F`. The contract does not say this step in words, but it follows from its use of "significand" and from its result range of [128, 256), whose top bit is that leading one. After this, $m$ is between 128 and 255 for an even exponent, or between 256 and 510 after doubling, read as a number with 7 fraction bits.

The contract defines the result as the largest $r$ with $\lfloor r^2 / 128 \rfloor \le m$. The C version finds it by binary search over $[90, 256]$, which takes up to 8 steps. Each step computes `mid * mid`. RV32I has no multiply instruction, so this is a call to `__mulsi3`, which is itself a loop.

The result is always between 128 and 255. Since $m \ge 128$, $r = 128$ always satisfies the condition, so the largest $r$ is at least 128. The smaller values in the search range also satisfy it, but they are never the largest. And $r = 256$ gives $256^2 / 128 = 512 > m$, so it never does. So the result never needs to be normalized again.

### Assembly against GCC

**bf16_from_f32.** Both versions use 11 instructions. The only difference is the test for Inf and NaN. The assembly shifts the sign bit out, which moves the exponent to the top 8 bits. Then a single unsigned compare with `0xFF000000` tells whether the exponent is all ones:

```asm
    slli    t0, a0, 1           # drop the sign: exponent in bits 31..24
    lui     t1, 0xFF000
    bgeu    t0, t1, 1f          # exponent 0xFF: Inf or NaN, no rounding
```

GCC uses `and` and `beq` instead, which is also 3 instructions. So this function can only tie with the compiler.

**bf16_mul and bf16_sqrt.** GCC calls `__mulsi3` in both functions: once for the product in the multiply, and once in every step of the square root's search. The assembly removes these calls. The next section explains how.

### Optimizations

**A. Inline multiply.** To call `__mulsi3`, GCC has to save registers. At every optimization level, its multiply opens a 32-byte stack frame and saves `ra` and `s0` to `s3`. That is 10 extra loads and stores per call.

The assembly does the 8-bit by 8-bit product itself, with a loop of 8 shift-and-add steps. Everything stays in registers, so there is no stack frame. The rare cases (special values, subnormal operands, overflow) are placed after the `ret` of the normal case, so a normal multiply runs straight through without jumping.

One small trick is the test for zero. Both +0 and -0 have all bits zero except the sign, so the test is `(a & 0x7FFF) == 0`. But `0x7FFF` does not fit in the 12-bit immediate of `andi`, and loading it first would take two more instructions. Instead, the code shifts the 16-bit value left by 17 with `slli t3, a0, 17`. The sign bit moves past bit 31 and is dropped, and the low 15 bits move to the top. The result is zero exactly when those 15 bits are zero, so one instruction does the test.

Result: the cost per call drops from 95.0 instructions (best C build) to 65.7. The worst call over the four builds drops from 179 to 141.

**B. Digit-by-digit square root.** The binary search needs a multiply in every step. The assembly avoids multiplying at all. First, the contract's condition can be rewritten:

$$\left\lfloor \frac{r^2}{128} \right\rfloor \le m \iff r^2 < 128(m+1) \iff r^2 \le N, \qquad N = 128m + 127.$$

So the result is simply the integer square root of $N$. Since $N < 2^{16}$, the root has 8 bits.

The assembly finds these 8 bits one at a time, starting from the top. Let $R$ be the bits found so far. Setting the next bit $k$ makes the square grow by

$$(R + 2^k)^2 - R^2 = 2R \cdot 2^k + 4^k.$$

The bit is kept if this amount still fits in what is left, $N - R^2$. Otherwise the bit stays 0.

Computing $2R \cdot 2^k$ directly would need a multiply. Instead, the loop keeps two registers with these values at the start of the step for bit $k$:

$$t_2 = 2R \cdot 2^k, \qquad t_3 = 4^k.$$

Then the amount is just $t_2 + t_3$, one addition.

Why can the loop keep these values without multiplying? The next step handles bit $k - 1$. Let $R'$ be the root after this step. The next step needs $t_2' = 2R' \cdot 2^{k-1} = R' \cdot 2^k$. There are two cases:

- The bit is not kept. Then $R' = R$, and $t_2' = R \cdot 2^k = t_2 / 2$.
- The bit is kept. Then $R' = R + 2^k$, and $t_2' = (R + 2^k) \cdot 2^k = R \cdot 2^k + 4^k = t_2 / 2 + t_3$.

So each step does the following:

- Shift $t_2$ right by one (`srli t2, t2, 1`).
- If the bit is kept, add $t_3$ to $t_2$ (`add t2, t2, t3`), and subtract the amount from what is left (`sub t1, t1, t4`).
- Shift $t_3$ right by two, from $4^k$ to $4^{k-1}$ (`srli t3, t3, 2`).

At the start, $R = 0$, so $t_2 = 0$. After the last step, for bit 0, $t_2 = 2R \cdot 2^{-1} = R$, which is the root. $t_2$ is always even before it is shifted, so no bit is lost. The whole loop uses only additions, subtractions and shifts:

```asm
3:
    add     t4, t2, t3          # (R + 2^k)^2 - R^2
    srli    t2, t2, 1
    bltu    t1, t4, 4f          # does it fit in what is left?
    sub     t1, t1, t4
    add     t2, t2, t3          # yes: keep bit k
4:
    srli    t3, t3, 2           # 4^k -> 4^(k-1)
    bnez    t3, 3b
```

The loop always runs 8 times, with 6 or 7 instructions each time. It gives the same result as the binary search, so the error is the same too. The result is not correctly rounded, and the contract gives a worst relative error of 0.3884% over the positive normal values.

Result: the cost per call drops from 325.6 instructions (best C build) to 46.1. The worst call over the four builds drops from 626 to 86.

### Results

Cost per call over the bench inputs (instructions):

| | -O1 | -O2 | -O3 | -Os | asm | speedup |
|---|---|---|---|---|---|---|
| from_f32 | 11.1 | 12.1 | 13.8 | 12.1 | 11.2 | 0.98x |
| mul | 95.0 | 95.4 | 96.8 | 96.5 | 65.7 | 1.45x |
| sqrt | 328.1 | 325.6 | 326.8 | 332.8 | 46.1 | 7.06x |

The conversion shows 0.98x, but both runs actually execute the same total number of instructions. The difference comes from the empty timing loop, which measured 3 instructions lower in the assembly run.

The worst calls of the assembly are 14, 141 and 86 instructions, within the budgets of 60, 400 and 1500. The assembly object takes 536 bytes of `.text`, against 732 bytes for the smallest C build (`-Os`). No version has data sections.

### Verification

`make grade` passes `bf16` at all four levels (`bf16 PASS 15.0/15`). This includes the check that the assembly gives the same results as the C version. `make sanitize` reports no errors.

### Applications

BFloat16 is used to train and run neural networks. There, range matters more than precision. Since BFloat16 keeps the exponent of a 32-bit float, converting between the two only means keeping or dropping the lower 16 bits.

## 2x2x2 Rubik's Cube Solver (`rubik`)

Source: [`rubik.c`](https://github.com/moon-jam/arch2026-progs/blob/f9e88297925129020e13a65688287a3d9434c095/src/rubik/rubik.c), [`rubik.S` ported](https://github.com/moon-jam/arch2026-progs/blob/17891b21897194e4d110fdeb5c3ac51c51e6514a/src/rubik/rubik.S), [`rubik.S` after A and B](https://github.com/moon-jam/arch2026-progs/blob/b0b1dc08b32c9858a2ced4ccf225e82b940a6286/src/rubik/rubik.S), [`rubik.S` final](https://github.com/moon-jam/arch2026-progs/blob/9ea9e1495f768c85d48c4c9d660af736f2043d1b/src/rubik/rubik.S)

### Principle

The solver comes from Homework 1, where its design is explained in full: [moon-jam/minirubik](https://github.com/moon-jam/minirubik). In short, a state is two numbers, the rank of the corner permutation and the rank of the corner twists, so a move is two table lookups. The search is IDA\*, with two lower bounds: the moves needed to solve the permutation alone, and the distance to the subgroup $\langle R2, B2, D2 \rangle$, stored modulo 3 in 2 bits per entry. The tables take 95,667 bytes, and none of them stores a move for every state.

This section only describes how the solver was ported to this assignment and made faster.

### C version

The C version keeps the search of Homework 1 and adds the contract's interface:

- It checks the 14 characters while reading them: digits in range, no repeated corner, twists that add up to a multiple of 3. Reading stops at the first bad character, so a short string is never read past its end.
- The search uses one frame per depth in a fixed array and a loop, not recursion. This fits easily in the 4 KiB stack.
- Before writing the answer, it counts how many bytes the move names, spaces and the final NUL need. If they do not fit in `cap`, it returns $-2$ and writes nothing but `out[0] = '\0'`. It returns $-1$ for an invalid state and leaves `out` untouched.
- It needs no multiply at all. A face selects its table row through an array of row pointers instead of computing `face * 5040`, and the permutation rank is built with shifts and adds.

### Assembly against GCC

The assembly started as the hand-written solver of Homework 1, [`solver-rv32i.s`](https://github.com/moon-jam/minirubik/blob/bbc2197b5888447bb7fcc15d16efd67eb2898829/solver-rv32i.s). Ported as it was, it took 6,479 instructions per call. The best C build here is `-O3` at 5,793, which inlines all small functions and keeps more values in registers. So the port was 12% slower and would have failed the grader.

### Optimizations

Five changes made it faster than `-O3`. Each diff compares the Homework 1 code (`-`) with the new code (`+`).

**A. Rank by shifts and adds.** The permutation rank is built as $((d_0 \cdot 6 + d_1) \cdot 5 + d_2) \cdots$, which needs a multiply for each digit. Homework 1 multiplied by repeated addition, a loop that ran 27 times in total. The new code multiplies by 6, 5, 4, 3 and 2 with shifts and adds, as the C version does. For example, $6p = 4p + 2p$:

```diff
-    li      t1, 7               # rank = (7 - i) * rank + digit, by addition
-    sub     t1, t1, t2
-    li      t3, 0
-.Lrank_mul:
-    beqz    t1, .Lrank_add
-    add     t3, t3, a0
-    addi    t1, t1, -1
-    j       .Lrank_mul
+    lbu     t1, 1(t0)
+    slli    t2, a0, 2           # 6p + d
+    slli    a0, a0, 1
+    add     a0, a0, t2
+    add     a0, a0, t1
+    ...                         # then 5p + d, 4p + d, 3p + d, 2p + d
```

**B. Inline the lookups when finding the start distance.** Walking into $H$ tries up to 9 moves per step. Homework 1 called a helper function for each move and for each remainder lookup. Every call loaded the table addresses again, and the candidate state had to be kept on the stack, because a call overwrites the temporary registers. The new code puts the lookups inline, loads the rows of a face once, and keeps everything in registers. The function now needs no stack frame:

```diff
 .Lroot_turn:
-    mv      a0, s6
-    lw      a1, 12(sp)
-    mv      a2, s5
-    call    quarter_rank
-    mv      s6, a0
-    sw      a1, 12(sp)
-    call    half_remainder
+    slli    t1, a6, 1           # one more quarter turn
+    add     t1, t3, t1          # t3, t4: rows of this face
+    lhu     a6, 0(t1)
+    slli    t1, a7, 1
+    add     t1, t4, t1
+    lhu     a7, 0(t1)
+    ...                         # the remainder lookup, also inline
```

Together, A and B brought the cost per call from 6,479 to 5,943.

**C. Look up the distance change.** A remainder change of $-2$ means the distance went up by one, and $+2$ means it went down by one. Homework 1 handled these two cases with two compares and branches. The new code reads the answer from a 5-byte table, indexed by the change plus 2:

```diff
     sub     t1, s9, t0          # new remainder - old remainder
-    li      t2, -2
-    bne     t1, t2, 4f
-    li      t1, 1
-4:
-    li      t2, 2
-    bne     t1, t2, 5f
-    li      t1, -1
-5:
+    add     t1, t1, s10         # s10 = delta_table: 1, -1, 0, 1, -1
+    lb      t1, 2(t1)
```

**D. Compute the move number only when it is recorded.** Homework 1 computed $3 \cdot \text{face} + \text{turn}$ for every move it tried. Most tried moves are cut off right away, so the number is never used. The new code computes it only when a move is kept in the solution, which also frees `s10` for the table of C:

```diff
     lbu     t0, 11(s5)
-    slli    t1, s8, 1           # move = 3 * face + turn, for every move
-    add     t1, t1, s8
-    add     s10, t1, t0
     addi    t0, t0, 1
```

**E. Retry the same face directly.** When a move is cut off, Homework 1 went back to the top of the node, which checks the face again and reloads the frame. If the same face still has turns left, none of that is needed, so the new code jumps straight to the next turn:

```diff
     add     t1, t0, a0
-    blt     s3, t1, .Lsearch_node
+    blt     s3, t1, .Lsearch_retry
     ...
+.Lsearch_retry:                 # cut off: the same face again if turns remain
+    lbu     t1, 11(s5)
+    bnez    t1, .Lsearch_turn
+    j       .Lsearch_node
```

Together, C, D and E brought the cost per call from 5,943 to 5,389.

### Results

Cost per call over the 6 bench states (instructions):

| -O1 | -O2 | -O3 | -Os | asm |
|---|---|---|---|---|
| 7,883.3 | 6,167.7 | 5,793.5 | 8,708.7 | 5,388.7 |

The assembly is 1.08x faster than the best C build (`-O3`). Every test state stays within the budgets: 7.5 million instructions for the assembly and 50 million for the C version, including all states at distance 11.

Static footprint (bytes, `size -A`), against the limit of 131,072:

| | `.text` | `.rodata` | `.bss` | total |
|---|---|---|---|---|
| -O1 | 2,232 | 95,667 | 0 | 97,899 |
| -O2 | 1,648 | 95,667 | 0 | 97,315 |
| -O3 | 2,892 | 95,667 | 0 | 98,559 |
| -Os | 1,632 | 95,667 | 0 | 97,299 |
| asm | 1,728 | 95,667 | 208 | 97,603 |

The tables dominate every version. The assembly keeps its search frames in `.bss` (208 bytes), while the C version keeps them on the stack.

### Verification

`make grade` passes `rubik` at all four levels (`rubik PASS 15.0/15`). The tests solve 59 states from distance 0 to 11 and check that each answer parses, solves the cube, and has exactly the shortest length. They also cover all 9 single moves, 13 invalid states and every buffer size around the exact fit. `make sanitize` reports no errors.

### Applications

The same ideas solve larger puzzles. Optimal solvers for the 3x3x3 cube, such as Korf's, also run IDA\* with pattern databases as lower bounds. The trade-off is the same as here: a bigger table gives a tighter bound and a faster search, but it has to fit in memory.
