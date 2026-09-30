"""The chess board: position state, move generation and make/unmake.

Moves are packed into one int:  from | to << 6 | flag << 12

    flag  0 quiet          4 capture
          1 double push    5 en passant capture
          2 castle short   8-11  promotion to N, B, R, Q
          3 castle long    12-15 promotion with capture

so `flag & 4` means "captures something" and `flag & 8` means "promotes".
"""

from .bitboard import (BISHOP, BISHOP_MASKS, BISHOP_TABLES, BLACK, EMPTY, FULL,
                       KING, KING_ATTACKS, KNIGHT, KNIGHT_ATTACKS, NOT_FILE_A,
                       NOT_FILE_H, PAWN, PAWN_ATTACKS, PIECE_CHARS, QUEEN, RANK_3,
                       RANK_6, ROOK, ROOK_MASKS, ROOK_TABLES, WHITE, ZOBRIST_CASTLE,
                       ZOBRIST_EP, ZOBRIST_PIECE, ZOBRIST_SIDE, parse_square,
                       square_name)
from .evaluate import EG_TABLE, MG_TABLE, PHASE

START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

QUIET, DOUBLE_PUSH, KING_CASTLE, QUEEN_CASTLE, CAPTURE, EP_CAPTURE = 0, 1, 2, 3, 4, 5
PROMOTION = 8
PROMO_CHARS = "nbrq"

WHITE_KINGSIDE, WHITE_QUEENSIDE, BLACK_KINGSIDE, BLACK_QUEENSIDE = 1, 2, 4, 8

# castling &= CASTLE_MASK[from] & CASTLE_MASK[to]: moving the king or a rook,
# or capturing a rook on its home square, removes the matching rights
CASTLE_MASK = [15] * 64
CASTLE_MASK[0] = 15 ^ WHITE_QUEENSIDE
CASTLE_MASK[7] = 15 ^ WHITE_KINGSIDE
CASTLE_MASK[4] = 15 ^ (WHITE_KINGSIDE | WHITE_QUEENSIDE)
CASTLE_MASK[56] = 15 ^ BLACK_QUEENSIDE
CASTLE_MASK[63] = 15 ^ BLACK_KINGSIDE
CASTLE_MASK[60] = 15 ^ (BLACK_KINGSIDE | BLACK_QUEENSIDE)


def encode_move(frm, to, flag=QUIET):
    return frm | (to << 6) | (flag << 12)


def move_to_uci(move):
    if move == 0:
        return "0000"
    text = square_name(move & 63) + square_name((move >> 6) & 63)
    flag = move >> 12
    if flag & PROMOTION:
        text += PROMO_CHARS[flag & 3]
    return text


class Board:
    def __init__(self, fen=START_FEN):
        self.set_fen(fen)

    # --- setting up ---------------------------------------------------------

    def set_fen(self, fen):
        parts = fen.split()
        if len(parts) < 4:
            raise ValueError(f"FEN needs at least 4 fields: {fen!r}")
        self.bb = [0] * 12
        self.occ = [0, 0]
        self.squares = [EMPTY] * 64
        self.mg = self.eg = self.phase = 0

        rows = parts[0].split("/")
        if len(rows) != 8:
            raise ValueError(f"FEN board needs 8 ranks: {fen!r}")
        for i, row in enumerate(rows):
            rank, file = 7 - i, 0
            for char in row:
                if char.isdigit():
                    file += int(char)
                elif char in PIECE_CHARS and file < 8:
                    self._put(PIECE_CHARS.index(char), rank * 8 + file)
                    file += 1
                else:
                    raise ValueError(f"bad FEN board: {fen!r}")
            if file != 8:
                raise ValueError(f"FEN rank {rank + 1} doesn't have 8 squares: {fen!r}")
        for color in (WHITE, BLACK):
            if self.bb[color * 6 + KING].bit_count() != 1:
                raise ValueError("each side needs exactly one king")

        self.side = WHITE if parts[1] == "w" else BLACK
        self.castling = 0
        for char, right in zip("KQkq", (1, 2, 4, 8)):
            if char in parts[2]:
                self.castling |= right
        self.ep = parse_square(parts[3]) if parts[3] != "-" else -1
        self.halfmove = int(parts[4]) if len(parts) > 4 else 0
        self.fullmove = int(parts[5]) if len(parts) > 5 else 1
        self.hash = self.compute_hash()
        self.stack = []
        self.history = [self.hash]

    def _put(self, piece, sq):
        bit = 1 << sq
        self.bb[piece] |= bit
        self.occ[piece // 6] |= bit
        self.squares[sq] = piece
        self.mg += MG_TABLE[piece][sq]
        self.eg += EG_TABLE[piece][sq]
        self.phase += PHASE[piece]

    def compute_hash(self):
        """Hash from scratch; make_move keeps it updated incrementally."""
        h = 0
        for sq, piece in enumerate(self.squares):
            if piece != EMPTY:
                h ^= ZOBRIST_PIECE[piece][sq]
        h ^= ZOBRIST_CASTLE[self.castling]
        if self.ep != -1:
            h ^= ZOBRIST_EP[self.ep & 7]
        if self.side == BLACK:
            h ^= ZOBRIST_SIDE
        return h

    def fen(self):
        rows = []
        for rank in range(7, -1, -1):
            row, gap = "", 0
            for file in range(8):
                piece = self.squares[rank * 8 + file]
                if piece == EMPTY:
                    gap += 1
                else:
                    row += (str(gap) if gap else "") + PIECE_CHARS[piece]
                    gap = 0
            rows.append(row + (str(gap) if gap else ""))
        castling = "".join(c for c, r in zip("KQkq", (1, 2, 4, 8)) if self.castling & r) or "-"
        ep = square_name(self.ep) if self.ep != -1 else "-"
        side = "w" if self.side == WHITE else "b"
        return f"{'/'.join(rows)} {side} {castling} {ep} {self.halfmove} {self.fullmove}"

    def copy(self):
        return Board(self.fen())

    def __str__(self):
        lines = []
        for rank in range(7, -1, -1):
            cells = []
            for file in range(8):
                piece = self.squares[rank * 8 + file]
                cells.append(PIECE_CHARS[piece] if piece != EMPTY else ".")
            lines.append(f"{rank + 1}  {' '.join(cells)}")
        lines.append("   a b c d e f g h")
        return "\n".join(lines)

    # --- attacks ------------------------------------------------------------

    def is_attacked(self, sq, by):
        bb = self.bb
        base = by * 6
        if PAWN_ATTACKS[by ^ 1][sq] & bb[base]:
            return True
        if KNIGHT_ATTACKS[sq] & bb[base + 1]:
            return True
        if KING_ATTACKS[sq] & bb[base + 5]:
            return True
        occupied = self.occ[0] | self.occ[1]
        if BISHOP_TABLES[sq][occupied & BISHOP_MASKS[sq]] & (bb[base + 2] | bb[base + 4]):
            return True
        return bool(ROOK_TABLES[sq][occupied & ROOK_MASKS[sq]] & (bb[base + 3] | bb[base + 4]))

    def in_check(self):
        return self.is_attacked(self.bb[self.side * 6 + KING].bit_length() - 1, self.side ^ 1)

    # --- move generation ----------------------------------------------------

    def generate_moves(self, captures_only=False):
        """Pseudo-legal moves: they may leave our own king in check, which
        make_move detects. Castling is checked fully here."""
        moves = []
        add = moves.append
        us = self.side
        them = us ^ 1
        bb = self.bb
        own = self.occ[us]
        enemy = self.occ[them]
        occupied = own | enemy
        empty = FULL ^ occupied
        pawns = bb[us * 6]

        if us == WHITE:
            push = (pawns << 8) & empty
            double = ((push & RANK_3) << 8) & empty
            left = ((pawns & NOT_FILE_A) << 7) & enemy
            right = ((pawns & NOT_FILE_H) << 9) & enemy
            forward, left_step, right_step = 8, 7, 9
            last_rank = 0xFF << 56
        else:
            push = (pawns >> 8) & empty
            double = ((push & RANK_6) >> 8) & empty
            left = ((pawns & NOT_FILE_A) >> 9) & enemy
            right = ((pawns & NOT_FILE_H) >> 7) & enemy
            forward, left_step, right_step = -8, -9, -7
            last_rank = 0xFF

        for targets, step, capture in ((push, forward, 0), (left, left_step, CAPTURE),
                                       (right, right_step, CAPTURE)):
            while targets:
                low = targets & -targets
                to = low.bit_length() - 1
                targets ^= low
                base = (to - step) | (to << 6)
                if low & last_rank:
                    flag = PROMOTION | capture
                    add(base | ((flag | 3) << 12))  # queen first
                    add(base | (flag << 12))
                    add(base | ((flag | 1) << 12))
                    add(base | ((flag | 2) << 12))
                elif capture or not captures_only:
                    add(base | (capture << 12))

        if not captures_only:
            while double:
                low = double & -double
                to = low.bit_length() - 1
                double ^= low
                add((to - 2 * forward) | (to << 6) | (DOUBLE_PUSH << 12))

        if self.ep != -1:
            attackers = PAWN_ATTACKS[them][self.ep] & pawns
            while attackers:
                low = attackers & -attackers
                attackers ^= low
                add((low.bit_length() - 1) | (self.ep << 6) | (EP_CAPTURE << 12))

        allowed = enemy if captures_only else FULL ^ own
        base_piece = us * 6
        for ptype in (KNIGHT, BISHOP, ROOK, QUEEN, KING):
            pieces = bb[base_piece + ptype]
            while pieces:
                low = pieces & -pieces
                frm = low.bit_length() - 1
                pieces ^= low
                if ptype == KNIGHT:
                    attacks = KNIGHT_ATTACKS[frm]
                elif ptype == BISHOP:
                    attacks = BISHOP_TABLES[frm][occupied & BISHOP_MASKS[frm]]
                elif ptype == ROOK:
                    attacks = ROOK_TABLES[frm][occupied & ROOK_MASKS[frm]]
                elif ptype == QUEEN:
                    attacks = (ROOK_TABLES[frm][occupied & ROOK_MASKS[frm]]
                               | BISHOP_TABLES[frm][occupied & BISHOP_MASKS[frm]])
                else:
                    attacks = KING_ATTACKS[frm]
                attacks &= allowed
                while attacks:
                    target = attacks & -attacks
                    attacks ^= target
                    to = target.bit_length() - 1
                    add(frm | (to << 6) | ((CAPTURE << 12) if target & enemy else 0))

        if not captures_only and self.castling:
            if us == WHITE:
                if (self.castling & WHITE_KINGSIDE and not occupied & 0x60
                        and not self.is_attacked(4, them) and not self.is_attacked(5, them)
                        and not self.is_attacked(6, them)):
                    add(encode_move(4, 6, KING_CASTLE))
                if (self.castling & WHITE_QUEENSIDE and not occupied & 0x0E
                        and not self.is_attacked(4, them) and not self.is_attacked(3, them)
                        and not self.is_attacked(2, them)):
                    add(encode_move(4, 2, QUEEN_CASTLE))
            else:
                if (self.castling & BLACK_KINGSIDE and not occupied & (0x60 << 56)
                        and not self.is_attacked(60, them) and not self.is_attacked(61, them)
                        and not self.is_attacked(62, them)):
                    add(encode_move(60, 62, KING_CASTLE))
                if (self.castling & BLACK_QUEENSIDE and not occupied & (0x0E << 56)
                        and not self.is_attacked(60, them) and not self.is_attacked(59, them)
                        and not self.is_attacked(58, them)):
                    add(encode_move(60, 58, QUEEN_CASTLE))
        return moves

    def legal_moves(self):
        legal = []
        for move in self.generate_moves():
            if self.make_move(move):
                self.unmake_move()
                legal.append(move)
        return legal

    # --- making and unmaking moves ------------------------------------------

    def make_move(self, move):
        """Play a pseudo-legal move. If it leaves our king in check it is
        taken back and False is returned."""
        frm = move & 63
        to = (move >> 6) & 63
        flag = move >> 12
        us = self.side
        them = us ^ 1
        bb = self.bb
        occ = self.occ
        squares = self.squares
        piece = squares[frm]
        captured = squares[to]

        self.stack.append((move, captured, self.castling, self.ep, self.halfmove,
                           self.hash, self.mg, self.eg, self.phase))

        h = self.hash ^ ZOBRIST_CASTLE[self.castling] ^ ZOBRIST_SIDE
        if self.ep != -1:
            h ^= ZOBRIST_EP[self.ep & 7]
        mg = self.mg
        eg = self.eg
        from_bit = 1 << frm
        to_bit = 1 << to

        if captured != EMPTY:
            bb[captured] ^= to_bit
            occ[them] ^= to_bit
            h ^= ZOBRIST_PIECE[captured][to]
            mg -= MG_TABLE[captured][to]
            eg -= EG_TABLE[captured][to]
            self.phase -= PHASE[captured]

        move_bits = from_bit | to_bit
        bb[piece] ^= move_bits
        occ[us] ^= move_bits
        squares[frm] = EMPTY
        squares[to] = piece
        h ^= ZOBRIST_PIECE[piece][frm] ^ ZOBRIST_PIECE[piece][to]
        mg += MG_TABLE[piece][to] - MG_TABLE[piece][frm]
        eg += EG_TABLE[piece][to] - EG_TABLE[piece][frm]

        self.ep = -1
        if flag:
            if flag == DOUBLE_PUSH:
                self.ep = (frm + to) >> 1
                h ^= ZOBRIST_EP[self.ep & 7]
            elif flag == EP_CAPTURE:
                cap_sq = to - 8 if us == WHITE else to + 8
                cap_piece = them * 6
                cap_bit = 1 << cap_sq
                bb[cap_piece] ^= cap_bit
                occ[them] ^= cap_bit
                squares[cap_sq] = EMPTY
                h ^= ZOBRIST_PIECE[cap_piece][cap_sq]
                mg -= MG_TABLE[cap_piece][cap_sq]
                eg -= EG_TABLE[cap_piece][cap_sq]
            elif flag == KING_CASTLE or flag == QUEEN_CASTLE:
                rook_from, rook_to = (to + 1, to - 1) if flag == KING_CASTLE else (to - 2, to + 1)
                rook = us * 6 + ROOK
                rook_bits = (1 << rook_from) | (1 << rook_to)
                bb[rook] ^= rook_bits
                occ[us] ^= rook_bits
                squares[rook_from] = EMPTY
                squares[rook_to] = rook
                h ^= ZOBRIST_PIECE[rook][rook_from] ^ ZOBRIST_PIECE[rook][rook_to]
                mg += MG_TABLE[rook][rook_to] - MG_TABLE[rook][rook_from]
                eg += EG_TABLE[rook][rook_to] - EG_TABLE[rook][rook_from]
            elif flag & PROMOTION:
                promoted = us * 6 + (flag & 3) + 1
                bb[piece] ^= to_bit
                bb[promoted] ^= to_bit
                squares[to] = promoted
                h ^= ZOBRIST_PIECE[piece][to] ^ ZOBRIST_PIECE[promoted][to]
                mg += MG_TABLE[promoted][to] - MG_TABLE[piece][to]
                eg += EG_TABLE[promoted][to] - EG_TABLE[piece][to]
                self.phase += PHASE[promoted]

        self.castling &= CASTLE_MASK[frm] & CASTLE_MASK[to]
        h ^= ZOBRIST_CASTLE[self.castling]
        if piece == us * 6 or captured != EMPTY:
            self.halfmove = 0
        else:
            self.halfmove += 1
        if us == BLACK:
            self.fullmove += 1
        self.side = them
        self.hash = h
        self.mg = mg
        self.eg = eg
        self.history.append(h)

        if self.is_attacked(bb[us * 6 + KING].bit_length() - 1, them):
            self.unmake_move()
            return False
        return True

    def unmake_move(self):
        move, captured, castling, ep, halfmove, h, mg, eg, phase = self.stack.pop()
        self.history.pop()
        us = self.side ^ 1
        them = self.side
        self.side = us
        self.castling = castling
        self.ep = ep
        self.halfmove = halfmove
        self.hash = h
        self.mg = mg
        self.eg = eg
        self.phase = phase
        if us == BLACK:
            self.fullmove -= 1
        if move == 0:  # null move
            return

        frm = move & 63
        to = (move >> 6) & 63
        flag = move >> 12
        bb = self.bb
        occ = self.occ
        squares = self.squares
        from_bit = 1 << frm
        to_bit = 1 << to
        piece = squares[to]

        if flag & PROMOTION:
            bb[piece] ^= to_bit
            piece = us * 6
            bb[piece] ^= to_bit
        move_bits = from_bit | to_bit
        bb[piece] ^= move_bits
        occ[us] ^= move_bits
        squares[frm] = piece
        squares[to] = captured
        if captured != EMPTY:
            bb[captured] ^= to_bit
            occ[them] ^= to_bit

        if flag == EP_CAPTURE:
            cap_sq = to - 8 if us == WHITE else to + 8
            cap_bit = 1 << cap_sq
            bb[them * 6] ^= cap_bit
            occ[them] ^= cap_bit
            squares[cap_sq] = them * 6
        elif flag == KING_CASTLE or flag == QUEEN_CASTLE:
            rook_from, rook_to = (to + 1, to - 1) if flag == KING_CASTLE else (to - 2, to + 1)
            rook = us * 6 + ROOK
            rook_bits = (1 << rook_from) | (1 << rook_to)
            bb[rook] ^= rook_bits
            occ[us] ^= rook_bits
            squares[rook_to] = EMPTY
            squares[rook_from] = rook

    def make_null_move(self):
        """Pass the turn (used by null-move pruning). Undo with unmake_move."""
        self.stack.append((0, EMPTY, self.castling, self.ep, self.halfmove,
                           self.hash, self.mg, self.eg, self.phase))
        h = self.hash ^ ZOBRIST_SIDE
        if self.ep != -1:
            h ^= ZOBRIST_EP[self.ep & 7]
            self.ep = -1
        if self.side == BLACK:
            self.fullmove += 1
        self.side ^= 1
        self.halfmove = 0
        self.hash = h
        self.history.append(h)

    # --- game state ---------------------------------------------------------

    def is_repetition(self):
        """Has this position happened before since the last capture or pawn
        move? (Inside a search, one repeat is enough to call it a draw.)"""
        history = self.history
        key = history[-1]
        stop = max(len(history) - 1 - self.halfmove, 0)
        i = len(history) - 3
        while i >= stop:
            if history[i] == key:
                return True
            i -= 2
        return False

    def repetition_count(self):
        history = self.history
        start = max(len(history) - 1 - self.halfmove, 0)
        return history[start:].count(history[-1])

    def has_non_pawn_material(self, color):
        base = color * 6
        bb = self.bb
        return bool(bb[base + 1] | bb[base + 2] | bb[base + 3] | bb[base + 4])

    def insufficient_material(self):
        # phase <= 1 means at most one knight or bishop and no rooks or queens
        return self.phase <= 1 and not (self.bb[0] | self.bb[6])

    def outcome(self):
        """None while the game is on, otherwise a description of the result."""
        if not self.legal_moves():
            if self.in_check():
                return "checkmate: " + ("black" if self.side == WHITE else "white") + " wins"
            return "draw by stalemate"
        if self.halfmove >= 100:
            return "draw by the fifty-move rule"
        if self.repetition_count() >= 3:
            return "draw by threefold repetition"
        if self.insufficient_material():
            return "draw by insufficient material"
        return None

    # --- notation -----------------------------------------------------------

    def san(self, move):
        """Standard algebraic notation, e.g. Nf3, exd5, O-O, e8=Q+."""
        frm = move & 63
        to = (move >> 6) & 63
        flag = move >> 12
        ptype = self.squares[frm] % 6
        if flag == KING_CASTLE:
            text = "O-O"
        elif flag == QUEEN_CASTLE:
            text = "O-O-O"
        elif ptype == PAWN:
            text = square_name(frm)[0] + "x" if flag & CAPTURE else ""
            text += square_name(to)
            if flag & PROMOTION:
                text += "=" + PROMO_CHARS[flag & 3].upper()
        else:
            text = "NBRQK"[ptype - 1]
            rivals = [m & 63 for m in self.legal_moves()
                      if (m >> 6) & 63 == to and m & 63 != frm
                      and self.squares[m & 63] == self.squares[frm]]
            if rivals:
                name = square_name(frm)
                if all(r & 7 != frm & 7 for r in rivals):
                    text += name[0]
                elif all(r >> 3 != frm >> 3 for r in rivals):
                    text += name[1]
                else:
                    text += name
            if flag & CAPTURE:
                text += "x"
            text += square_name(to)
        self.make_move(move)
        if self.in_check():
            text += "#" if not self.legal_moves() else "+"
        self.unmake_move()
        return text

    def parse_move(self, text):
        """Accept SAN (Nf3, exd5, O-O) or UCI (g1f3, e7e8q) notation."""
        text = text.strip()
        legal = self.legal_moves()
        for move in legal:
            if move_to_uci(move) == text.lower():
                return move
        wanted = text.replace("0", "O").rstrip("+#!?")
        for move in legal:
            if self.san(move).rstrip("+#") == wanted:
                return move
        raise ValueError(f"illegal or unrecognised move: {text!r}")


def perft(board, depth):
    """Count the leaf nodes of the legal move tree: the standard way to prove
    a move generator is correct, by comparing with known totals."""
    if depth == 0:
        return 1
    nodes = 0
    for move in board.generate_moves():
        if board.make_move(move):
            nodes += perft(board, depth - 1) if depth > 1 else 1
            board.unmake_move()
    return nodes
