"""Lumen: a small programming language written in Python."""

from .errors import LumenError, LumenRuntimeError, LumenSyntaxError
from .interpreter import Interpreter
from .lexer import Lexer, Token
from .parser import Parser
from .values import stringify

__version__ = "1.0.0"


def run_source(source, interpreter=None):
    """Lex, parse and run a Lumen program. Returns the interpreter used."""
    interpreter = interpreter or Interpreter()
    tokens = Lexer(source).tokenize()
    program = Parser(tokens).parse()
    interpreter.run(program)
    return interpreter
