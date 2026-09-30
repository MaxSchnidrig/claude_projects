"""The abstract syntax tree (AST): the shapes the parser builds.

`1 + 2 * 3` becomes Binary(Literal(1), "+", Binary(Literal(2), "*", Literal(3)))
which is how operator precedence gets "baked in" to the program.
"""

from dataclasses import dataclass, field, fields


@dataclass
class Node:
    line: int = field(default=0, kw_only=True, repr=False)
    col: int = field(default=0, kw_only=True, repr=False)


# --- expressions (things that produce a value) ------------------------------

@dataclass
class Literal(Node):
    value: object


@dataclass
class Variable(Node):
    name: str


@dataclass
class Assign(Node):
    name: str
    value: Node


@dataclass
class Unary(Node):
    op: str
    operand: Node


@dataclass
class Binary(Node):
    left: Node
    op: str
    right: Node


@dataclass
class Logical(Node):
    """`and` / `or`, kept apart from Binary because they short-circuit."""
    left: Node
    op: str
    right: Node


@dataclass
class Call(Node):
    callee: Node
    args: list


@dataclass
class Index(Node):
    target: Node
    index: Node


@dataclass
class SetIndex(Node):
    target: Node
    index: Node
    value: Node


@dataclass
class ListLiteral(Node):
    items: list


@dataclass
class MapLiteral(Node):
    entries: list  # list of (key, value) node pairs


@dataclass
class FunctionExpr(Node):
    name: object  # None for anonymous functions
    params: list
    body: list


# --- statements (things that do something) ----------------------------------

@dataclass
class ExprStmt(Node):
    expr: Node


@dataclass
class Let(Node):
    name: str
    value: Node


@dataclass
class Block(Node):
    body: list


@dataclass
class If(Node):
    condition: Node
    then_branch: Block
    else_branch: object  # Block, If or None


@dataclass
class While(Node):
    condition: Node
    body: Block


@dataclass
class For(Node):
    variable: str
    iterable: Node
    body: Block


@dataclass
class Return(Node):
    value: Node


@dataclass
class Break(Node):
    pass


@dataclass
class Continue(Node):
    pass


@dataclass
class Try(Node):
    body: Block
    error_name: str
    handler: Block


@dataclass
class Throw(Node):
    value: Node


def dump(node, indent=0):
    """Draw a tree as indented text, used by `python -m lumen --ast`."""
    if isinstance(node, list):
        return "\n".join(dump(child, indent) for child in node)
    pad = "  " * indent
    simple, children = [], []
    for f in fields(node):
        if f.name in ("line", "col"):
            continue
        value = getattr(node, f.name)
        if isinstance(value, Node):
            children.append((f.name, [value]))
        elif isinstance(value, list) and any(isinstance(v, (Node, tuple)) for v in value):
            flat = []
            for item in value:
                flat.extend(item if isinstance(item, tuple) else [item])
            children.append((f.name, flat))
        else:
            simple.append(f"{f.name}={value!r}")
    lines = [f"{pad}{type(node).__name__}({', '.join(simple)})"]
    for label, nodes in children:
        lines.append(f"{pad}  {label}:")
        lines.extend(dump(child, indent + 2) for child in nodes)
    return "\n".join(lines)
