# rubik_solve_asm: optimal 2x2x2 solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#
# Ported from the RV32I solver of moon-jam/minirubik (Homework 1). IDA* over
# two coordinates, p (permutation rank, 0..5039) and o (orientation rank,
# 0..728), with the same tables and lower bounds as rubik.c. The search is
# iterative, with one 16-byte frame per depth, so it needs no recursion.
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/trubik.c.

    .equ    MAX_DEPTH, 11

# Read-only tables, generated on the host (see rubik_tables.h); the labels
# are local to this object.
    .include "src/rubik/rubik_tables.inc"

    .section .rodata
# Move names, two bytes each, the second 0 for a one-letter name.
move_text:
    .ascii  "R\0R2R'B\0B2B'D\0D2D'"
# Change of the subgroup distance from the change of its remainder,
# indexed by (new - old) + 2: neighbors differ by at most one, so -2 is +1
# and +2 is -1 modulo 3.
delta_table:
    .byte   1, -1, 0, 1, -1

# Scratch: the parsed permutation and one search frame per depth.
    .section .bss
    .balign 4
p_buffer:
    .space  8
    .balign 16
frames:
    .space  (MAX_DEPTH + 1) * 16

    .text

# half_remainder(p, o): distance to the subgroup modulo 3.
#   a0 = p, a1 = o -> a0 = remainder (0..2); four 2-bit entries per byte
    .align  2
half_remainder:
    slli    t0, a0, 2           # index = subgroup_offset[p] + o
    la      t1, subgroup_offset
    add     t1, t1, t0
    lw      t1, 0(t1)
    add     t1, t1, a1
    andi    t2, t1, 3           # shift = 2 * (index & 3)
    slli    t2, t2, 1
    srli    t1, t1, 2
    la      t0, subgroup_remainder
    add     t0, t0, t1
    lbu     a0, 0(t0)
    srl     a0, a0, t2
    andi    a0, a0, 3
    ret

# parse_encode(input): check PPPPPPPOOOOOOO and rank it.
#   a0 = input -> a0 = p, a1 = o; a0 = -2 if the state is invalid
# A leaf: only caller-saved registers. Reading stops at the first bad
# character, so a short string is never read past its NUL.
    .align  2
parse_encode:
    la      t0, p_buffer
    li      t1, 0               # mask of cubies seen
    li      t2, 0               # index
.Lparse_perm:
    add     t3, a0, t2
    lbu     t4, 0(t3)
    addi    t4, t4, -'1'        # '1'..'7' -> 0..6
    sltiu   t5, t4, 7
    beqz    t5, .Lparse_bad
    li      t5, 1
    sll     t5, t5, t4
    and     t6, t1, t5
    bnez    t6, .Lparse_bad     # repeated cubie
    or      t1, t1, t5
    add     t3, t0, t2
    sb      t4, 0(t3)
    addi    t2, t2, 1
    li      t3, 7
    blt     t2, t3, .Lparse_perm

    li      t1, 0               # orientation rank
    li      t2, 0               # orientation sum
    li      t3, 0               # index
.Lparse_orient:
    addi    t4, t3, 7
    add     t4, a0, t4
    lbu     t5, 0(t4)
    addi    t5, t5, -'1'        # '1'..'3' -> 0..2
    sltiu   t6, t5, 3
    beqz    t6, .Lparse_bad
    add     t2, t2, t5
    li      t6, 6
    bge     t3, t6, .Lparse_orient_last
    slli    t4, t1, 1           # rank = 3 * rank + twist, first six only
    add     t1, t1, t4
    add     t1, t1, t5
.Lparse_orient_last:
    addi    t3, t3, 1
    li      t4, 7
    blt     t3, t4, .Lparse_orient
    lbu     t3, 14(a0)
    bnez    t3, .Lparse_bad     # longer than 14 characters
    li      t3, 0x1249          # bits 0, 3, 6, 9, 12: sum % 3 == 0
    srl     t3, t3, t2
    andi    t3, t3, 1
    beqz    t3, .Lparse_bad

    mv      a1, t1
    li      t2, 0               # i: Lehmer digit of p[i], stored over p[i]
.Lrank_outer:
    add     t3, t0, t2
    lbu     t4, 0(t3)           # p[i]
    addi    t5, t2, 1           # j
    li      t6, 0               # later entries smaller than p[i]
