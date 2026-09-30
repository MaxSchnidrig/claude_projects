"""Static evaluation: how good is this position for the side to move?

The core is a *tapered* evaluation. Every piece has a middlegame and an
endgame value that depends on its square (piece-square tables, taken from
Ronald Friederich's PeSTO). The board keeps both running totals up to date
as moves are made, so they cost nothing here. The two totals are blended by
game phase: with all pieces on the board we use the middlegame score, and as
pieces come off we slide towards the endgame score.

On top of that, evaluate() adds terms that depend on how pieces relate to
each other: pawn structure (cached by pawn layout), mobility, rooks on open
files, king shelter, the bishop pair, and endgame knowledge for mating.
"""

from .bitboard import (BISHOP_MASKS, BISHOP_TABLES, BLACK, FILES, KING_ATTACKS,
                       KNIGHT_ATTACKS, ROOK_MASKS, ROOK_TABLES, WHITE)

MG_VALUE = [82, 337, 365, 477, 1025, 0]
EG_VALUE = [94, 281, 297, 512, 936, 0]
PHASE_WEIGHT = [0, 1, 1, 2, 4, 0]
TOTAL_PHASE = 24

# PeSTO piece-square tables, written from White's point of view with a8 first
_MG_PST = [
    [  0,   0,   0,   0,   0,   0,  0,   0,
      98, 134,  61,  95,  68, 126, 34, -11,
      -6,   7,  26,  31,  65,  56, 25, -20,
     -14,  13,   6,  21,  23,  12, 17, -23,
     -27,  -2,  -5,  12,  17,   6, 10, -25,
     -26,  -4,  -4, -10,   3,   3, 33, -12,
     -35,  -1, -20, -23, -15,  24, 38, -22,
       0,   0,   0,   0,   0,   0,  0,   0],
    [-167, -89, -34, -49,  61, -97, -15, -107,
      -73, -41,  72,  36,  23,  62,   7,  -17,
      -47,  60,  37,  65,  84, 129,  73,   44,
       -9,  17,  19,  53,  37,  69,  18,   22,
      -13,   4,  16,  13,  28,  19,  21,   -8,
      -23,  -9,  12,  10,  19,  17,  25,  -16,
      -29, -53, -12,  -3,  -1,  18, -14,  -19,
     -105, -21, -58, -33, -17, -28, -19,  -23],
    [-29,   4, -82, -37, -25, -42,   7,  -8,
     -26,  16, -18, -13,  30,  59,  18, -47,
     -16,  37,  43,  40,  35,  50,  37,  -2,
      -4,   5,  19,  50,  37,  37,   7,  -2,
      -6,  13,  13,  26,  34,  12,  10,   4,
       0,  15,  15,  15,  14,  27,  18,  10,
       4,  15,  16,   0,   7,  21,  33,   1,
     -33,  -3, -14, -21, -13, -12, -39, -21],
    [ 32,  42,  32,  51, 63,  9,  31,  43,
      27,  32,  58,  62, 80, 67,  26,  44,
      -5,  19,  26,  36, 17, 45,  61,  16,
     -24, -11,   7,  26, 24, 35,  -8, -20,
     -36, -26, -12,  -1,  9, -7,   6, -23,
     -45, -25, -16, -17,  3,  0,  -5, -33,
     -44, -16, -20,  -9, -1, 11,  -6, -71,
     -19, -13,   1,  17, 16,  7, -37, -26],
    [-28,   0,  29,  12,  59,  44,  43,  45,
     -24, -39,  -5,   1, -16,  57,  28,  54,
     -13, -17,   7,   8,  29,  56,  47,  57,
     -27, -27, -16, -16,  -1,  17,  -2,   1,
      -9, -26,  -9, -10,  -2,  -4,   3,  -3,
     -14,   2, -11,  -2,  -5,   2,  14,   5,
     -35,  -8,  11,   2,   8,  15,  -3,   1,
      -1, -18,  -9,  10, -15, -25, -31, -50],
    [-65,  23,  16, -15, -56, -34,   2,  13,
      29,  -1, -20,  -7,  -8,  -4, -38, -29,
      -9,  24,   2, -16, -20,   6,  22, -22,
     -17, -20, -12, -27, -30, -25, -14, -36,
     -49,  -1, -27, -39, -46, -44, -33, -51,
     -14, -14, -22, -46, -44, -30, -15, -27,
       1,   7,  -8, -64, -43, -16,   9,   8,
     -15,  36,  12, -54,   8, -28,  24,  14],
]

