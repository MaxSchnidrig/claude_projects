"""Bitboard constants and precomputed attack tables.

A bitboard is a 64-bit integer where bit n is set if something is on square n.
Squares are numbered a1 = 0, b1 = 1, ... h1 = 7, a2 = 8, ... h8 = 63.

Leaper pieces (knight, king, pawn captures) get a plain table: square -> attacks.
Sliding pieces (bishop, rook, queen) depend on which squares are blocked, so
for every square we precompute a dict from "occupancy of the relevant squares"
to the attack set. This plays the role of magic bitboards: one AND plus two
lookups give the full attack set of a slider.
"""

import random

WHITE, BLACK = 0, 1
PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING = range(6)
PIECE_CHARS = "PNBRQKpnbrqk"  # piece index = color * 6 + piece type
EMPTY = -1

FULL = (1 << 64) - 1
FILE_A = 0x0101010101010101
FILE_H = FILE_A << 7
NOT_FILE_A = FULL ^ FILE_A
NOT_FILE_H = FULL ^ FILE_H
RANK_1 = 0xFF
RANK_3 = RANK_1 << 16
RANK_6 = RANK_1 << 40
RANK_8 = RANK_1 << 56
FILES = [FILE_A << f for f in range(8)]
RANKS = [RANK_1 << (8 * r) for r in range(8)]


def square_name(sq):
    return "abcdefgh"[sq & 7] + str((sq >> 3) + 1)


def parse_square(name):
    if len(name) != 2 or name[0] not in "abcdefgh" or name[1] not in "12345678":
        raise ValueError(f"bad square: {name!r}")
    return (ord(name[0]) - ord("a")) + 8 * (int(name[1]) - 1)


def iter_bits(bb):
    while bb:
        low = bb & -bb
        yield low.bit_length() - 1
        bb ^= low


def _on_board(f, r):
    return 0 <= f < 8 and 0 <= r < 8


def _step_table(deltas):
    table = []
    for sq in range(64):
        f, r = sq & 7, sq >> 3
        bb = 0
        for df, dr in deltas:
            if _on_board(f + df, r + dr):
                bb |= 1 << ((r + dr) * 8 + f + df)
        table.append(bb)
    return table


KNIGHT_ATTACKS = _step_table([(1, 2), (2, 1), (2, -1), (1, -2),
                              (-1, -2), (-2, -1), (-2, 1), (-1, 2)])
KING_ATTACKS = _step_table([(1, 0), (1, 1), (0, 1), (-1, 1),
                            (-1, 0), (-1, -1), (0, -1), (1, -1)])
# PAWN_ATTACKS[color][sq]: squares a pawn of that color on sq attacks
PAWN_ATTACKS = [_step_table([(-1, 1), (1, 1)]), _step_table([(-1, -1), (1, -1)])]

ROOK_DIRECTIONS = [(1, 0), (-1, 0), (0, 1), (0, -1)]
BISHOP_DIRECTIONS = [(1, 1), (1, -1), (-1, 1), (-1, -1)]


def _slide(sq, occupied, directions):
    """Attacks of a slider on sq, walking each ray until it hits a piece."""
    f, r = sq & 7, sq >> 3
    bb = 0
    for df, dr in directions:
        nf, nr = f + df, r + dr
        while _on_board(nf, nr):
            bit = 1 << (nr * 8 + nf)
            bb |= bit
            if occupied & bit:
                break
            nf += df
            nr += dr
    return bb


def _relevant_mask(sq, directions):
    """Squares whose occupancy matters. The last square of each ray never
    matters (the slider attacks it whether or not it is occupied)."""
    f, r = sq & 7, sq >> 3
    bb = 0
    for df, dr in directions:
        nf, nr = f + df, r + dr
        while _on_board(nf + df, nr + dr):
            bb |= 1 << (nr * 8 + nf)
            nf += df
            nr += dr
    return bb


def _slider_tables(directions):
    masks, tables = [], []
    for sq in range(64):
        mask = _relevant_mask(sq, directions)
        table = {}
        subset = 0
        while True:  # enumerate every subset of mask (Carry-Rippler trick)
            table[subset] = _slide(sq, subset, directions)
            subset = (subset - mask) & mask
            if subset == 0:
                break
        masks.append(mask)
        tables.append(table)
    return masks, tables


ROOK_MASKS, ROOK_TABLES = _slider_tables(ROOK_DIRECTIONS)
BISHOP_MASKS, BISHOP_TABLES = _slider_tables(BISHOP_DIRECTIONS)


def rook_attacks(sq, occupied):
    return ROOK_TABLES[sq][occupied & ROOK_MASKS[sq]]


def bishop_attacks(sq, occupied):
    return BISHOP_TABLES[sq][occupied & BISHOP_MASKS[sq]]


def queen_attacks(sq, occupied):
    return rook_attacks(sq, occupied) | bishop_attacks(sq, occupied)


# --- Zobrist hashing: a random number for every (piece, square) and state ---
_rng = random.Random(0x5EED)
ZOBRIST_PIECE = [[_rng.getrandbits(64) for _ in range(64)] for _ in range(12)]
ZOBRIST_CASTLE = [_rng.getrandbits(64) for _ in range(16)]
ZOBRIST_EP = [_rng.getrandbits(64) for _ in range(8)]
ZOBRIST_SIDE = _rng.getrandbits(64)