.Lrank_inner:
    add     t1, t0, t5
    lbu     t1, 0(t1)
    sltu    t1, t1, t4
    add     t6, t6, t1
    addi    t5, t5, 1
    li      t1, 7
    blt     t5, t1, .Lrank_inner
    sb      t6, 0(t3)           # p[i] is not needed by later digits
    addi    t2, t2, 1
    li      t1, 6
    blt     t2, t1, .Lrank_outer

    lbu     a0, 0(t0)           # radices 7, 6, 5, 4, 3, 2 by shifts and adds
    lbu     t1, 1(t0)
    slli    t2, a0, 2           # 6p + d
    slli    a0, a0, 1
    add     a0, a0, t2
    add     a0, a0, t1
    lbu     t1, 2(t0)
    slli    t2, a0, 2           # 5p + d
    add     a0, a0, t2
    add     a0, a0, t1
    lbu     t1, 3(t0)
    slli    a0, a0, 2           # 4p + d
    add     a0, a0, t1
    lbu     t1, 4(t0)
    slli    t2, a0, 1           # 3p + d
    add     a0, a0, t2
    add     a0, a0, t1
    lbu     t1, 5(t0)
    slli    a0, a0, 1           # 2p + d
    add     a0, a0, t1
    ret
.Lparse_bad:
    li      a0, -2
    ret

# root_distance(p, o, r): exact distance to the subgroup, from its value
# modulo 3. Walk down by always taking a move that lowers the remainder.
#   a0 = p, a1 = o, a2 = remainder -> a0 = distance, or -1
# A leaf with the lookups inlined; the rows of a face are loaded once.
#   a3 steps    a4 wanted remainder    a5 face    a6, a7 candidate p, o
#   t0 turn     t3, t4 rows of the face    t5 subgroup_offset
#   t6 subgroup_remainder    t1, t2 scratch
    .align  2
root_distance:
    li      a3, 0
    la      t5, subgroup_offset
    la      t6, subgroup_remainder
.Lroot_loop:
    slli    t1, a0, 2           # in the subgroup: offset[p] == 0 and o == 0
    add     t1, t5, t1
    lw      t1, 0(t1)
    bnez    t1, .Lroot_step
    beqz    a1, .Lroot_done
.Lroot_step:
    addi    a4, a2, -1          # wanted remainder: one less, modulo 3
    bgez    a4, 1f
    li      a4, 2
1:
    li      a5, 0
.Lroot_face:
    slli    t1, a5, 2           # rows of this face
    la      t2, permutation_rows
    add     t2, t2, t1
    lw      t3, 0(t2)
    la      t2, orientation_rows
    add     t2, t2, t1
    lw      t4, 0(t2)
    mv      a6, a0
    mv      a7, a1
    li      t0, 0
.Lroot_turn:
    slli    t1, a6, 1           # one more quarter turn
    add     t1, t3, t1
    lhu     a6, 0(t1)
    slli    t1, a7, 1
    add     t1, t4, t1
    lhu     a7, 0(t1)
    slli    t1, a6, 2           # its remainder
    add     t1, t5, t1
    lw      t1, 0(t1)
    add     t1, t1, a7
    andi    t2, t1, 3
    slli    t2, t2, 1
    srli    t1, t1, 2
    add     t1, t6, t1
    lbu     t1, 0(t1)
    srl     t1, t1, t2
    andi    t1, t1, 3
    beq     t1, a4, .Lroot_found
    addi    t0, t0, 1
    li      t1, 3
    blt     t0, t1, .Lroot_turn
    addi    a5, a5, 1
    blt     a5, t1, .Lroot_face
    li      a0, -1              # no move lowers it: not a valid state
    ret
.Lroot_found:
    mv      a0, a6
    mv      a1, a7
    mv      a2, a4
    addi    a3, a3, 1
    li      t1, MAX_DEPTH
    ble     a3, t1, .Lroot_loop
    li      a0, -1
    ret
.Lroot_done:
    mv      a0, a3
    ret

# search(p, o, moves): IDA* with explicit frames.
#   a0 = p, a1 = o, a2 = buffer (byte 0 length, bytes 1..11 moves)
#   -> a0 = length, or -1
# Frame layout (16 bytes): p 0, o 2, next_p 4, next_o 6 (16-bit);
# distance 8, previous_face 9, face 10, turn 11, next_distance 12,
# next_remainder 13, remainder 14 (8-bit).
# Registers: s0, s1 transition rows; s2 buffer; s3 bound; s4 depth;
# s5 &frames[depth]; s6 subgroup_offset; s7 subgroup_remainder; s8 face;
# s9 new remainder; s10 delta_table; s11 permutation_distance.
    .align  2
search:
    addi    sp, sp, -64
    sw      ra, 60(sp)
    sw      s0, 56(sp)
    sw      s1, 52(sp)
    sw      s2, 48(sp)
    sw      s3, 44(sp)
    sw      s4, 40(sp)
    sw      s5, 36(sp)
    sw      s6, 32(sp)
    sw      s7, 28(sp)
    sw      s8, 24(sp)
    sw      s9, 20(sp)
    sw      s10, 16(sp)
    sw      s11, 12(sp)
    mv      s0, a0              # root p
    mv      s1, a1              # root o
    mv      s2, a2
    or      t0, s0, s1
    bnez    t0, .Lsearch_start
    sb      zero, 0(s2)         # already solved
    li      a0, 0
    j       .Lsearch_exit