_EG_PST = [
    [  0,   0,   0,   0,   0,   0,   0,   0,
     178, 173, 158, 134, 147, 132, 165, 187,
      94, 100,  85,  67,  56,  53,  82,  84,
      32,  24,  13,   5,  -2,   4,  17,  17,
      13,   9,  -3,  -7,  -7,  -8,   3,  -1,
       4,   7,  -6,   1,   0,  -5,  -1,  -8,
      13,   8,   8,  10,  13,   0,   2,  -7,
       0,   0,   0,   0,   0,   0,   0,   0],
    [-58, -38, -13, -28, -31, -27, -63, -99,
     -25,  -8, -25,  -2,  -9, -25, -24, -52,
     -24, -20,  10,   9,  -1,  -9, -19, -41,
     -17,   3,  22,  22,  22,  11,   8, -18,
     -18,  -6,  16,  25,  16,  17,   4, -18,
     -23,  -3,  -1,  15,  10,  -3, -20, -22,
     -42, -20, -10,  -5,  -2, -20, -23, -44,
     -29, -51, -23, -15, -22, -18, -50, -64],
    [-14, -21, -11,  -8, -7,  -9, -17, -24,
      -8,  -4,   7, -12, -3, -13,  -4, -14,
       2,  -8,   0,  -1, -2,   6,   0,   4,
      -3,   9,  12,   9, 14,  10,   3,   2,
      -6,   3,  13,  19,  7,  10,  -3,  -9,
     -12,  -3,   8,  10, 13,   3,  -7, -15,
     -14, -18,  -7,  -1,  4,  -9, -15, -27,
     -23,  -9, -23,  -5, -9, -16,  -5, -17],
    [13, 10, 18, 15, 12,  12,   8,   5,
     11, 13, 13, 11, -3,   3,   8,   3,
      7,  7,  7,  5,  4,  -3,  -5,  -3,
      4,  3, 13,  1,  2,   1,  -1,   2,
      3,  5,  8,  4, -5,  -6,  -8, -11,
     -4,  0, -5, -1, -7, -12,  -8, -16,
     -6, -6,  0,  2, -9,  -9, -11,  -3,
     -9,  2,  3, -1, -5, -13,   4, -20],
    [ -9,  22,  22,  27,  27,  19,  10,  20,
     -17,  20,  32,  41,  58,  25,  30,   0,
     -20,   6,   9,  49,  47,  35,  19,   9,
       3,  22,  24,  45,  57,  40,  57,  36,
     -18,  28,  19,  47,  31,  34,  39,  23,
     -16, -27,  15,   6,   9,  17,  10,   5,
     -22, -23, -30, -16, -16, -23, -36, -32,
     -33, -28, -22, -43,  -5, -32, -20, -41],
    [-74, -35, -18, -18, -11,  15,   4, -17,
     -12,  17,  14,  17,  17,  38,  23,  11,
      10,  17,  23,  15,  20,  45,  44,  13,
      -8,  22,  24,  27,  26,  33,  26,   3,
     -18,  -4,  21,  24,  27,  23,   9, -11,
     -19,  -3,  11,  21,  23,  16,   7,  -9,
     -27, -11,   4,  13,  14,   4,  -5, -17,
     -53, -34, -21, -11, -28, -14, -24, -43],
]


def _build_tables(values, pst):
    """table[piece][square] = value + PST, positive for White, negative for Black."""
    tables = [[0] * 64 for _ in range(12)]
    for ptype in range(6):
        for sq in range(64):
            tables[ptype][sq] = values[ptype] + pst[ptype][sq ^ 56]
            tables[6 + ptype][sq] = -(values[ptype] + pst[ptype][sq])
    return tables


MG_TABLE = _build_tables(MG_VALUE, _MG_PST)
EG_TABLE = _build_tables(EG_VALUE, _EG_PST)
PHASE = [PHASE_WEIGHT[p % 6] for p in range(12)]

# --- masks for pawn structure ---------------------------------------------

ADJACENT_FILES = [(FILES[f - 1] if f > 0 else 0) | (FILES[f + 1] if f < 7 else 0)
                  for f in range(8)]


def _passed_masks(color):
    masks = []
    for sq in range(64):
        f, r = sq & 7, sq >> 3
        files = FILES[f] | ADJACENT_FILES[f]
        ahead = 0
        rows = range(r + 1, 8) if color == WHITE else range(0, r)
        for row in rows:
            ahead |= 0xFF << (8 * row)
        masks.append(files & ahead)
    return masks


PASSED_MASK = [_passed_masks(WHITE), _passed_masks(BLACK)]
PASSED_BONUS_MG = [0, 5, 10, 15, 30, 50, 80, 0]      # by rank from the pawn's side
PASSED_BONUS_EG = [0, 10, 20, 35, 60, 100, 160, 0]
ISOLATED_MG, ISOLATED_EG = -10, -15
DOUBLED_MG, DOUBLED_EG = -10, -25

MOBILITY_MG = [0, 4, 4, 2, 1, 0]
MOBILITY_EG = [0, 4, 5, 4, 2, 0]
ROOK_OPEN_FILE, ROOK_SEMI_OPEN = 25, 12
BISHOP_PAIR_MG, BISHOP_PAIR_EG = 30, 50
SHIELD_MISSING = 12
TEMPO = 12

# How far each square is from the centre, for driving a lone king to the edge
CENTER_DISTANCE = [max(3 - min(sq & 7, 7 - (sq & 7)), 3 - min(sq >> 3, 7 - (sq >> 3)))
                   for sq in range(64)]

_pawn_cache = {}


