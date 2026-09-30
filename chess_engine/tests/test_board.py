import random
import unittest

from kestrel.board import START_FEN, Board, move_to_uci, perft
from kestrel.evaluate import EG_TABLE, MG_TABLE

# Known-correct perft totals from the Chess Programming Wiki
PERFT_CASES = [
    (START_FEN, [20, 400, 8902]),
    ("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", [48, 2039]),
    ("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812, 43238]),
    ("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264, 9467]),
    ("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486]),
    ("r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", [46, 2079]),
]


class PerftTests(unittest.TestCase):
    def test_perft(self):
        for fen, expected in PERFT_CASES:
            board = Board(fen)
            for depth, count in enumerate(expected, 1):
                with self.subTest(fen=fen, depth=depth):
                    self.assertEqual(perft(board, depth), count)
            self.assertEqual(board.fen(), fen)  # make/unmake restored everything


class BoardTests(unittest.TestCase):
    def test_fen_round_trip(self):
        for fen, _ in PERFT_CASES:
            self.assertEqual(Board(fen).fen(), fen)

    def test_incremental_state_matches_recomputed(self):
        """Play random games; the hash and evaluation totals that make_move
        updates incrementally must always equal a fresh computation."""
        rng = random.Random(1)
        for _ in range(20):
            board = Board()
            for _ in range(80):
                moves = board.legal_moves()
                if not moves:
                    break
                board.make_move(rng.choice(moves))
                fresh = Board(board.fen())
                self.assertEqual(board.hash, fresh.hash)
                self.assertEqual(board.mg, fresh.mg)
                self.assertEqual(board.eg, fresh.eg)
                self.assertEqual(board.phase, fresh.phase)
                self.assertEqual(board.bb, fresh.bb)
            while board.stack:
                board.unmake_move()
            self.assertEqual(board.fen(), START_FEN)

    def test_evaluation_tables_are_symmetric(self):
        for ptype in range(6):
            for sq in range(64):
                self.assertEqual(MG_TABLE[ptype][sq], -MG_TABLE[6 + ptype][sq ^ 56])
                self.assertEqual(EG_TABLE[ptype][sq], -EG_TABLE[6 + ptype][sq ^ 56])

    def test_san(self):
        board = Board("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        sans = {board.san(m) for m in board.legal_moves()}
        self.assertIn("O-O", sans)
        self.assertIn("O-O-O", sans)
        self.assertIn("Bxa6", sans)
        self.assertIn("Nxf7", sans)
        self.assertIn("Rb1", sans)

    def test_san_disambiguation_and_promotion(self):
        board = Board("4k3/1P6/8/8/8/8/4K3/R6R w - - 0 1")
        sans = {board.san(m) for m in board.legal_moves()}
        self.assertIn("b8=Q+", sans)
        self.assertIn("Rad1", sans)
        self.assertIn("Rhd1", sans)

    def test_parse_move(self):
        board = Board()
        for text in ("e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "O-O"):
            board.make_move(board.parse_move(text))
        self.assertEqual(move_to_uci(board.stack[-1][0]), "e1g1")
        with self.assertRaises(ValueError):
            board.parse_move("Qh5xh7")

    def test_outcomes(self):
        self.assertIn("checkmate", Board("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1").outcome())
        self.assertIn("stalemate", Board("7k/8/6QK/8/8/8/8/8 b - - 0 1").outcome())
        self.assertIn("insufficient", Board("8/8/4k3/8/8/2KN4/8/8 w - - 0 1").outcome())
        board = Board()
        for text in ["Nf3", "Nf6", "Ng1", "Ng8"] * 2:
            board.make_move(board.parse_move(text))
        self.assertIn("repetition", board.outcome())


if __name__ == "__main__":
    unittest.main()
