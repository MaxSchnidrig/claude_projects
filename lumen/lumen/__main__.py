"""Command line entry point.

    python3 -m lumen                     start the interactive REPL
    python3 -m lumen program.lum         run a file
    python3 -m lumen --tokens file.lum   show the tokens the lexer produces
    python3 -m lumen --ast file.lum      show the syntax tree the parser builds
"""

import sys

from . import Interpreter, Lexer, LumenError, Parser, __version__, run_source, stringify
from .ast_nodes import dump

USAGE = __doc__.split("\n", 2)[2]


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if not args:
        return repl()
    if args[0] in ("-h", "--help"):
        print(USAGE)
        return 0

    mode = "run"
    if args[0] in ("--tokens", "--ast"):
        mode = args.pop(0)[2:]
    if len(args) != 1:
        print(USAGE, file=sys.stderr)
        return 2

    path = args[0]
    try:
        with open(path, encoding="utf-8") as file:
            source = file.read()
    except OSError as error:
        print(f"lumen: can't open {path}: {error.strerror}", file=sys.stderr)
        return 1

    try:
        if mode == "tokens":
            for token in Lexer(source).tokenize():
                print(f"{token.line:>4}:{token.col:<4} {token.kind:<8} {token.value!r}")
        elif mode == "ast":
            print(dump(Parser(Lexer(source).tokenize()).parse()))
        else:
            run_source(source)
    except LumenError as error:
        print(error.format(source), file=sys.stderr)
        return 1
    return 0


def _needs_more_input(source):
    """True while brackets are still open, so the REPL keeps reading lines."""
    try:
        tokens = Lexer(source).tokenize()
    except LumenError:
        return False  # let the real run report the error
    depth = 0
    for token in tokens:
        if token.kind == "OP" and token.value in "([{":
            depth += 1
        elif token.kind == "OP" and token.value in ")]}":
            depth -= 1
    return depth > 0


def run_repl_input(source, interpreter):
    """Run one REPL entry. A lone expression like `1 + 2` has its value
    returned (so the REPL can echo it); anything else runs as statements."""
    tokens = Lexer(source).tokenize()
    try:
        expression = Parser(tokens).parse_expression()
    except LumenError:
        interpreter.run(Parser(tokens).parse())
        return None
    return interpreter.run_expression(expression)


def repl():
    print(f"Lumen {__version__}. Type 'exit' to quit.")
    interpreter = Interpreter()
    lines = []
    while True:
        try:
            line = input("... " if lines else ">>> ")
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not lines and line.strip() in ("exit", "quit"):
            return 0
        lines.append(line)
        source = "\n".join(lines)
        if _needs_more_input(source):
            continue
        lines = []
        if not source.strip():
            continue
        try:
            value = run_repl_input(source, interpreter)
            if value is not None:
                print(stringify(value, quote_strings=True))
        except LumenError as error:
            print(error.format(source))


if __name__ == "__main__":
    sys.exit(main())
