"""Built-in functions that every Lumen program can use."""

import math
import random
import time

from .errors import LumenRuntimeError
from .values import Builtin, is_integer, is_number, stringify, type_name, values_equal


def _require(condition, message):
    if not condition:
        raise LumenRuntimeError(message)


def _is_key(value):
    return isinstance(value, str) or is_number(value)


def install_builtins(interpreter):
    def builtin(name, min_args, max_args=None):
        def register(function):
            most = min_args if max_args is None else max_args
            interpreter.globals.define(name, Builtin(name, function, min_args, most))
            return function
        return register

    # --- input and output ---------------------------------------------------

    @builtin("print", 0, math.inf)
    def _print(*values):
        interpreter.output(" ".join(stringify(v) for v in values))

    @builtin("input", 0, 1)
    def _input(prompt=""):
        return interpreter.input_fn(stringify(prompt))

    # --- types and conversion -----------------------------------------------

    @builtin("type", 1)
    def _type(value):
        return type_name(value)

    @builtin("str", 1)
    def _str(value):
        return stringify(value)

    @builtin("num", 1)
    def _num(value):
        if is_number(value):
            return value
        _require(isinstance(value, str), f"num() can't convert a {type_name(value)}")
        for convert in (int, float):
            try:
                return convert(value.strip())
            except ValueError:
                pass
        raise LumenRuntimeError(f"Can't convert {stringify(value, True)} to a number")

    # --- lists, strings and maps --------------------------------------------

    @builtin("len", 1)
    def _len(value):
        _require(isinstance(value, (str, list, dict)),
                 f"len() needs a string, list or map, not a {type_name(value)}")
        return len(value)

    @builtin("range", 1, 3)
    def _range(*args):
        _require(all(is_integer(a) for a in args), "range() needs whole numbers")
        _require(len(args) < 3 or args[2] != 0, "range() step can't be zero")
        numbers = range(*args)
        _require(len(numbers) <= 10_000_000, "range() is too large")
        return list(numbers)

    @builtin("push", 2)
    def _push(items, value):
        _require(isinstance(items, list), f"push() needs a list, not a {type_name(items)}")
        items.append(value)
        return items

    @builtin("pop", 1)
    def _pop(items):
        _require(isinstance(items, list), f"pop() needs a list, not a {type_name(items)}")
        _require(items, "Can't pop from an empty list")
        return items.pop()

    @builtin("keys", 1)
    def _keys(mapping):
        _require(isinstance(mapping, dict), f"keys() needs a map, not a {type_name(mapping)}")
        return list(mapping)

    @builtin("has", 2)
    def _has(container, item):
        """has(map, key), has(list, item) or has(string, substring)"""
        if isinstance(container, dict):
            return _is_key(item) and item in container
        if isinstance(container, list):
            return any(values_equal(x, item) for x in container)
        if isinstance(container, str):
            _require(isinstance(item, str), "has() on a string needs a string to look for")
            return item in container
        raise LumenRuntimeError(f"has() can't look inside a {type_name(container)}")

    @builtin("sort", 1)
    def _sort(items):
        _require(isinstance(items, list), f"sort() needs a list, not a {type_name(items)}")
        _require(all(is_number(x) for x in items) or all(isinstance(x, str) for x in items),
                 "sort() needs a list of only numbers or only strings")
        return sorted(items)

    @builtin("join", 1, 2)
    def _join(items, separator=""):
        _require(isinstance(items, list), f"join() needs a list, not a {type_name(items)}")
        _require(isinstance(separator, str), "join() separator must be a string")
        return separator.join(stringify(x) for x in items)

    @builtin("split", 1, 2)
    def _split(text, separator=None):
        _require(isinstance(text, str), f"split() needs a string, not a {type_name(text)}")
        _require(separator is None or (isinstance(separator, str) and separator),
                 "split() separator must be a non-empty string")
        return text.split(separator)

    # --- maths --------------------------------------------------------------

    def _number(name, value):
        _require(is_number(value), f"{name}() needs a number, not a {type_name(value)}")

    @builtin("abs", 1)
    def _abs(x):
        _number("abs", x)
        return abs(x)

    @builtin("floor", 1)
    def _floor(x):
        _number("floor", x)
        return math.floor(x)

    @builtin("sqrt", 1)
    def _sqrt(x):
        _number("sqrt", x)
        _require(x >= 0, "Can't take the square root of a negative number")
        return math.sqrt(x)

    @builtin("random", 0)
    def _random():
        return random.random()

    @builtin("random_int", 2)
    def _random_int(low, high):
        _require(is_integer(low) and is_integer(high) and low <= high,
                 "random_int() needs two whole numbers, low <= high")
        return random.randint(low, high)

    @builtin("clock", 0)
    def _clock():
        return time.perf_counter()
