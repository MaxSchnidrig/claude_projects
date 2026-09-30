"""The lexer: turns Lumen source text into a list of tokens.

For example `let x = 2 * (y + 1);` becomes:
    KEYWORD let, IDENT x, OP =, NUMBER 2, OP *, OP (, IDENT y, ...
"""

from dataclasses import dataclass

from .errors import LumenSyntaxError

KEYWORDS = {
    "let", "fn", "return", "if", "else", "while", "for", "in",
    "break", "continue", "and", "or", "not", "true", "false", "nil",
    "try", "catch", "throw",
}

# Two-character operators come first so that "<=" is not read as "<" then "=".
OPERATORS = (
    "+=", "-=", "*=", "/=", "%=", "**", "==", "!=", "<=", ">=",
    "+", "-", "*", "/", "%", "<", ">", "=",
    "(", ")", "{", "}", "[", "]", ",", ";", ":",
)

DIGITS = "0123456789"
ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
END = "\0"  # returned by _peek() once we run off the end of the source


@dataclass(frozen=True)
class Token:
    kind: str  # NUMBER, STRING, IDENT, KEYWORD, OP or EOF
    value: object
    line: int
    col: int


class Lexer:
    def __init__(self, source):
        self.source = source
        self.pos = 0
        self.line = 1
        self.col = 1

    def tokenize(self):
        tokens = []
        while True:
            self._skip_whitespace_and_comments()
            if self.pos >= len(self.source):
                tokens.append(Token("EOF", None, self.line, self.col))
                return tokens
            tokens.append(self._read_token())

    # --- reading characters -------------------------------------------------

    def _peek(self, offset=0):
        index = self.pos + offset
        return self.source[index] if index < len(self.source) else END

    def _advance(self):
        char = self.source[self.pos]
        self.pos += 1
        if char == "\n":
            self.line += 1
            self.col = 1
        else:
            self.col += 1
        return char

    def _skip_whitespace_and_comments(self):
        while True:
            char = self._peek()
            if char in " \t\r\n":
                self._advance()
            elif char == "#":
                while self._peek() not in ("\n", END):
                    self._advance()
            else:
                return

    # --- reading tokens -----------------------------------------------------

    def _read_token(self):
        line, col = self.line, self.col
        char = self._peek()
        if char in DIGITS:
            return self._read_number(line, col)
        if char.isalpha() or char == "_":
            return self._read_word(line, col)
        if char == '"':
            return self._read_string(line, col)
        for op in OPERATORS:
            if self.source.startswith(op, self.pos):
                for _ in op:
                    self._advance()
                return Token("OP", op, line, col)
        raise LumenSyntaxError(f"Unexpected character {char!r}", line, col)

    def _read_number(self, line, col):
        start = self.pos
        while self._peek() in DIGITS:
            self._advance()
        is_float = self._peek() == "." and self._peek(1) in DIGITS
        if is_float:
            self._advance()
            while self._peek() in DIGITS:
                self._advance()
        text = self.source[start:self.pos]
        return Token("NUMBER", float(text) if is_float else int(text), line, col)

    def _read_word(self, line, col):
        start = self.pos
        while self._peek().isalnum() or self._peek() == "_":
            self._advance()
        word = self.source[start:self.pos]
        return Token("KEYWORD" if word in KEYWORDS else "IDENT", word, line, col)

    def _read_string(self, line, col):
        self._advance()  # the opening quote
        chars = []
        while True:
            char = self._peek()
            if char in ("\n", END):
                raise LumenSyntaxError("Unterminated string", line, col)
            self._advance()
            if char == '"':
                return Token("STRING", "".join(chars), line, col)
            if char == "\\":
                escape = self._peek()
                if escape not in ESCAPES:
                    raise LumenSyntaxError(
                        f"Unknown escape sequence '\\{escape}'", self.line, self.col - 1
                    )
                self._advance()
                chars.append(ESCAPES[escape])
            else:
                chars.append(char)