.Lsearch_start:
    call    half_remainder
    mv      s6, a0              # root remainder
    mv      a2, a0
    mv      a0, s0
    mv      a1, s1
    call    root_distance
    bltz    a0, .Lsearch_fail
    mv      s7, a0              # root distance
    srli    t1, s0, 1           # first bound: max(permutation bound, distance)
    andi    t2, s0, 1
    slli    t2, t2, 2
    la      t0, permutation_distance
    add     t1, t0, t1
    lbu     s3, 0(t1)
    srl     s3, s3, t2
    andi    s3, s3, 15
    bge     s3, s7, 1f
    mv      s3, s7
1:
    sh      s0, 0(sp)           # keep the root on the stack
    sh      s1, 2(sp)
    sb      s6, 4(sp)
    sb      s7, 5(sp)
    la      s0, permutation_rows
    la      s1, orientation_rows
    la      s6, subgroup_offset
    la      s7, subgroup_remainder
    la      s10, delta_table
    la      s11, permutation_distance
.Lsearch_pass:
    li      t0, MAX_DEPTH
    bgt     s3, t0, .Lsearch_fail
    li      s4, 0               # depth
    la      s5, frames
    lhu     t0, 0(sp)
    sh      t0, 0(s5)
    lhu     t0, 2(sp)
    sh      t0, 2(s5)
    lbu     t0, 5(sp)
    sb      t0, 8(s5)
    li      t0, 255             # no previous face at the root
    sb      t0, 9(s5)
    sb      zero, 10(s5)
    sb      zero, 11(s5)
    lbu     t0, 4(sp)
    sb      t0, 14(s5)
.Lsearch_node:
    lbu     t0, 10(s5)          # never turn the face just turned
    lbu     t1, 9(s5)
    bne     t0, t1, 2f
    addi    t0, t0, 1
    sb      t0, 10(s5)
    sb      zero, 11(s5)
2:
    li      t1, 3
    blt     t0, t1, .Lsearch_try
    beqz    s4, .Lsearch_next_pass
    addi    s4, s4, -1          # faces exhausted: back to the parent
    addi    s5, s5, -16
    j       .Lsearch_node
.Lsearch_try:
    mv      s8, t0              # face
    lbu     t1, 11(s5)
    bnez    t1, .Lsearch_turn
    lw      t2, 0(s5)           # first turn: start from the frame's state
    sw      t2, 4(s5)
    lbu     t2, 8(s5)
    sb      t2, 12(s5)
    lbu     t2, 14(s5)
    sb      t2, 13(s5)
.Lsearch_turn:
    lhu     a0, 4(s5)           # one more quarter turn of the same face
    lhu     a1, 6(s5)
    slli    t0, s8, 2
    add     t1, s0, t0
    lw      t1, 0(t1)
    slli    t2, a0, 1
    add     t1, t1, t2
    lhu     a0, 0(t1)
    add     t1, s1, t0
    lw      t1, 0(t1)
    slli    t2, a1, 1
    add     t1, t1, t2
    lhu     a1, 0(t1)
    sh      a0, 4(s5)
    sh      a1, 6(s5)

    slli    t0, a0, 2           # remainder of the new state
    add     t1, s6, t0
    lw      t1, 0(t1)
    add     t1, t1, a1
    andi    t2, t1, 3
    slli    t2, t2, 1
    srli    t1, t1, 2
    add     t0, s7, t1
    lbu     s9, 0(t0)
    srl     s9, s9, t2
    andi    s9, s9, 3           # a0 keeps next_p for the bound below

    lbu     t0, 13(s5)          # distance change from the remainder change
    sub     t1, s9, t0
    add     t1, t1, s10
    lb      t1, 2(t1)
    lbu     t2, 12(s5)
    add     t2, t2, t1
    sb      t2, 12(s5)
    sb      s9, 13(s5)
    lbu     t0, 11(s5)          # advance the turn, then the face
    addi    t0, t0, 1
    li      t1, 3
    blt     t0, t1, 6f
    sb      zero, 11(s5)        # third turn: next face
    lbu     t0, 10(s5)
    addi    t0, t0, 1
    sb      t0, 10(s5)
    j       7f
6:
    sb      t0, 11(s5)
