"""The Universal Chess Interface, so Kestrel can be used from chess GUIs
(Arena, Cute Chess, BanksiaGUI, ...) or pitted against other engines."""

import sys
import threading

from .board import Board, move_to_uci
from .search import Searcher, format_info

ENGINE_NAME = "Kestrel 1.0"
MOVE_OVERHEAD = 0.05  # seconds kept in reserve for communication lag


def choose_time(board, options):
    """Turn the clock information from a `go` command into a time budget."""
    if "movetime" in options:
        return max(0.01, options["movetime"] / 1000 - MOVE_OVERHEAD)
    remaining = options.get("wtime" if board.side == 0 else "btime")
    if remaining is None:
        return None
    increment = options.get("winc" if board.side == 0 else "binc", 0) / 1000
    remaining /= 1000
    moves_to_go = options.get("movestogo", 30)
    budget = remaining / max(moves_to_go, 1) + 0.75 * increment
    return max(0.01, min(budget, remaining * 0.5 - MOVE_OVERHEAD))


class UciEngine:
    def __init__(self, output=print):
        self.output = output
        self.board = Board()
        self.searcher = Searcher()
        self.thread = None

    def handle(self, line):
        """Process one command. Returns False when the engine should quit."""
        words = line.split()
        if not words:
            return True
        command = words[0]
        if command == "uci":
            self.output(f"id name {ENGINE_NAME}")
            self.output("id author Claude and Max")
            self.output("uciok")
        elif command == "isready":
            self.output("readyok")
        elif command == "ucinewgame":
            self.wait()
            self.searcher.clear()
        elif command == "position":
            self.wait()
            self.set_position(words[1:])
        elif command == "go":
            self.wait()
            self.go(words[1:])
        elif command == "stop":
            self.searcher.stop = True
            self.wait()
        elif command == "quit":
            self.searcher.stop = True
            self.wait()
            return False
        elif command == "d":  # non-standard: show the board
            self.output(str(self.board))
            self.output(f"fen {self.board.fen()}")
        return True

    def set_position(self, words):
        if words and words[0] == "startpos":
            board, rest = Board(), words[1:]
        elif words and words[0] == "fen":
            end = words.index("moves") if "moves" in words else len(words)
            board, rest = Board(" ".join(words[1:end])), words[end:]
        else:
            return
        if rest and rest[0] == "moves":
            for text in rest[1:]:
                board.make_move(board.parse_move(text))
        self.board = board

    def go(self, words):
        options = {}
        for i, word in enumerate(words[:-1]):
            if word in ("wtime", "btime", "winc", "binc", "movestogo", "movetime", "depth"):
                options[word] = int(words[i + 1])
        infinite = "infinite" in words
        time_limit = None if infinite else choose_time(self.board, options)
        depth = options.get("depth", 99)

        def run():
            move, _ = self.searcher.search(
                self.board, max_depth=depth, time_limit=time_limit,
                on_info=lambda *info: self.output(format_info(*info)))
            self.output(f"bestmove {move_to_uci(move)}")

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def wait(self):
        if self.thread is not None:
            self.thread.join()
            self.thread = None


def main():
    engine = UciEngine(output=lambda text: print(text, flush=True))
    for line in sys.stdin:
        if not engine.handle(line):
            return
    engine.wait()  # input ended (e.g. piped commands): finish the search first
