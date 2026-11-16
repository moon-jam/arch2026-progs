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
