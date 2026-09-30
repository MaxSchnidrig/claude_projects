# Kestrel

A chess engine written in pure Python (3.10+, no libraries), using bitboard
move generation and an alpha-beta search.

```
python3 -m kestrel                 # play against it (you are White)
python3 -m kestrel play --black    # play as Black
python3 -m kestrel play --time 10  # let it think 10 seconds a move
python3 -m kestrel analyse "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"
python3 -m kestrel uci             # UCI mode, for chess GUIs
python3 -m kestrel perft 5         # move generator self-check
python3 -m kestrel bench           # speed test
python3 -m unittest                # run the tests
```

Moves can be typed as SAN (`e4`, `Nf3`, `exd5`, `O-O`, `e8=Q`) or UCI
(`e2e4`). During a game you can also type `undo`, `hint`, `fen` or `quit`.

To use it in a chess GUI such as [Cute Chess](https://cutechess.com/) or
Arena, add an engine whose command is `python3 -m kestrel uci`, run from this
folder.

## How it works

| File | What it does |
| --- | --- |
| `kestrel/bitboard.py` | 64-bit integer bitboards, precomputed attack tables, Zobrist keys |
| `kestrel/board.py` | Position state, move generation, make/unmake, FEN, SAN, game results |
| `kestrel/evaluate.py` | Scores a position: tapered piece-square tables, pawn structure, mobility and more |
| `kestrel/search.py` | Iterative deepening alpha-beta with a transposition table |
| `kestrel/uci.py` | The UCI protocol and time management |

### Bitboards

A bitboard is a 64-bit number where each bit is a square (a1 = bit 0, h8 =
bit 63). One bitboard per piece type and colour describes the whole board,
and whole groups of moves can be computed at once. For example, every white
pawn push is `(white_pawns << 8) & empty_squares`.

Knight, king and pawn attacks are looked up in tables. Sliding pieces
(bishops, rooks and queens) are blocked by other pieces, so for every square
there is a table from "which of the squares that matter are occupied" to the
attack set. This is the same idea as magic bitboards, but a Python dict does
the hashing. A rook's moves are `ROOK_TABLES[sq][occupied & ROOK_MASKS[sq]]`.

The move generator produces *pseudo-legal* moves. `make_move` plays a move,
checks whether our own king is attacked, and takes it back if so. The
generator passes the standard **perft** tests: it counts exactly the right
number of positions in well-known tricky test positions (castling through
check, en passant pins, promotions and so on). That is 1.6 million
positions in total, and all of them match.

### Search

- **Negamax alpha-beta**: explores the move tree and cuts off branches that
  can't change the result.
- **Iterative deepening**: searches depth 1, then 2, then 3, until time runs
  out. Each pass improves the move ordering for the next one.
- **Transposition table**: a hash table of positions already searched,
  indexed by Zobrist hash. It stores the score, depth, bound type and best
  move, so positions reached by different move orders are only searched once.
- **Move ordering**: the hash move first, then captures by MVV-LVA (most
  valuable victim, least valuable attacker), then queen promotions, then
  killer moves, then moves ranked by the history heuristic.
- **Principal variation search**: every move after the first is searched
  with a zero-width window, and re-searched only if it turns out better.
- **Quiescence search**: at the end of the main search, captures keep being
  played until the position is quiet, so the engine never evaluates in the
  middle of an exchange. Delta pruning skips hopeless captures.
- **Pruning**: null-move pruning, reverse futility pruning, late move
  reductions, late move pruning and mate distance pruning.
- **Extensions**: check extensions and aspiration windows.
- **Draws**: detects repetition, the fifty-move rule and insufficient
  material.

### Evaluation

- **Tapered piece-square tables** from PeSTO (Ronald Friederich). Each piece
  has a middlegame and an endgame value per square. The engine blends the two
  by game phase, so the king hides in the middlegame and walks forward in the
  endgame. These totals are updated incrementally inside `make_move`.
- **Pawn structure**: passed, isolated and doubled pawns, cached by pawn
  layout.
- **Piece activity**: mobility, rooks on open and half-open files, the bishop
  pair, and the pawn shelter around the king.
- **Endgame knowledge**: drives a lone king to the edge for mating, and
  recognises draws without mating material.

## Strength

Pure Python searches about 40,000 positions per second, roughly 1,000 times
slower than a C++ engine like Stockfish. Kestrel makes up for some of that
with aggressive pruning, and reaches 8 to 12 moves deep within a few seconds
in most positions. That is enough to be tactically sharp and to beat
most casual and club players.
