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

Count the shared factors of two, $k = \mathrm{ctz}(a \mid b)$, and make $a$ odd. Then loop: make $b$ odd, swap $a$ and $b$ if $a > b$, and set $b \leftarrow b - a$, until $b = 0$. The answer is `a << k`. Odd minus odd is even, so each pass shifts out at least one bit, which bounds the loop to about 64 passes.

RV32I also has no ctz instruction. `ctz32` finds the lowest set bit by binary search: test the low 16 bits, then 8, 4, 2 and 1. Its input must be nonzero; `gcd_u32` returns early on a zero operand and leaves the loop when $b$ reaches zero.

### Assembly against GCC

The first version (v1) follows the C code line by line. It counts trailing zeros with a macro, expanded at each of its three uses, so it never makes a call. It is a leaf function that uses only `a` and `t` registers, so it needs no stack frame.

GCC handles `ctz32` differently at each level:

| Level | How `ctz32` is used | Calls | Stack frame |
|---|---|---|---|
| `-O1` | a separate function | 3 | 16 bytes |
| `-Os` | a separate function | 3 | 16 bytes |
| `-O2` | inline in the loop, called for the first two counts | 2 | 16 bytes |
| `-O3` | inline at all three uses | 0 | none |

Against `-O1`, `-Os` and `-O2`, the assembly saves the calls and the frame. To make a call, GCC must save `ra` and keep its values in the saved registers `s0` to `s2`, so each call also costs loads and stores.

`-O3` makes no call and has no frame either, and it is the fastest C build. The assembly still beats it, because its trailing-zero count takes fewer instructions. Its tests are shorter, and it runs straight through, while the code from `-O3` takes a detour in the common case.

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

The loop is not faster on every input. A call with a single pass that shifts out 31 zeros, such as $a = 1$ and $b$ = `0x80000000`, costs $31 \times 4 + 2 = 126$ instructions in the loop, against at most 22 for v1. The total is bounded, though. $a$ and $b$ have at most 32 binary digits each, 64 together. Each shift drops one digit from $b$, while a subtraction or a swap never adds a digit, and at the end $a$ is at least 1 and keeps one digit. So a whole call shifts out at most 63 zeros, and since every pass after the first shifts out at least one, it runs at most 64 passes. The loop therefore costs at most $4 \times 63 + 2 \times 64 = 380$ instructions per call. It can lose to v1 only on calls with few passes and wins on average, and the measurements below show that it is better in the worst case as well.

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

`make grade` passes `gcd` at all four levels (`gcd PASS 15.0/15`). `make sanitize` reports no errors. The tests are in `tests/tgcd.c`. They compare both versions with Euclid's algorithm, written separately in the test file. They also check that the assembly gives the same results as the C version.

These are the edge cases the tests cover:

| Edge case | Example | Why it matters |
|---|---|---|
| Both operands zero | `gcd(0, 0) = 0` | Takes the early return. Keeps zero away from `ctz32`, which gives a wrong count for 0. |
| One operand zero | `gcd(0, x) = x`, `gcd(x, 0) = x` | Takes the other early return. |
| Equal operands | `gcd(x, x) = x` | The first subtraction gives 0, so the loop must stop after one pass. |
| Bit 31 set | `gcd(0x80000000, 1) = 1`, `gcd(0x80000000, 0x7FFFFFFF) = 1` | A signed compare would treat these as negative. This checks that the compare that decides whether to swap is unsigned (`bgeu`). |
| Most trailing zeros | `0x80000000` has 31 | The largest count `ctz32` can return. |
| Powers of two | `gcd(2^i, 2^j) = 2^min(i, j)`, all 1,024 pairs | Tests the count of shared factors of two, from 0 to 31. |
| Shared factors of two | `gcd(u << i, v << j) = gcd(u, v) << min(i, j)` | The factors must be removed once and put back once. |
| Largest values | `gcd(0xFFFFFFFF, 0xFFFF) = 0xFFFF` | Tests the full 32-bit range. |
| Close to the worst case | `gcd(1, 0xFFFFFFFF) = 1` | The loop walks down the bits of `b` one pass at a time. |
| Consecutive Fibonacci numbers | `gcd(2971215073, 1836311903) = 1` | The worst case of Euclid's algorithm, and a long run here too. |
| Every pair below 256 | all 65,536 pairs | Covers every small combination of bits. |

