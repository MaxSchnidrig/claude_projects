import unittest

from kestrel.board import Board, move_to_uci
from kestrel.search import MATE_BOUND, Searcher
from kestrel.uci import UciEngine

# (description, FEN, acceptable best moves in UCI notation)
TACTICS = [
    ("back rank mate in 1", "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1", {"d1d8"}),
    ("mate in 2 with a queen sacrifice",
     "r1b2k1r/ppp1bppp/8/1B1Q4/5q2/2P5/PPP2PPP/R3R1K1 w - - 1 0", {"d5d8"}),
    ("smothered mate in 2", "6rk/6pp/8/6N1/8/8/1Q6/6K1 w - - 0 1", {"b2g7", "g5f7"}),
    ("win a hanging queen", "rnb1kbnr/pppp1ppp/8/4p1q1/4P3/3P4/PPP2PPP/RNBQKBNR w KQkq - 0 1",
     {"c1g5"}),
    ("knight fork of king and queen", "4k3/8/8/3q4/8/8/8/3NK3 w - - 0 1", {"d1e3", "d1c3"}),
    ("promote the passed pawn", "8/5P1k/8/8/8/8/8/6K1 w - - 0 1", {"f7f8q"}),
]


class SearchTests(unittest.TestCase):
    def best(self, fen, seconds=5, depth=64):
        move, score = Searcher(hash_bits=16).search(Board(fen), max_depth=depth,
                                                    time_limit=seconds)
        return move_to_uci(move), score

    def test_tactics(self):
        for name, fen, answers in TACTICS:
            with self.subTest(name):
                move, _ = self.best(fen)
                self.assertIn(move, answers)

    def test_reports_mate_score(self):
        _, score = self.best("6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1")
        self.assertGreater(score, MATE_BOUND)

    def test_avoids_stalemating_when_winning(self):
        # Qf7 or Qg6 would stalemate the black king; the engine must not.
        board = Board("7k/8/6K1/8/8/8/8/5Q2 w - - 0 1")
        move, _ = Searcher(hash_bits=16).search(board, time_limit=5)
        board.make_move(move)
        self.assertNotEqual(board.outcome(), "draw by stalemate")

    def test_mates_with_king_and_rook(self):
        """Play K+R vs K out to mate, with Black choosing its own moves."""
        board = Board("8/8/8/4k3/8/8/8/R3K3 w - - 0 1")
        searcher = Searcher(hash_bits=16)
        for _ in range(60):
            if board.outcome():
                break
            move, _ = searcher.search(board, time_limit=0.5)
            board.make_move(move)
        self.assertIn("checkmate", board.outcome() or "")

    def test_search_leaves_board_unchanged(self):
        board = Board("r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP1B1PPP/R2QKB1R w KQ - 0 8")
        fen = board.fen()
        Searcher(hash_bits=16).search(board, time_limit=0.3)  # stopped mid-search
        self.assertEqual(board.fen(), fen)
        self.assertEqual(board.stack, [])


class UciTests(unittest.TestCase):
    def test_go_returns_a_legal_bestmove(self):
        lines = []
        engine = UciEngine(output=lines.append)
        for command in ("uci", "isready", "position startpos moves e2e4 e7e5", "go depth 4"):
            engine.handle(command)
        engine.wait()
        self.assertIn("uciok", lines)
        self.assertIn("readyok", lines)
        bestmove = lines[-1].split()[1]
        board = Board()
        board.make_move(board.parse_move("e4"))
        board.make_move(board.parse_move("e5"))
        self.assertIn(bestmove, {move_to_uci(m) for m in board.legal_moves()})


if __name__ == "__main__":
    unittest.main()
