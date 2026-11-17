#include "rubik.h"
#include "rubik_tables.h"

/*
 * Optimal 2x2x2 solver, ported from moon-jam/minirubik (Homework 1).
 *
 * A state is two coordinates: p ranks the permutation of the seven cubies
 * (0..5039) and o packs six orientations in base 3 (0..728); the seventh
 * orientation follows from the others. A quarter turn of a face maps each
 * coordinate on its own, so it is two table lookups. The search is IDA*
 * with two lower bounds: a table of permutation distances, and the exact
 * distance to a subgroup H, tracked as it changes by -1, 0 or +1 per move
 * from a table that stores it modulo 3.
 */
enum {
    CUBIES = 7,
    MOVES = 9,
    MAX_DEPTH = 11,
};

typedef struct {
    uint8_t p[CUBIES], o[CUBIES];
} state_t;

typedef struct {
    uint16_t p, o;
} coordinate_t;

static const char *const move_names[MOVES] = {"R",  "R2", "R'", "B", "B2",
                                              "B'", "D",  "D2", "D'"};

/* Row addresses, so a face selects a row without multiplying by 5040. */
static const uint16_t *const permutation_rows[3] = {
    permutation_transitions[0],
    permutation_transitions[1],
    permutation_transitions[2],
};
static const uint16_t *const orientation_rows[3] = {
    orientation_transitions[0],
    orientation_transitions[1],
    orientation_transitions[2],
};

/* The digits must be in range, the cubies distinct, and the orientations
 * sum to a multiple of 3. Reading stops at the first bad character, so a
 * short string is never read past its NUL.
 */
static int parse_state(const char *input, state_t *state)
{
    unsigned sum = 0;
    for (int i = 0; i < CUBIES; ++i) {
        if (input[i] < '1' || input[i] > '7')
            return 0;
        state->p[i] = (uint8_t) (input[i] - '1');
        for (int j = 0; j < i; ++j)
            if (state->p[j] == state->p[i])
                return 0;
    }
    for (int i = 0; i < CUBIES; ++i) {
        if (input[i + CUBIES] < '1' || input[i + CUBIES] > '3')
            return 0;
        state->o[i] = (uint8_t) (input[i + CUBIES] - '1');
        sum += state->o[i];
    }
    /* 0x1249 has bits 0, 3, 6, 9 and 12 set: sum % 3 == 0 for sum <= 14. */
    return input[14] == '\0' && ((0x1249u >> sum) & 1u);
}

static coordinate_t encode_state(const state_t *state)
{
    uint8_t digits[CUBIES - 1];
    for (int i = 0; i < CUBIES - 1; ++i) {
        uint8_t smaller = 0;
        for (int j = i + 1; j < CUBIES; ++j)
            smaller = (uint8_t) (smaller + (state->p[j] < state->p[i]));
        digits[i] = smaller;
    }
    /* Mixed radix 7, 6, 5, 4, 3, 2 by shifts and adds, without a multiply. */
    uint32_t p = digits[0];
    p = (p << 2) + (p << 1) + digits[1]; /* 6p + d */
    p = (p << 2) + p + digits[2];        /* 5p + d */
    p = (p << 2) + digits[3];            /* 4p + d */
    p = (p << 1) + p + digits[4];        /* 3p + d */
    p = (p << 1) + digits[5];            /* 2p + d */
    uint32_t o = 0;
    for (int i = 0; i < CUBIES - 1; ++i)
        o = (o << 1) + o + state->o[i]; /* 3o + d */
    return (coordinate_t) {(uint16_t) p, (uint16_t) o};
}

/* Lower bound from the permutation alone: two 4-bit entries per byte. */
static unsigned permutation_bound(unsigned p)
{
    return (permutation_distance[p >> 1] >> ((p & 1u) << 2)) & 15u;
}

/* Distance to the subgroup H modulo 3: four 2-bit entries per byte. */
static unsigned half_remainder(unsigned p, unsigned o)
{
    uint32_t index = subgroup_offset[p] + o;
    return (subgroup_remainder[index >> 2] >> ((index & 3u) << 1)) & 3u;
}

/* The exact distance to H of the root: walk to H, always taking a move that
 * lowers the remainder by one, and count the moves. -1 if it does not end.
 */