The input space has $2^{64}$ pairs, which is too many to check. Instead, the tests reach every branch of the code. They take both early returns, the swap path and the no-swap path, and the shift loop with 1 zero and with 31 zeros. They also check that the shared factors of two are restored.

To go further, [`mytests/gcd_verify.c`](https://github.com/moon-jam/arch2026-progs/blob/main/mytests/gcd_verify.c) checks the C version on the host against Euclid's algorithm, which uses the remainder and shares no step with the binary algorithm. It checks **every pair of operands below $2^{16}$, all $2^{32}$ pairs**. They all match. The check takes about 9 minutes.

So every path of the code is tested, and every pair of 16-bit operands is checked. Larger operands only add more passes of the same loop, which the 32-bit edge cases above already cover.

### Applications

Binary GCD suits processors without a fast divider. Its extended form computes modular inverses in public-key cryptography such as RSA key generation, often in constant-time variants that resist timing attacks.

## Arithmetic from Logic and Q11.20 Fixed Point (`fixed`)

Source: [`fixed.c`](https://github.com/moon-jam/arch2026-progs/blob/ee11889a07641734330212c2d143826a07784961/src/fixed/fixed.c), [`fixed.S`](https://github.com/moon-jam/arch2026-progs/blob/fbada8b25d7c93948eca00ac4e4d056c009e3f13/src/fixed/fixed.S)

### Principle

**op1** adds two words with logic only. For one bit, `a ^ b` is the sum without the carry and `a & b` is the carry, which belongs one position higher, so $a + b = (a \oplus b) + ((a \mathbin{\mathrm{AND}} b) \ll 1)$. That is again an addition, so the loop repeats it until no carry is left. Each pass moves the pending carries up at least one position, so the loop ends within 32 passes. The pass count `*n` is part of the result, which is why op1 keeps the loop instead of a single `add`.

**op2** is $a - b$ modulo $2^{32}$. Building it from op1 as $a + (\lnot b + 1)$ would take two op1 calls, hundreds of instructions, against a budget of 40, so it is the plain subtraction, which wraps the same way.

**op3** is $\lfloor (a + b) / 2 \rfloor$ without overflow. Both operands are halved before the addition, and when both are odd the two dropped halves add up to one, which `a & b & 1` puts back:

$$\left\lfloor \frac{a + b}{2} \right\rfloor = \left\lfloor \frac{a}{2} \right\rfloor + \left\lfloor \frac{b}{2} \right\rfloor + (a \mathbin{\mathrm{AND}} b \mathbin{\mathrm{AND}} 1)$$

**q_mul** multiplies two Q11.20 values. A stored integer $A$ represents $A / 2^{20}$: one sign bit, 11 integer bits and 20 fraction bits, so the range is $[-2048, 2048)$ and the resolution $2^{-20} \approx 9.5 \times 10^{-7}$. The product of two values is

$$\frac{A}{2^{20}} \cdot \frac{B}{2^{20}} = \frac{AB}{2^{40}},$$

so the 64-bit product $AB$ is shifted right by 20 to return to Q11.20. Adding $2^{19}$, half a unit, before the shift turns truncation into rounding to nearest, and since the arithmetic shift rounds toward minus infinity, ties go toward plus infinity: $1.5 \to 2$ and $-1.5 \to -1$. The error against the exact product is therefore at most half a unit, $2^{-21}$, as long as the result fits the format. The host check in the Verification section measures exactly half a unit as the largest error. A result outside the format keeps its low 32 bits and wraps instead of saturating.

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

The largest error of q_mul against the exact product, measured on the host over the 35,721 edge pairs and $2^{32}$ random pairs of the Verification section, is **0.5 units** ($2^{-21}$), for results that do not wrap. This is the bound of round to nearest: it is reached exactly on ties. op1, op2 and op3 are exact.

### Verification

`make grade` passes `fixed` at all four levels (`fixed PASS 15.0/15`). `make sanitize` reports no errors. The tests are in `tests/tfixed.c`. They use three kinds of checks:

- golden values from the instructor's reference model;
- a separate Q11.20 multiply written in the test file, which builds the product in a different way from our code;
- algebraic laws, which need no reference.

They also check that the assembly gives the same results as the C version.

These are the edge cases the tests cover for **op1**:

| Edge case | Example | Why it matters |
|---|---|---|
| Adding zero | `op1(x, 0)` gives `x` with 0 passes | The loop must not run at all. |
| A long carry | `0xFFFF + 1` takes 17 passes | The carry moves up one bit per pass. |
| The longest carry | `0xFFFFFFFF + 1` gives 0 in 32 passes | The upper limit of the loop, and the sum wraps to 0. |
| Crossing the sign bit | `0x7FFFFFFF + 1 = 0x80000000` | The sum has no sign; it just counts bits. |
| Overflow | `0x80000000 + 0x80000000 = 0` | The sum must wrap modulo $2^{32}$. |
| No carry | `0x55555555 + 0xAAAAAAAA = 0xFFFFFFFF` in 1 pass | The loop ends after one pass. |

The tests also check that the pass count is the same when `a` and `b` swap, that it is 0 only when `b` is 0, and that it never goes above 32.

For **op2** and **op3**:

| Edge case | Example | Why it matters |
|---|---|---|
| op2 below zero | `0 - 1 = 0xFFFFFFFF` | The result must wrap. |
| op2 across the sign bit | `0x80000000 - 1 = 0x7FFFFFFF` | Same as above, at the other end. |
| op3 with both operands odd | `op3(1, 1) = 1`, `op3(3, 4) = 3` | The dropped halves must be added back only when both are odd. |
| op3 where `a + b` overflows | `op3(0xFFFFFFFF, 0xFFFFFFFF) = 0xFFFFFFFF` | A plain `(a + b) / 2` would overflow and give the wrong answer. |

For **q_mul**, each operand shows its bits and the value it stands for. A stored integer $A$ means $A / 2^{20}$, so one unit is $2^{-20}$:

| Edge case | a | b | Result | Why it matters |
|---|---|---|---|---|
| A positive tie | `0x00000003`<br>3 units | `0x00080000`<br>0.5 | `0x00000002`<br>2 units | The exact product is 1.5 units. A tie rounds up, to 2. This is the contract's example. |
| A negative tie | `0xFFFFFFFD`<br>-3 units | `0x00080000`<br>0.5 | `0xFFFFFFFF`<br>-1 unit | The exact product is -1.5 units. A tie rounds up, to -1, not down to -2. |
| Positive times negative | `0x00180000`<br>1.5 | `0xFFF00000`<br>-1.0 | `0xFFE80000`<br>-1.5 | The code multiplies the magnitudes and fixes the sign afterwards. |
| Negative times negative | `0xFFE80000`<br>-1.5 | `0xFFF00000`<br>-1.0 | `0x00180000`<br>1.5 | Two negative signs give a positive result. |
| A result below one unit | `0x00000001`<br>1 unit | `0x00000001`<br>1 unit | `0x00000000`<br>0 | The product is $2^{-40}$, far below half a unit, so it rounds to 0. |
| Wrap instead of clamping | `0x7FFFFFFF`<br>2047.999999 | `0x7FFFFFFF`<br>2047.999999 | `0xFFFFF000`<br>-0.00390625 | The exact product, about 4,194,304, does not fit. The contract keeps the low 32 bits, so it wraps to a small negative value instead of clamping to the largest one. |
| Wrap of the smallest value | `0x80000000`<br>-2048 | `0x80000000`<br>-2048 | `0x00000000`<br>0 | $2048^2 = 2^{22}$ wraps to exactly 0. |
| Identity | `0x00180000`<br>1.5 | `0x00100000`<br>1.0 | `0x00180000`<br>1.5 | Times 1.0 must give the input. The tests also check times 0, 2.0 and -1.0. |

**Why these checks are enough.** None of the four routines can be checked on every input: each takes two 32-bit operands, so there are $2^{64}$ pairs, which would take thousands of years. Instead, the code and the contract show which parts can go wrong, and the tests target exactly those parts:

- **op2** is a single subtraction, and **op3** is six instructions with no branch. Every input runs the same instructions. The only thing that changes from input to input is whether a sum overflows or both operands are odd, and the cases above test both.
- **op1** has one loop, whose length depends on the carry chain. The tests run it from 0 passes to 32, the limit.
- **q_mul** follows the formula of the Principle section, which holds for every input. What can still go wrong in the code is listed below, and each item has its own cases:
  - the carries between the partial products (C) or between the two words of the product (assembly), reached by the largest values and the powers of two and their neighbors;
  - the sign handling, reached by all four sign combinations and by `0x80000000`, whose magnitude does not fit a signed 32-bit value;
  - the rounding, reached by positive and negative ties and by results below one unit;
  - the bits that are kept, reached by results that wrap.

All other inputs take the same paths as these cases. The tests check them for both the C and the assembly version: every test above is registered twice, once for each. The assembly must also match the C version on 4,096 random pairs.

On top of that, [`mytests/fixed_verify.c`](https://github.com/moon-jam/arch2026-progs/blob/main/mytests/fixed_verify.c) checks q_mul in C on the host, against the exact product. Two 32-bit operands give at most a 62-bit product, which `int64_t` holds exactly. So the reference simply forms that product, adds $2^{19}$ and shifts right by 20, with no partial products. It checks every pair of 189 edge values (0, the largest and smallest values, and $\pm 2^k$, $\pm(2^k - 1)$, $\pm(2^k + 1)$ for each $k$), 35,721 pairs in all, and $2^{32}$ random pairs. They all match. The check takes about 17 seconds.

### Applications

Fixed-point arithmetic is how processors without a floating-point unit handle fractions, in microcontrollers, digital signal processing and audio codecs. A Q format trades range for precision at a fixed point, so the format is chosen to fit the data, and the choice between wrapping and saturating on overflow matters: audio code usually saturates, because a wrapped sample turns into a loud click.

## BFloat16 (`bf16`)

Source: [`bf16.c` first version](https://github.com/moon-jam/arch2026-progs/blob/dda9a203ed15b73f7c1f839c9f70210be06f05c4/src/bf16/bf16.c), [`bf16.S` first version](https://github.com/moon-jam/arch2026-progs/blob/9c256e0d6204810d7058f8d3a57521594f5aa554/src/bf16/bf16.S), [`bf16.c` with the fast path](https://github.com/moon-jam/arch2026-progs/blob/f5b8cf85142097f4c8a33b1df81351c2a7986459/src/bf16/bf16.c), [`bf16.S` with the fast path](https://github.com/moon-jam/arch2026-progs/blob/f5b8cf85142097f4c8a33b1df81351c2a7986459/src/bf16/bf16.S)

### Format

BFloat16 is the upper half of a 32-bit float. It has one sign bit, 8 exponent bits with a bias of 127, and 7 fraction bits. A normal value is

$$(-1)^S \times 1.F \times 2^{E - 127}.$$

Because the exponent is the same as in a 32-bit float, the range is the same, about $10^{\pm 38}$.

Two exponent values are special:

- Exponent `0xFF`: Inf if the fraction is zero, NaN otherwise.
- Exponent 0: zero if the fraction is zero, otherwise a subnormal value, which has no hidden leading one.

The code never uses a `float` in arithmetic. Every value is handled as its bit pattern.

### Converting float32 to BF16 (`bf16_from_f32`)

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

**A. Inline multiply.** To call `__mulsi3`, GCC has to save registers. At every optimization level, its multiply opens a 16-byte stack frame and saves `ra`, `s0` and `s1`. That is 6 extra loads and stores per call.

The assembly does the 8-bit by 8-bit product itself, with a loop of 8 shift-and-add steps. Everything stays in registers, so there is no stack frame. The rare cases (special values, subnormal operands, overflow) are placed after the `ret` of the normal case, so a normal multiply runs straight through without jumping.

One small trick is the test for zero. Both +0 and -0 have all bits zero except the sign, so the test is `(a & 0x7FFF) == 0`. But `0x7FFF` does not fit in the 12-bit immediate of `andi`, and loading it first would take two more instructions. Instead, the code shifts the 16-bit value left by 17 with `slli t3, a0, 17`. The sign bit moves past bit 31 and is dropped, and the low 15 bits move to the top. The result is zero exactly when those 15 bits are zero, so one instruction does the test.

Result: in the first version, the assembly took 65.7 instructions per call, against 95.0 for the best C build. Its worst call was 141, against 179.

**B. A fast path for normal operands, and early answers.** After A, every multiply still checked for Inf, NaN, zero and subnormal operands one by one, even though most operands are normal numbers. Three changes cut this cost, in both the C and the assembly version.

*One test per operand.* A normal operand has an exponent field between 1 and 254. Zero and subnormal values have 0, and Inf and NaN have 255. So one unsigned compare, `exponent - 1 < 254`, tells whether an operand is normal. The value 0 wraps to a huge number, and 255 gives exactly 254, so both fail. When both operands pass, the code goes straight to the multiply. Only when a test fails does it look at the special cases, in the contract's order. The assembly also keeps what the failed test already knows: `exponent - 1` equals 254 exactly for Inf or NaN, so one more compare separates them from zero and subnormal values without testing again from the start.

*An answer before the multiply.* Once the hidden ones are in place, the product of the two significands can raise the exponent by at most one. So the exponent before the multiply already decides some results:

- If it is 255 or more, the result is Inf, whatever the product is.
- If it is below -6, the result is zero. Even with the extra one it stays at -6 or below, where the 7-bit fraction is shifted right by at least 7 bits and becomes zero.

The boundary matters. At exactly -6 before the multiply, a product that reaches bit 15 raises the exponent to -5, and the fraction is shifted right by only 6 bits. For example, `0xFF × 0xFF = 0xFE01` keeps the fraction `0x7E`, and `0x7E >> 6 = 1`, so the result is not zero. That is why the early answer starts below -6.

*One test fewer in the multiply loop.* The multiplier now always has its top bit set. So the shift-and-add loop only tests the 7 low bits, and adds the multiplicand once more at the end for the top bit:

```asm
1:
    andi    t0, a3, 1
    beqz    t0, 2f
    add     a4, a4, a2
2:
    slli    a2, a2, 1
    srli    a3, a3, 1
    bne     a3, t3, 1b          # t3 = 1: stop when only the top bit is left
    add     a4, a4, a2          # the top bit always contributes
```

Because the loop now stops when only the top bit is left, it does not need a separate test for it. With the early answer for an exponent of 255 or more, the only overflow left after the multiply is a carry from 254, which one compare catches.

Result: the assembly drops from 65.7 to 53.4 instructions per call, and its worst call over the four builds from 141 to 119. The same changes bring the best C build from 95.0 to 77.7. Note that only 10 of the 16 bench inputs have two normal operands, because the bench includes zeros, Inf and subnormal values on purpose. On real data, where almost every operand is normal, the fast path is taken even more often.

**C. Digit-by-digit square root.** The binary search needs a multiply in every step. The assembly avoids multiplying at all. First, the contract's condition can be rewritten:

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

The loop always runs 8 times, with 6 or 7 instructions each time. It gives the same result as the binary search, so the error is the same too. The result is not correctly rounded: its worst relative error, measured below, is 0.3884%.

Result: the cost per call drops from 325.6 instructions (best C build) to 46.1. The worst call over the four builds drops from 626 to 86.

### Results

Cost per call over the bench inputs (instructions):

| | -O1 | -O2 | -O3 | -Os | asm | speedup |
|---|---|---|---|---|---|---|
| from_f32 | 11.1 | 12.1 | 13.8 | 12.1 | 11.2 | 0.98x |
| mul | 77.7 | 78.4 | 79.8 | 78.0 | 53.4 | 1.45x |
| sqrt | 328.1 | 325.6 | 326.8 | 332.8 | 46.1 | 7.06x |

The conversion shows 0.98x, but both runs actually execute the same total number of instructions. The difference comes from the empty timing loop, which measured 3 instructions lower in the assembly run.

The worst calls of the assembly are 14, 119 and 86 instructions, within the budgets of 60, 400 and 1500. The assembly object takes 568 bytes of `.text`, against 744 bytes for the smallest C build (`-Os`). No version has data sections.

Largest error against the exact result, measured on the host over every input (see Verification). One ulp is one unit in the last place of the result:

| | largest error | expected from the rounding rule |
|---|---|---|
| from_f32 | 0.5000 ulp | at most 0.5 ulp (round to nearest) |
| mul | 0.9961 ulp | less than 1 ulp (truncation) |
| sqrt | 0.3884% relative, 0.1529% on average | not correctly rounded |

The multiply's error is measured over results in the normal range. The conversion reaches exactly half an ulp on ties, and the multiply comes just under one ulp, as truncation allows. Both match their rounding rules.

### Verification

Three kinds of evidence show that bf16 is correct:

1. the provided tests;
2. an exhaustive check of the C version on the host;
3. a check that the assembly matches the C version.

**1. The provided tests.** The tests are in `tests/tbf16.c`. `make grade` passes all of them at the four levels (`bf16 PASS 15.0/15`). `make sanitize` reports no errors.

Many tests compare our results with golden values from the instructor's reference model, which is not published. When there are many inputs, the test does not store every answer. Instead, it splits the inputs into blocks and folds each block of results into one number, a hash. A single wrong bit anywhere in the block gives a different hash, so the test fails.

The multiply grid uses 256 typical operands, paired with each other in all 65,536 ways. The 256 operands are:

| Kind | Count | Values |
|---|---|---|
| Normal numbers | 241 | exponents spread from 1 to 254; includes 1.0, -1.0, 2.0, 0.5, the smallest and largest normal values of both signs |
| Subnormal numbers | 6 | `0x0001`, `0x0002`, `0x0040`, `0x007F`, `0x8001`, `0x807F` |
| NaN | 5 | `0x7FC0`, `0xFFC0`, `0x7F81`, `0xFFBF`, `0xFFE2` |
| Zero | 2 | `0x0000`, `0x8000` |
| Inf | 2 | `0x7F80`, `0xFF80` |

About half of them are negative. A second test multiplies every one of the 65,536 values by each of 8 constants: 1.0, 2.0, 0.5, -1.0, `0x3F81` (just above 1.0), the largest finite value, the smallest subnormal value, and Inf.

Each example writes a value as its three fields in hex, `S|E|M`: the sign bit, the exponent field and the fraction field, followed by the value it stands for. For example, `0x3FC0` is written `0|7F|40`, which is 1.5.

These are the edge cases of **bf16_from_f32**. The input is a 32-bit float, so its fraction field has 23 bits (6 hex digits):

| Edge case | Example (S\|E\|M, value) | Why it matters |
|---|---|---|
| A tie, even result | `0\|7F\|008000` → `0\|7F\|00` (1.00390625 → 1) | The dropped half is exactly `0x8000`. The kept half `0x3F80` is even, so it stays. |
| A tie, odd result | `0\|7F\|018000` → `0\|7F\|02` (1.01171875 → 1.015625) | Exactly half again, but `0x3F81` is odd, so it rounds up to the even `0x3F82`. |
| Just below a tie | `0\|7F\|007FFF` → `0\|7F\|00` (1.003906131 → 1) | Less than half: rounds down. |
| Just above a tie | `0\|7F\|008001` → `0\|7F\|01` (1.003906369 → 1.0078125) | More than half: rounds up. |
| A negative tie | `1\|7F\|008000` → `1\|7F\|00` (-1.00390625 → -1) | The rule does not depend on the sign. |
| Subnormal to normal | `0\|00\|7FFFFF` → `0\|01\|00` (1.175e-38 → 1.175e-38) | Rounding up carries into the exponent: the largest subnormal value becomes the smallest normal one. |
| Largest finite to Inf | `0\|FE\|7F8000` → `0\|FF\|00` (3.396e+38 → Inf) | Rounding up overflows the exponent. The contract says this must happen. |
| A subnormal input | `0\|00\|010000` → `0\|00\|01` (9.184e-41 → 9.184e-41) | The contract's own example. |
| NaN stays | `0\|FF\|400000` → `0\|FF\|40` (NaN → NaN) | Inf and NaN are returned before rounding. |
| A float NaN becomes Inf | `0\|FF\|000001` → `0\|FF\|00` (NaN → Inf) | A NaN as a 32-bit float, but its only nonzero fraction bit is in the dropped half, so the kept half is Inf. |

The tests also try every top half with the bottom halves `0x7FFF`, `0x8000` and `0x8001`. The rounding only depends on which side of `0x8000` the bottom half falls. So these three values cover every input.

These are the edge cases of **bf16_mul**. The Step column refers to the numbered steps of the Multiply section above:

| Step | Edge case | Example (S\|E\|M, value) | Why it matters |
|---|---|---|---|
| 1 | Negative times positive | `1\|7F\|00` × `0\|7F\|00` → `1\|7F\|00` (-1 × 1 → -1) | The sign is the XOR of the two signs. The tests check the sign of every result on the grid. |
| 1 | Negative times negative | `1\|7F\|00` × `1\|7F\|00` → `0\|7F\|00` (-1 × -1 → 1) | Two negative signs give a positive result. |
| 2 | `a` is NaN | `0\|FF\|40` × `0\|7F\|00` → `0\|FF\|40` (NaN × 1 → NaN) | A NaN `a` is returned as it is. |
| 2 | `a` is Inf, `b` is zero | `0\|FF\|00` × `0\|00\|00` → `0\|FF\|40` (Inf × 0 → NaN) | Inf times zero has no meaning, so it gives NaN. |
| 2 | `a` is Inf, `b` is NaN | `0\|FF\|00` × `0\|FF\|40` → `0\|FF\|00` (Inf × NaN → Inf) | `a` is checked first and gives Inf, so the NaN in `b` is never looked at. |
| 2 | `b` is NaN | `0\|7F\|00` × `0\|FF\|40` → `0\|FF\|40` (1 × NaN → NaN) | The same rules, applied to `b` after `a`. |
| 3 | Zero times a finite value | `1\|00\|00` × `0\|7F\|00` → `1\|00\|00` (-0 × 1 → -0) | Gives zero with the right sign. |
| 4 | A subnormal `a` | `0\|00\|01` × `0\|FE\|7F` → `0\|79\|7F` (9.184e-41 × 3.39e+38 → 0.03112792969) | `a` has no hidden one, so it is shifted up until it has one, and its exponent goes down. |
| 5 | The product reaches bit 15 | `0\|7F\|40` × `0\|7F\|40` → `0\|80\|10` (1.5 × 1.5 → 2.25) | One more shift, so the exponent goes up by one: `7F` becomes `80`. |
| 6 | Low bits dropped | `0\|7F\|01` × `0\|7F\|01` → `0\|7F\|02` (1.0078125 × 1.0078125 → 1.015625) | The exact product is 1.01568603515625. The bits past the 7th fraction bit are cut off, not rounded. |
| 6 | Most bits dropped | `0\|7F\|7F` × `0\|7F\|7F` → `0\|80\|7E` (1.9921875 × 1.9921875 → 3.96875) | The largest fractions leave the most bits to cut off. |
| 8 | Result too large | `0\|FE\|7F` × `0\|80\|00` → `0\|FF\|00` (3.39e+38 × 2 → Inf) | The exponent reaches `FF`, so the result is Inf. The tests multiply every value by 2.0 and by the largest value. |
| 8 | Result just below normal | `0\|01\|40` × `0\|7E\|00` → `0\|00\|20` (1.763e-38 × 0.5 → 2.939e-39) | The exponent becomes 0, so the fraction is shifted right and the result is subnormal. The tests multiply every value by 0.5 and by the smallest subnormal value. |
| 8 | Result far too small | `0\|01\|00` × `0\|01\|00` → `0\|00\|00` (1.175e-38 × 1.175e-38 → 0) | The exponent is below -6, so the result is zero. |

Step 7, the exponent sum, is part of every example above.

These are the edge cases of **bf16_sqrt**:

| Edge case | Example (S\|E\|M, value) | Why it matters |
|---|---|---|
| A negative input | `1\|7F\|00` → `0\|FF\|40` (-1 → NaN) | Every negative input from `0x8001` to `0xFFFF` gives `0x7FC0`, or stays the same when it is a NaN. Each one is checked. |
| A subnormal input | `0\|00\|01` → `0\|00\|00` (9.184e-41 → 0) | Every subnormal input from `0x0001` to `0x007F` gives +0. Each one is checked. |
| A positive NaN | `0\|FF\|01` → `0\|FF\|01` (NaN → NaN) | Every positive NaN from `0x7F81` to `0x7FFF` stays the same. Each one is checked. |
| Negative zero | `1\|00\|00` → `0\|00\|00` (-0 → 0) | -0 gives +0, as the contract says. |
| Positive Inf | `0\|FF\|00` → `0\|FF\|00` (Inf → Inf) | +Inf stays the same. |
| Even exponent | `0\|81\|00` → `0\|80\|00` (4 → 2) | √4 = 2. The exponent can be halved directly. |
| Odd exponent | `0\|80\|00` → `0\|7F\|35` (2 → 1.4140625) | √2. The significand is doubled first so the exponent becomes even. |
| Smallest normal input | `0\|01\|00` → `0\|40\|00` (1.175e-38 → 1.084e-19) | One end of the range. |
| Largest finite input | `0\|FE\|7F` → `0\|BE\|7F` (3.39e+38 → 1.837e+19) | The other end of the range. |

The tests also compare all 65,536 inputs with the golden hashes.

**2. An exhaustive check on the host.** The square root is fully covered by the tests, but the multiply and the conversion have $2^{32}$ inputs each, and the tests only sample them. So [`mytests/bf16_verify.c`](https://github.com/moon-jam/arch2026-progs/blob/main/mytests/bf16_verify.c) checks the C version on every input of all three routines. It compares them with references that work in a different way from our code:

| Routine | How the reference works | Why it is independent |
|---|---|---|
| Multiply | Multiplies the two values as `double`, then reads the exponent and the top 7 fraction bits directly from the bits of the product, and applies the contract's rules for Inf, subnormal results and zero. | Our code multiplies integers by shift and add. The reference uses the floating-point hardware. |
| Conversion | Compares the dropped half with `0x8000` directly. | Our code adds `0x7FFF` instead. |
| Square root | Takes the square root of $128(m+1) - 1$ in `double`, then moves it up or down by one until it meets the condition exactly. | Our C version uses a binary search, and the assembly a digit-by-digit root. |

**Why a `double` product is exact.** The reference only works if the product is exact, because the contract truncates, while floating-point arithmetic rounds to nearest. A `double` holds every product of two BF16 values exactly, with a wide margin:

| | The product of two BF16 values needs | A normal `double` gives |
|---|---|---|
| Smallest positive value | $2^{-133} \times 2^{-133} = 2^{-266}$ (two of the smallest subnormal values) | $2^{-1022}$ |
| Largest value | less than $2^{128} \times 2^{128} = 2^{256}$ | about $2^{1024}$ |
| Significant bits | at most $8 + 8 = 16$ | 53 |

So every product is a normal `double` with no rounding, and its exponent and top 7 fraction bits can be read straight from its bits. A 32-bit `float` would not do this as simply. Its range ends near $2^{128}$ and $2^{-149}$, so large products become Inf and tiny ones become 0 or subnormal, and each of these cases would need its own handling.

All $2^{32}$ pairs of the multiply, all $2^{32}$ inputs of the conversion and all 65,536 inputs of the square root match. The check takes about two minutes. It also measures the errors in the table of the Results section.

**3. The assembly against the C version.** The exhaustive check runs on the host, so it covers the C version only. The assembly is checked by the tests in the ELF. On 8,192 random inputs, it must give the same results as the C version. It also passes every golden-hash test above, including all 65,536 inputs of the square root.

So the C version is checked on every possible input of every routine. The assembly matches it on all the edge cases above and on a large random sample. We do not need to worry about an input that was never checked.

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

`make grade` passes `rubik` at all four levels (`rubik PASS 15.0/15`). `make sanitize` reports no errors. The tests are in `tests/trubik.c`. They build their own copy of the cube model from the published face tables, so they do not trust the solver. Every answer is applied to this model, and it must reach the solved cube.

These are the edge cases the tests cover:

| Edge case | Example | Why it matters |
|---|---|---|
| Every distance from 0 to 11 | 59 states, one test per distance | The length must equal the exact distance. An answer that works but is not the shortest fails. |
| The hardest states | states at distance 11 | The longest searches. They must also stay within the instruction budget. |
| The solved cube | `12345671111111` | Returns 0 and writes an empty string. |
| The nine single moves | the solved cube after each of R, R2, ..., D' | Each must be solved in one move. This checks every move name and direction. |
| A chain of moves | follow an 11-move answer one move at a time | The solver must find distance 10, then 9, down to 0. It must agree with itself. |
| Too short or too long | 13 characters, 15 characters, an empty string | Must return -1. |
| A cubie digit out of range | `0`, `8` or `9` in the first seven characters | Must return -1. |
| A twist out of range | `0`, `4` or `8` in the last seven characters | Must return -1. |
| A wrong character | a letter in the string | Must return -1. |
| A repeated cubie | `11345671111111` | Must return -1. |
| Twists with a bad sum | `12345671111112` | The twists must add up to a multiple of 3. |
| Output untouched on -1 | every invalid state above | The whole output buffer must stay as it was. |
| A buffer too small | every size from 1 byte to one byte short | Must return -2 and set `out[0]` to `'\0'`. |
| The exact buffer size | the length of the answer plus 1 | Must succeed without writing past the end. |
| A buffer of size 0 | `cap = 0` | Must write nothing at all. |

The search itself comes from Homework 1, where it was checked on all 3,674,160 states. Here, the tests cover every distance, every move, every reason to reject a state and every buffer size around the exact fit. These are all the places where the port changed the code.

### Applications

The same ideas solve larger puzzles. Optimal solvers for the 3x3x3 cube, such as Korf's, also run IDA\* with pattern databases as lower bounds. The trade-off is the same as here: a bigger table gives a tighter bound and a faster search, but it has to fit in memory.
