"""Command line interface.

    python3 -m kestrel                    play against the engine in the terminal
    python3 -m kestrel play --black       play as Black
    python3 -m kestrel play --time 10     give the engine 10 seconds per move
    python3 -m kestrel uci                speak UCI (for chess GUIs)
    python3 -m kestrel analyse FEN        analyse a position
    python3 -m kestrel reply e4 e5 Nf3    play those moves, then show the engine's reply
    python3 -m kestrel perft 5 [FEN]      count move-tree leaves (move generator test)
    python3 -m kestrel bench              search fixed positions and report speed
"""

import argparse
import sys
import time

from .board import START_FEN, Board, move_to_uci, perft
from .search import Searcher, format_info, format_score

BENCH_POSITIONS = [
    START_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "r1bq1rk1/pp2bppp/2n1pn2/3p4/2PP4/2N1PN2/PP1B1PPP/R2QKB1R w KQ - 0 8",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1",
]


def print_info(depth, score, nodes, elapsed, pv, board):
    line = []
    copy = board.copy()
    for move in pv:
        line.append(copy.san(move))
        copy.make_move(move)
    print(f"  depth {depth:2}  {format_score(score):>9}  {nodes:>8} nodes  "
          f"{elapsed:5.1f}s  {' '.join(line)}")


def play(human_is_white, think_time):
    board = Board()
    searcher = Searcher()
    print("You are", "White" if human_is_white else "Black",
          "- type moves like e4, Nf3, O-O or e2e4. Commands: undo, hint, fen, quit.")
    while True:
        print()
        print(board)
        result = board.outcome()
        if result:
            print(f"\nGame over: {result}")
            return
        if (board.side == 0) == human_is_white:
            text = input("\nYour move: ").strip()
            if text == "quit":
                return
            if text == "fen":
                print(board.fen())
                continue
            if text == "undo":
                for _ in range(min(2, len(board.stack))):
                    board.unmake_move()
                continue
            if text == "hint":
                move, _ = searcher.search(board, time_limit=think_time)
                print("Hint:", board.san(move))
                continue
            try:
                move = board.parse_move(text)
            except ValueError as error:
                print(error)
                continue
            board.make_move(move)
        else:
            print("\nKestrel is thinking...")
            move, score = searcher.search(
                board, time_limit=think_time,
                on_info=lambda *info: print_info(*info, board))
            print(f"Kestrel plays {board.san(move)}")
            board.make_move(move)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="kestrel", description="A bitboard chess engine.")
    sub = parser.add_subparsers(dest="command")
    play_cmd = sub.add_parser("play", help="play against the engine")
    play_cmd.add_argument("--black", action="store_true", help="play the black pieces")
    play_cmd.add_argument("--time", type=float, default=5.0, help="engine seconds per move")
    sub.add_parser("uci", help="run the UCI protocol")
    analyse_cmd = sub.add_parser("analyse", help="analyse a position")
    analyse_cmd.add_argument("fen", nargs="?", default=START_FEN)
    analyse_cmd.add_argument("--time", type=float, default=10.0)
    reply_cmd = sub.add_parser("reply", help="play moves from the start, then reply")
    reply_cmd.add_argument("moves", nargs="*")
    reply_cmd.add_argument("--time", type=float, default=5.0)
    perft_cmd = sub.add_parser("perft", help="count leaf nodes to a depth")
    perft_cmd.add_argument("depth", type=int)
    perft_cmd.add_argument("fen", nargs="?", default=START_FEN)
    sub.add_parser("bench", help="measure search speed")
    args = parser.parse_args(argv)

    if args.command in (None, "play"):
        black = getattr(args, "black", False)
        play(not black, getattr(args, "time", 5.0))
    elif args.command == "uci":
        from .uci import main as uci_main
        uci_main()
    elif args.command == "analyse":
        board = Board(args.fen)
        print(board)
        move, _ = Searcher().search(board, time_limit=args.time,
                                    on_info=lambda *info: print_info(*info, board))
        print("Best move:", board.san(move))
    elif args.command == "reply":
        board = Board()
        for text in args.moves:
            board.make_move(board.parse_move(text))
        result = board.outcome()
        if result:
            print(board, f"\nGame over: {result}", sep="\n")
            return 0
        move, _ = Searcher().search(board, time_limit=args.time,
                                    on_info=lambda *info: print_info(*info, board))
        print(f"Kestrel plays {board.san(move)} ({move_to_uci(move)})")
        board.make_move(move)
        print(board)
        result = board.outcome()
        if result:
            print(f"Game over: {result}")
    elif args.command == "perft":
        board = Board(args.fen)
        start = time.perf_counter()
        nodes = perft(board, args.depth)
        elapsed = time.perf_counter() - start
        print(f"perft {args.depth}: {nodes} nodes in {elapsed:.2f}s")
    elif args.command == "bench":
        total_nodes, total_time = 0, 0.0
        for fen in BENCH_POSITIONS:
            searcher = Searcher()
            start = time.perf_counter()
            move, score = searcher.search(Board(fen), max_depth=7)
            elapsed = time.perf_counter() - start
            total_nodes += searcher.nodes
            total_time += elapsed
            print(f"{move_to_uci(move):6} {format_score(score):>10} {searcher.nodes:>8} nodes "
                  f"{elapsed:6.2f}s  {fen}")
        print(f"total {total_nodes} nodes, {total_nodes / total_time:.0f} nodes/second")
    return 0


if __name__ == "__main__":
    sys.exit(main())