static int root_half_distance(coordinate_t state, unsigned remainder)
{
    int distance = 0;
    while (subgroup_offset[state.p] != 0 || state.o != 0) {
        unsigned wanted = remainder == 0 ? 2 : remainder - 1;
        int found = 0;
        for (unsigned face = 0; face < 3 && !found; ++face) {
            coordinate_t next = state;
            for (unsigned turn = 0; turn < 3; ++turn) {
                next.p = permutation_rows[face][next.p];
                next.o = orientation_rows[face][next.o];
                if (half_remainder(next.p, next.o) == wanted) {
                    state = next;
                    remainder = wanted;
                    found = 1;
                    break;
                }
            }
        }
        if (!found || ++distance > MAX_DEPTH)
            return -1;
    }
    return distance;
}

/* One level of the iterative search; the stack holds no recursion. */
typedef struct {
    uint16_t p, o, next_p, next_o;
    uint8_t distance, previous_face, face, turn;
    uint8_t next_distance, next_remainder, remainder;
} frame_t;

static void begin_frame(frame_t *frame,
                        unsigned p,
                        unsigned o,
                        unsigned distance,
                        unsigned previous_face,
                        unsigned remainder)
{
    frame->p = (uint16_t) p;
    frame->o = (uint16_t) o;
    frame->distance = (uint8_t) distance;
    frame->previous_face = (uint8_t) previous_face;
    frame->face = frame->turn = 0;
    frame->remainder = (uint8_t) remainder;
}

/* IDA*: deepen the bound until a path fits. Returns the length and writes
 * the moves, or -1. A move never turns the face the previous move turned.
 */
static int search(coordinate_t root, uint8_t *moves)
{
    frame_t frames[MAX_DEPTH + 1];
    unsigned root_remainder = half_remainder(root.p, root.o);
    int distance = root_half_distance(root, root_remainder);
    if (distance < 0)
        return -1;
    if (root.p == 0 && root.o == 0)
        return 0;
    unsigned first_bound = permutation_bound(root.p);
    if ((unsigned) distance > first_bound)
        first_bound = (unsigned) distance;

    for (unsigned bound = first_bound; bound <= MAX_DEPTH; ++bound) {
        unsigned depth = 0;
        begin_frame(&frames[0], root.p, root.o, (unsigned) distance, 0xFF,
                    root_remainder);
        for (;;) {
            frame_t *frame = &frames[depth];
            if (frame->face == frame->previous_face) {
                ++frame->face;
                frame->turn = 0;
            }
            if (frame->face == 3) {
                if (depth == 0)
                    break;
                --depth;
                continue;
            }
            unsigned face = frame->face;
            if (frame->turn == 0) {
                frame->next_p = frame->p;
                frame->next_o = frame->o;
                frame->next_distance = frame->distance;
                frame->next_remainder = frame->remainder;
            }
            frame->next_p = permutation_rows[face][frame->next_p];
            frame->next_o = orientation_rows[face][frame->next_o];
            unsigned remainder = half_remainder(frame->next_p, frame->next_o);
            /* Neighbors differ by at most one in distance, so a remainder
             * change of -2 means +1 and +2 means -1, modulo 3.
             */
            int delta = (int) remainder - frame->next_remainder;
            if (delta == -2)
                delta = 1;
            else if (delta == 2)
                delta = -1;
            frame->next_distance = (uint8_t) (frame->next_distance + delta);
            frame->next_remainder = (uint8_t) remainder;
            unsigned move = (face << 1) + face + frame->turn; /* 3f + t */
            if (++frame->turn == 3) {
                ++frame->face;
                frame->turn = 0;
            }
            if (depth + 1 + frame->next_distance > bound)
                continue;
            if (depth + 1 + permutation_bound(frame->next_p) > bound)
                continue;
            moves[depth] = (uint8_t) move;
            if (frame->next_p == 0 && frame->next_o == 0)
                return (int) depth + 1;
            if (depth + 1 == bound)
                continue;
            begin_frame(&frames[depth + 1], frame->next_p, frame->next_o,
                        frame->next_distance, face, remainder);
            ++depth;
        }
    }
    return -1;
}

int rubik_solve(const char *state, char *out, size_t cap)
{
    state_t cube;
    if (!parse_state(state, &cube))
        return -1;
    uint8_t moves[MAX_DEPTH];
    int length = search(encode_state(&cube), moves);
    if (length < 0)
        return -1;

    /* Each name is 1 or 2 characters, with a space between two names. */
    size_t need = 1;
    for (int i = 0; i < length; ++i)
        need += (i > 0) + (move_names[moves[i]][1] ? 2 : 1);
    if (need > cap) {
        if (cap)
            out[0] = '\0';
        return -2;
    }
    char *w = out;
    for (int i = 0; i < length; ++i) {
        if (i > 0)
            *w++ = ' ';
        for (const char *c = move_names[moves[i]]; *c; c++)
            *w++ = *c;
    }
    *w = '\0';
    return length;
}