7:
    addi    t0, s4, 1           # prune: depth + 1 + distance > bound
    add     t1, t0, t2
    blt     s3, t1, .Lsearch_retry
    srli    t1, a0, 1           # prune on the permutation bound too
    andi    t2, a0, 1
    slli    t2, t2, 2
    add     t1, s11, t1
    lbu     a0, 0(t1)
    srl     a0, a0, t2
    andi    a0, a0, 15
    add     t1, t0, a0
    blt     s3, t1, .Lsearch_retry

    lbu     t1, 11(s5)          # record move 3 * face + turn; the turn has
    addi    t1, t1, -1          # already advanced, and wrapped after 2
    bgez    t1, 9f
    li      t1, 2
9:
    slli    t2, s8, 1
    add     t2, t2, s8
    add     t1, t1, t2
    add     t2, s2, s4
    sb      t1, 1(t2)
    lhu     t1, 4(s5)
    bnez    t1, 8f
    lhu     t1, 6(s5)
    bnez    t1, 8f
    sb      t0, 0(s2)           # solved
    mv      a0, t0
    j       .Lsearch_exit
8:
    beq     t0, s3, .Lsearch_node   # at the bound: no child can fit
    addi    t1, s5, 16          # push a frame for the child
    lw      t2, 4(s5)
    sw      t2, 0(t1)
    lbu     t2, 12(s5)
    sb      t2, 8(t1)
    sb      s8, 9(t1)
    sb      zero, 10(t1)
    sb      zero, 11(t1)
    sb      s9, 14(t1)
    addi    s4, s4, 1
    mv      s5, t1
    j       .Lsearch_node
.Lsearch_retry:                 # pruned: the same face again if turns remain
    lbu     t1, 11(s5)
    bnez    t1, .Lsearch_turn
    j       .Lsearch_node
.Lsearch_next_pass:
    addi    s3, s3, 1           # the whole pass failed: raise the bound
    j       .Lsearch_pass
.Lsearch_fail:
    li      a0, -1
.Lsearch_exit:
    lw      s11, 12(sp)
    lw      s10, 16(sp)
    lw      s9, 20(sp)
    lw      s8, 24(sp)
    lw      s7, 28(sp)
    lw      s6, 32(sp)
    lw      s5, 36(sp)
    lw      s4, 40(sp)
    lw      s3, 44(sp)
    lw      s2, 48(sp)
    lw      s1, 52(sp)
    lw      s0, 56(sp)
    lw      ra, 60(sp)
    addi    sp, sp, 64
    ret

# rubik_solve_asm(state, out, cap): the entry point of the contract.
#   a0 = state, a1 = out, a2 = cap -> a0 = length, -1 or -2
# The moves are found first into a 12-byte buffer on the stack, then the
# length of the text is counted, so nothing is written when it does not fit.
#   s0 out    s1 cap    s2 number of moves    t3 move_text
    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    mv      s0, a1
    mv      s1, a2
    call    parse_encode
    li      t0, -2
    beq     a0, t0, .Lsolve_invalid   # out is left untouched
    mv      a2, sp              # buffer at 0(sp)..11(sp)
    call    search
    bltz    a0, .Lsolve_invalid
    mv      s2, a0

    la      t3, move_text       # bytes needed: names, spaces and the NUL
    li      t0, 1
    li      t1, 0
.Lsolve_count:
    bge     t1, s2, .Lsolve_fit
    beqz    t1, 1f
    addi    t0, t0, 1           # space before every name but the first
1:
    add     t2, sp, t1
    lbu     t2, 1(t2)
    slli    t2, t2, 1
    add     t2, t3, t2
    lbu     t2, 1(t2)
    snez    t2, t2              # two-letter name?
    addi    t0, t0, 1
    add     t0, t0, t2
    addi    t1, t1, 1
    j       .Lsolve_count
.Lsolve_fit:
    bgtu    t0, s1, .Lsolve_small

    mv      t0, s0              # write pointer
    li      t1, 0
.Lsolve_write:
    bge     t1, s2, .Lsolve_end
    beqz    t1, 2f
    li      t2, ' '
    sb      t2, 0(t0)
    addi    t0, t0, 1
2:
    add     t2, sp, t1
    lbu     t2, 1(t2)
    slli    t2, t2, 1
    add     t2, t3, t2
    lbu     t4, 0(t2)
    sb      t4, 0(t0)
    addi    t0, t0, 1
    lbu     t4, 1(t2)
    beqz    t4, 3f
    sb      t4, 0(t0)
    addi    t0, t0, 1
3:
    addi    t1, t1, 1
    j       .Lsolve_write
.Lsolve_end:
    sb      zero, 0(t0)
    mv      a0, s2
    j       .Lsolve_exit
.Lsolve_small:
    beqz    s1, 4f              # out[0] = '\0' when there is room for it
    sb      zero, 0(s0)
4:
    li      a0, -2
    j       .Lsolve_exit
.Lsolve_invalid:
    li      a0, -1
.Lsolve_exit:
    lw      s2, 16(sp)
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm
