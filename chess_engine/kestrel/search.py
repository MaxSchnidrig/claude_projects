"""Search: finding the best move.

The engine looks ahead with *negamax alpha-beta*: "my best score is the
negative of my opponent's best score", and branches that can't affect the
result are cut off. Alpha-beta cuts the most when the best move is tried
first, so most of this file is about searching less and in a better order:

* Iterative deepening: search 1 move deep, then 2, then 3... Each pass fills
  the transposition table, which makes the next pass's move ordering better.
* Transposition table: a big hash table of positions already searched
  (reached by different move orders), with their score, depth and best move.
* Move ordering: hash move, then captures by MVV-LVA (most valuable victim,
  least valuable attacker), then killer moves, then the history heuristic.
* Principal variation search: after the first move, prove the others are
  worse with a cheap null window, and only re-search if one surprises us.
* Quiescence search: at the end of the main search, keep playing captures so
  we never stop in the middle of an exchange.
* Pruning and reductions: null-move pruning, reverse futility pruning,
  late move reductions and late move pruning skip or shorten hopeless lines.
* Check extensions and aspiration windows.
"""

import math
import time

from .bitboard import KING, PAWN
from .board import EP_CAPTURE, move_to_uci
from .evaluate import evaluate

INFINITY = 32000
MATE = 31000
MATE_BOUND = MATE - 1000  # scores beyond this mean "mate in N"
MAX_PLY = 100

EXACT, LOWER_BOUND, UPPER_BOUND = 0, 1, 2

VICTIM_VALUE = [100, 320, 330, 500, 900, 0]

# Late move reduction amounts, by depth and move number
LMR = [[0] * 64 for _ in range(64)]
for _d in range(1, 64):
    for _m in range(1, 64):
        LMR[_d][_m] = int(0.8 + math.log(_d) * math.log(_m) / 2.4)
LATE_MOVE_LIMIT = [0, 6, 10, 16]


class SearchStopped(Exception):
    pass


class Searcher:
    def __init__(self, hash_bits=20):
        self.tt_size = 1 << hash_bits
        self.tt = [None] * self.tt_size
        self.killers = [[0, 0] for _ in range(MAX_PLY + 1)]
        self.history = [[0] * 64 for _ in range(12)]
        self.nodes = 0
        self.stop = False  # set from another thread to abort a search

    def clear(self):
        self.tt = [None] * self.tt_size
        self.history = [[0] * 64 for _ in range(12)]

    # --- transposition table ------------------------------------------------
    # Mate scores are stored relative to the node, not the root, so they stay
    # correct when the same position is reached at a different distance.

    def _tt_store(self, key, depth, flag, score, move, ply):
        if score > MATE_BOUND:
            score += ply
        elif score < -MATE_BOUND:
            score -= ply
        index = key & (self.tt_size - 1)
        old = self.tt[index]
        if old is None or old[0] != key or depth >= old[1] or flag == EXACT:
            self.tt[index] = (key, depth, flag, score, move)

    def _tt_probe(self, key):
        entry = self.tt[key & (self.tt_size - 1)]
        return entry if entry is not None and entry[0] == key else None

    # --- the main entry point ------------------------------------------------

    def search(self, board, max_depth=MAX_PLY - 1, time_limit=None, on_info=None):
        """Return (best_move, score). time_limit is in seconds."""
        self.board = board
        self.nodes = 0
        self.stop = False
        self.start_time = time.perf_counter()
        self.deadline = self.start_time + time_limit if time_limit else None
        self.killers = [[0, 0] for _ in range(MAX_PLY + 1)]
        for row in self.history:
            for i in range(64):
                row[i] //= 8

        root_moves = board.legal_moves()
        if not root_moves:
            return 0, (-MATE if board.in_check() else 0)
        best_move, best_score = root_moves[0], 0
        stack_size = len(board.stack)

        for depth in range(1, max_depth + 1):
            self.root_best = 0
            try:
                score = self._aspiration(depth, best_score)
            except SearchStopped:
                while len(board.stack) > stack_size:
                    board.unmake_move()
                if self.root_best:  # a move from the unfinished pass beat the old best
                    best_move = self.root_best
                break
            best_move = self.root_best or best_move
            best_score = score
            if on_info:
                on_info(depth, score, self.nodes, time.perf_counter() - self.start_time,
                        self.principal_variation(best_move))
            if len(root_moves) == 1 and depth >= 4:
                break  # only one legal move: no need to think hard
            if abs(score) > MATE_BOUND and MATE - abs(score) <= depth:
                break  # found a forced mate that can't get shorter
            if self.deadline:
                elapsed = time.perf_counter() - self.start_time
                if elapsed > 0.5 * (self.deadline - self.start_time):
                    break  # the next pass would probably not finish
        return best_move, best_score

    def _aspiration(self, depth, previous):
        if depth < 5 or abs(previous) > MATE_BOUND:
            return self._search(depth, -INFINITY, INFINITY, 0, True)
        window = 35
        alpha, beta = previous - window, previous + window
        while True:
            score = self._search(depth, alpha, beta, 0, True)
            if score <= alpha:
                alpha = max(alpha - window, -INFINITY)
            elif score >= beta:
                beta = min(beta + window, INFINITY)
            else:
                return score
            window *= 2

    def principal_variation(self, first_move, limit=12):
        """Follow best moves through the transposition table."""
        board = self.board
        pv = []
        move = first_move
        seen = set()
        while move and len(pv) < limit and board.hash not in seen:
            if move not in board.legal_moves():
                break
            seen.add(board.hash)
            board.make_move(move)
            pv.append(move)
            entry = self._tt_probe(board.hash)
            move = entry[4] if entry else 0
        for _ in pv:
            board.unmake_move()
        return pv

    def _check_time(self):
        if self.stop or (self.deadline and time.perf_counter() > self.deadline):
            raise SearchStopped()

    # --- move ordering -------------------------------------------------------

    def _order(self, moves, tt_move, ply):
        squares = self.board.squares
        killer1, killer2 = self.killers[ply]
        history = self.history
        scored = []
        for move in moves:
            if move == tt_move:
                score = 10_000_000
            else:
                flag = move >> 12
                if flag & 4:
                    victim = PAWN if flag == EP_CAPTURE else squares[(move >> 6) & 63] % 6
                    score = 1_000_000 + VICTIM_VALUE[victim] * 10 - squares[move & 63] % 6
                    if flag & 8:
                        score += 1000
                elif flag & 8:
                    score = 950_000 if flag & 3 == 3 else -1000  # under-promotions last
                elif move == killer1:
                    score = 900_000
                elif move == killer2:
                    score = 800_000
                else:
                    score = history[squares[move & 63]][(move >> 6) & 63]
            scored.append((score, move))
        scored.sort(reverse=True)
        return [move for _, move in scored]

    # --- alpha-beta ----------------------------------------------------------

    def _search(self, depth, alpha, beta, ply, allow_null):
        board = self.board
        self.nodes += 1
        if self.nodes & 1023 == 0:
            self._check_time()
        pv_node = beta - alpha > 1

        if ply:
            if board.halfmove >= 100 or board.is_repetition() or board.insufficient_material():
                return 0
            # Mate distance pruning: a shorter mate was already found
            alpha = max(alpha, -MATE + ply)
            beta = min(beta, MATE - ply - 1)
            if alpha >= beta:
                return alpha

        in_check = board.in_check()
        if in_check:
            depth += 1  # check extension: don't stop searching mid-attack
        if depth <= 0:
            return self._quiesce(alpha, beta, ply)
        if ply >= MAX_PLY:
            return evaluate(board)

        key = board.hash
        entry = self._tt_probe(key)
        tt_move = 0
        if entry:
            tt_move = entry[4]
            if entry[1] >= depth and not pv_node:
                score, flag = entry[3], entry[2]
                if score > MATE_BOUND:
                    score -= ply
                elif score < -MATE_BOUND:
                    score += ply
                if (flag == EXACT or (flag == LOWER_BOUND and score >= beta)
                        or (flag == UPPER_BOUND and score <= alpha)):
                    return score

        if not in_check and not pv_node:
            static = evaluate(board)
            # Reverse futility: we're so far ahead a quiet move can't ruin it
            if depth <= 6 and static - 85 * depth >= beta and abs(beta) < MATE_BOUND:
                return static - 85 * depth
            # Null move: if passing still beats beta, a real move surely will
            if (allow_null and depth >= 3 and static >= beta
                    and board.has_non_pawn_material(board.side)):
                reduction = 3 + depth // 6
                board.make_null_move()
                score = -self._search(depth - 1 - reduction, -beta, -beta + 1, ply + 1, False)
                board.unmake_move()
                if score >= beta:
                    return beta if score > MATE_BOUND else score
        else:
            static = None

        moves = self._order(board.generate_moves(), tt_move, ply)
        best_score = -INFINITY
        best_move = 0
        legal = 0
        original_alpha = alpha

        for move in moves:
            if not board.make_move(move):
                continue
            legal += 1
            quiet = not (move >> 12) & 12  # not a capture or promotion

            if legal == 1:
                score = -self._search(depth - 1, -beta, -alpha, ply + 1, True)
            else:
                gives_check = board.in_check()
                # Late move pruning: near the leaves, skip quiet moves ordered last
                if (quiet and not pv_node and not in_check and not gives_check
                        and depth <= 3 and legal > LATE_MOVE_LIMIT[depth]
                        and best_score > -MATE_BOUND):
                    board.unmake_move()
                    continue
                reduction = 0
                if depth >= 3 and quiet and not in_check and not gives_check:
                    reduction = LMR[min(depth, 63)][min(legal, 63)]
                    if pv_node:
                        reduction -= 1
                    reduction = max(0, min(reduction, depth - 2))
                score = -self._search(depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, True)
                if score > alpha and reduction:
                    score = -self._search(depth - 1, -alpha - 1, -alpha, ply + 1, True)
                if alpha < score < beta:
                    score = -self._search(depth - 1, -beta, -alpha, ply + 1, True)
            board.unmake_move()

            if score > best_score:
                best_score = score
                best_move = move
                if score > alpha:
                    alpha = score
                    if ply == 0:
                        self.root_best = move
                    if alpha >= beta:
                        if quiet:
                            killers = self.killers[ply]
                            if killers[0] != move:
                                killers[1] = killers[0]
                                killers[0] = move
                            row = self.history[board.squares[move & 63]]
                            to = (move >> 6) & 63
                            row[to] = min(row[to] + depth * depth, 700_000)
                        break

        if legal == 0:
            return -MATE + ply if in_check else 0

        if best_score >= beta:
            flag = LOWER_BOUND
        elif best_score > original_alpha:
            flag = EXACT
        else:
            flag = UPPER_BOUND
        self._tt_store(key, depth, flag, best_score, best_move, ply)
        return best_score

    def _quiesce(self, alpha, beta, ply):
        """Only look at captures (and promotions) until the position is quiet."""
        board = self.board
        self.nodes += 1
        if self.nodes & 1023 == 0:
            self._check_time()

        stand_pat = evaluate(board)
        if stand_pat >= beta or ply >= MAX_PLY:
            return stand_pat
        if stand_pat > alpha:
            alpha = stand_pat

        squares = board.squares
        scored = []
        for move in board.generate_moves(captures_only=True):
            flag = move >> 12
            victim = PAWN if flag == EP_CAPTURE else (squares[(move >> 6) & 63] % 6
                                                      if flag & 4 else KING)
            gain = VICTIM_VALUE[victim] + (800 if flag & 8 else 0)
            # Delta pruning: even winning this piece can't lift us to alpha
            if stand_pat + gain + 200 < alpha:
                continue
            scored.append((gain * 10 - squares[move & 63] % 6, move))
        scored.sort(reverse=True)

        best = stand_pat
        for _, move in scored:
            if not board.make_move(move):
                continue
            score = -self._quiesce(-beta, -alpha, ply + 1)
            board.unmake_move()
            if score > best:
                best = score
                if score > alpha:
                    alpha = score
                    if alpha >= beta:
                        break
        return best


def format_score(score):
    if abs(score) > MATE_BOUND:
        moves = (MATE - abs(score) + 1) // 2
        return f"mate {moves if score > 0 else -moves}"
    return f"cp {score}"


def format_info(depth, score, nodes, elapsed, pv):
    nps = int(nodes / elapsed) if elapsed > 0 else 0
    return (f"info depth {depth} score {format_score(score)} nodes {nodes} nps {nps} "
            f"time {int(elapsed * 1000)} pv {' '.join(move_to_uci(m) for m in pv)}")
