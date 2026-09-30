"""How Lumen values are represented in Python, plus helpers for them.

    Lumen      Python
    nil        None
    true       True
    42, 1.5    int, float
    "hi"       str
    [1, 2]     list
    {"a": 1}   dict
    fn         LumenFunction or Builtin
"""


class LumenFunction:
    """A function written in Lumen. It remembers the scope it was created in
    (its *closure*), which is what lets inner functions see outer variables."""

    def __init__(self, declaration, closure):
        self.declaration = declaration
        self.closure = closure

    @property
    def name(self):
        return self.declaration.name or "anonymous function"

    @property
    def params(self):
        return self.declaration.params


class Builtin:
    """A function written in Python that Lumen programs can call."""

    def __init__(self, name, function, min_args, max_args):
        self.name = name
        self.function = function
        self.min_args = min_args
        self.max_args = max_args


def is_number(value):
    # bool is a subclass of int in Python, but not a number in Lumen
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_truthy(value):
    """Only `nil` and `false` count as false. 0 and "" are true."""
    return value is not None and value is not False


def values_equal(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b  # stop Python treating true == 1
    return a == b


def type_name(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "bool"
    if is_number(value):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "map"
    if isinstance(value, (LumenFunction, Builtin)):
        return "function"
    return type(value).__name__


def stringify(value, quote_strings=False):
    """Turn a value into the text `print` shows. Strings inside lists and maps
    get quotes so that ["1"] and [1] look different."""
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float):
        if value.is_integer() and abs(value) < 1e16:
            return str(int(value))
        return repr(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return _quote(value) if quote_strings else value
    if isinstance(value, list):
        return "[" + ", ".join(stringify(item, True) for item in value) + "]"
    if isinstance(value, dict):
        pairs = (f"{stringify(k, True)}: {stringify(v, True)}" for k, v in value.items())
        return "{" + ", ".join(pairs) + "}"
    if isinstance(value, LumenFunction):
        return f"<fn {value.name}>"
    if isinstance(value, Builtin):
        return f"<builtin {value.name}>"
    return repr(value)


def _quote(text):
    escaped = (text.replace("\\", "\\\\").replace('"', '\\"')
               .replace("\n", "\\n").replace("\t", "\\t"))
    return f'"{escaped}"'