def _pawn_structure(white_pawns, black_pawns):
    """Pawn terms (White minus Black), cached because pawns move rarely."""
    key = (white_pawns, black_pawns)
    cached = _pawn_cache.get(key)
    if cached is not None:
        return cached
    mg = eg = 0
    for color, own, enemy, sign in ((WHITE, white_pawns, black_pawns, 1),
                                    (BLACK, black_pawns, white_pawns, -1)):
        passed = PASSED_MASK[color]
        bb = own
        while bb:
            low = bb & -bb
            sq = low.bit_length() - 1
            bb ^= low
            f = sq & 7
            if not passed[sq] & enemy:
                rank = (sq >> 3) if color == WHITE else 7 - (sq >> 3)
                mg += sign * PASSED_BONUS_MG[rank]
                eg += sign * PASSED_BONUS_EG[rank]
            if not ADJACENT_FILES[f] & own:
                mg += sign * ISOLATED_MG
                eg += sign * ISOLATED_EG
        for file_mask in FILES:
            count = (own & file_mask).bit_count()
            if count > 1:
                mg += sign * DOUBLED_MG * (count - 1)
                eg += sign * DOUBLED_EG * (count - 1)
    if len(_pawn_cache) > 200_000:
        _pawn_cache.clear()
    _pawn_cache[key] = (mg, eg)
    return mg, eg


def evaluate(board):
    """Score in centipawns from the point of view of the side to move."""
    bb = board.bb
    white_pawns, black_pawns = bb[0], bb[6]
    occupied = board.occ[0] | board.occ[1]

    mg, eg = _pawn_structure(white_pawns, black_pawns)
    mg += board.mg
    eg += board.eg

    for color, sign in ((WHITE, 1), (BLACK, -1)):
        base = color * 6
        own_pawns = bb[base]
        enemy_pawns = bb[6 - base]
        safe = ~(board.occ[color]) & ((1 << 64) - 1)

        # Mobility: how many squares each piece can reach
        for ptype in (1, 2, 3, 4):
            pieces = bb[base + ptype]
            while pieces:
                low = pieces & -pieces
                sq = low.bit_length() - 1
                pieces ^= low
                if ptype == 1:
                    attacks = KNIGHT_ATTACKS[sq]
                elif ptype == 2:
                    attacks = BISHOP_TABLES[sq][occupied & BISHOP_MASKS[sq]]
                elif ptype == 3:
                    attacks = ROOK_TABLES[sq][occupied & ROOK_MASKS[sq]]
                    file_mask = FILES[sq & 7]
                    if not file_mask & own_pawns:
                        bonus = ROOK_OPEN_FILE if not file_mask & enemy_pawns else ROOK_SEMI_OPEN
                        mg += sign * bonus
                        eg += sign * (bonus // 2)
                else:
                    attacks = (ROOK_TABLES[sq][occupied & ROOK_MASKS[sq]]
                               | BISHOP_TABLES[sq][occupied & BISHOP_MASKS[sq]])
                moves = (attacks & safe).bit_count()
                mg += sign * MOBILITY_MG[ptype] * moves
                eg += sign * MOBILITY_EG[ptype] * moves

        if bb[base + 2] & (bb[base + 2] - 1):  # two or more bishops
            mg += sign * BISHOP_PAIR_MG
            eg += sign * BISHOP_PAIR_EG

        # King shelter: pawns directly around the king (middlegame only)
        king_sq = bb[base + 5].bit_length() - 1
        shelter = (KING_ATTACKS[king_sq] & own_pawns).bit_count()
        mg -= sign * SHIELD_MISSING * max(0, 3 - shelter)

    phase = min(board.phase, TOTAL_PHASE)
    score = (mg * phase + eg * (TOTAL_PHASE - phase)) // TOTAL_PHASE
    score = _endgame_adjust(board, score)
    return (score if board.side == WHITE else -score) + TEMPO


def _endgame_adjust(board, score):
    """Endgame knowledge: no mating material means no win, and when one side
    has a lone king, drive it to the edge and bring our king closer."""
    if board.phase > 8 or score == 0:
        return score
    bb = board.bb
    strong = WHITE if score > 0 else BLACK
    weak = strong ^ 1
    strong_pawns = bb[strong * 6]
    strong_material = sum(MG_VALUE[p] * bb[strong * 6 + p].bit_count() for p in range(1, 5))
    weak_material = sum(MG_VALUE[p] * bb[weak * 6 + p].bit_count() for p in range(1, 5))

    if not strong_pawns and strong_material - weak_material < 400:
        return score // 8  # e.g. a lone minor piece can't force mate

    if not bb[weak * 6] and weak_material == 0 and strong_material >= 400:
        strong_king = bb[strong * 6 + 5].bit_length() - 1
        weak_king = bb[weak * 6 + 5].bit_length() - 1
        distance = (abs((strong_king & 7) - (weak_king & 7))
                    + abs((strong_king >> 3) - (weak_king >> 3)))
        bonus = 20 * CENTER_DISTANCE[weak_king] + 8 * (14 - distance)
        return score + bonus if strong == WHITE else score - bonus
    return score
