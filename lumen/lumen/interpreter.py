"""The interpreter: walks the syntax tree and runs it.

Each node type has a handler method. Statements are *executed* (they do
something) and expressions are *evaluated* (they produce a value).
`return`, `break` and `continue` are implemented with Python exceptions,
which unwind the Python call stack back to the loop or function they belong to.
"""

import sys

from . import ast_nodes as ast
from .builtins import install_builtins
from .errors import LumenRuntimeError
from .values import (Builtin, LumenFunction, is_integer, is_number, is_truthy,
                     stringify, type_name, values_equal)

MAX_CALL_DEPTH = 1000
PYTHON_RECURSION_LIMIT = 25000  # each Lumen call uses ~15 Python frames
MAX_EXPONENT = 10_000


class _ReturnSignal(Exception):
    def __init__(self, value):
        self.value = value


class _BreakSignal(Exception):
    pass


class _ContinueSignal(Exception):
    pass


class Environment:
    """One scope of variables, linked to the scope that encloses it."""

    def __init__(self, parent=None):
        self.values = {}
        self.parent = parent

    def define(self, name, value):
        self.values[name] = value

    def lookup(self, name, node):
        env = self
        while env is not None:
            if name in env.values:
                return env.values[name]
            env = env.parent
        raise LumenRuntimeError(f"Undefined variable '{name}'", node.line, node.col)

    def assign(self, name, value, node):
        env = self
        while env is not None:
            if name in env.values:
                env.values[name] = value
                return
            env = env.parent
        raise LumenRuntimeError(
            f"Can't assign to '{name}' because it doesn't exist (declare it with 'let')",
            node.line, node.col)


def _plural(count, word):
    return f"{count} {word}" + ("" if count == 1 else "s")


class Interpreter:
    def __init__(self, output=print, input_fn=input):
        self.output = output
        self.input_fn = input_fn
        self.globals = Environment()
        self.call_depth = 0
        self._handlers = {
            ast.ExprStmt: self._exec_expr_stmt,
            ast.Let: self._exec_let,
            ast.Block: self._exec_block,
            ast.If: self._exec_if,
            ast.While: self._exec_while,
            ast.For: self._exec_for,
            ast.Return: self._exec_return,
            ast.Break: self._exec_break,
            ast.Continue: self._exec_continue,
            ast.Try: self._exec_try,
            ast.Throw: self._exec_throw,
            ast.Literal: self._eval_literal,
            ast.Variable: self._eval_variable,
            ast.Assign: self._eval_assign,
            ast.Unary: self._eval_unary,
            ast.Binary: self._eval_binary,
            ast.Logical: self._eval_logical,
            ast.Call: self._eval_call,
            ast.Index: self._eval_index,
            ast.SetIndex: self._eval_set_index,
            ast.ListLiteral: self._eval_list,
            ast.MapLiteral: self._eval_map,
            ast.FunctionExpr: self._eval_function,
        }
        install_builtins(self)
        if sys.getrecursionlimit() < PYTHON_RECURSION_LIMIT:
            sys.setrecursionlimit(PYTHON_RECURSION_LIMIT)

    # --- entry points -------------------------------------------------------

    def run(self, statements):
        try:
            for statement in statements:
                self.execute(statement, self.globals)
        except RecursionError:
            raise LumenRuntimeError("Stack overflow: the program nested too deeply") from None

    def run_expression(self, expression):
        try:
            return self.evaluate(expression, self.globals)
        except RecursionError:
            raise LumenRuntimeError("Stack overflow: the program nested too deeply") from None

    def execute(self, node, env):
        self._handlers[type(node)](node, env)

    def evaluate(self, node, env):
        return self._handlers[type(node)](node, env)

    def execute_block(self, statements, env):
        for statement in statements:
            self.execute(statement, env)

    @staticmethod
    def _error(message, node):
        return LumenRuntimeError(message, node.line, node.col)

    # --- statements ---------------------------------------------------------

    def _exec_expr_stmt(self, node, env):
        self.evaluate(node.expr, env)

    def _exec_let(self, node, env):
        env.define(node.name, self.evaluate(node.value, env))

    def _exec_block(self, node, env):
        self.execute_block(node.body, Environment(env))

    def _exec_if(self, node, env):
        if is_truthy(self.evaluate(node.condition, env)):
            self.execute(node.then_branch, env)
        elif node.else_branch is not None:
            self.execute(node.else_branch, env)

    def _exec_while(self, node, env):
        while is_truthy(self.evaluate(node.condition, env)):
            try:
                self.execute(node.body, env)
            except _BreakSignal:
                break
            except _ContinueSignal:
                continue

    def _exec_for(self, node, env):
        iterable = self.evaluate(node.iterable, env)
        if isinstance(iterable, (list, str)):
            items = list(iterable)  # a copy, so changing the list mid-loop is safe
        elif isinstance(iterable, dict):
            items = list(iterable.keys())
        else:
            raise self._error(f"Can't loop over a {type_name(iterable)}", node.iterable)
        for item in items:
            # A fresh scope each time round, so closures capture this item
            loop_env = Environment(env)
            loop_env.define(node.variable, item)
            try:
                self.execute(node.body, loop_env)
            except _BreakSignal:
                break
            except _ContinueSignal:
                continue

    def _exec_return(self, node, env):
        raise _ReturnSignal(self.evaluate(node.value, env))

    def _exec_break(self, node, env):
        raise _BreakSignal()

    def _exec_continue(self, node, env):
        raise _ContinueSignal()

    def _exec_try(self, node, env):
        try:
            self.execute(node.body, env)
        except LumenRuntimeError as error:
            handler_env = Environment(env)
            handler_env.define(node.error_name, error.value)
            self.execute(node.handler, handler_env)

    def _exec_throw(self, node, env):
        value = self.evaluate(node.value, env)
        error = self._error(stringify(value), node)
        error.value = value
        raise error

    # --- expressions --------------------------------------------------------

    def _eval_literal(self, node, env):
        return node.value

    def _eval_variable(self, node, env):
        return env.lookup(node.name, node)

    def _eval_assign(self, node, env):
        value = self.evaluate(node.value, env)
        env.assign(node.name, value, node)
        return value

    def _eval_unary(self, node, env):
        value = self.evaluate(node.operand, env)
        if node.op == "not":
            return not is_truthy(value)
        if not is_number(value):
            raise self._error(f"Can't make a {type_name(value)} negative", node)
        return -value

    def _eval_logical(self, node, env):
        left = self.evaluate(node.left, env)
        if node.op == "or":
            return left if is_truthy(left) else self.evaluate(node.right, env)
        return self.evaluate(node.right, env) if is_truthy(left) else left

    def _eval_binary(self, node, env):
        left = self.evaluate(node.left, env)
        right = self.evaluate(node.right, env)
        return self._binary_op(node.op, left, right, node)

    def _binary_op(self, op, left, right, node):
        if op == "==":
            return values_equal(left, right)
        if op == "!=":
            return not values_equal(left, right)

        both_numbers = is_number(left) and is_number(right)
        both_strings = isinstance(left, str) and isinstance(right, str)

        if op in ("<", "<=", ">", ">="):
            if not (both_numbers or both_strings):
                raise self._error(
                    f"Can't compare a {type_name(left)} with a {type_name(right)}", node)
            if op == "<":
                return left < right
            if op == "<=":
                return left <= right
            if op == ">":
                return left > right
            return left >= right

        if op == "+":
            if both_numbers or both_strings or (isinstance(left, list) and isinstance(right, list)):
                return left + right
            hint = ""
            if isinstance(left, str) or isinstance(right, str):
                hint = " (use str() to turn a value into a string first)"
            raise self._error(f"Can't add a {type_name(left)} and a {type_name(right)}{hint}", node)

        if op == "*" and isinstance(left, (str, list)) and is_integer(right):
            return left * right  # "ab" * 3 == "ababab"

        if not both_numbers:
            raise self._error(
                f"Can't use '{op}' on a {type_name(left)} and a {type_name(right)}", node)

        if op == "-":
            return left - right
        if op == "*":
            return left * right
        if op == "/":
            if right == 0:
                raise self._error("Division by zero", node)
            if is_integer(left) and is_integer(right) and left % right == 0:
                return left // right  # keep 6 / 3 as the whole number 2
            return left / right
        if op == "%":
            if right == 0:
                raise self._error("Modulo by zero", node)
            return left % right
        if op == "**":
            if abs(right) > MAX_EXPONENT and abs(left) > 1:
                raise self._error("Number too large", node)
            try:
                result = left ** right
            except ZeroDivisionError:
                raise self._error("Can't raise zero to a negative power", node) from None
            except OverflowError:
                raise self._error("Number too large", node) from None
            if isinstance(result, complex):
                raise self._error("The result is not a real number", node)
            return result
        raise self._error(f"Unknown operator '{op}'", node)

    def _eval_call(self, node, env):
        callee = self.evaluate(node.callee, env)
        args = [self.evaluate(arg, env) for arg in node.args]

        if isinstance(callee, LumenFunction):
            expected = len(callee.params)
            if len(args) != expected:
                raise self._error(f"{callee.name}() takes {_plural(expected, 'argument')} "
                                  f"but was given {len(args)}", node)
            if self.call_depth >= MAX_CALL_DEPTH:
                raise self._error(
                    f"Stack overflow: more than {MAX_CALL_DEPTH} nested function calls", node)
            call_env = Environment(callee.closure)
            for name, value in zip(callee.params, args):
                call_env.define(name, value)
            self.call_depth += 1
            try:
                self.execute_block(callee.declaration.body, call_env)
            except _ReturnSignal as signal:
                return signal.value
            except LumenRuntimeError as error:
                error.add_frame(callee.name, node.line)
                raise
            finally:
                self.call_depth -= 1
            return None

        if isinstance(callee, Builtin):
            if not callee.min_args <= len(args) <= callee.max_args:
                if callee.min_args == callee.max_args:
                    wanted = _plural(callee.min_args, "argument")
                else:
                    wanted = f"{callee.min_args} to {callee.max_args} arguments"
                raise self._error(f"{callee.name}() takes {wanted} but was given {len(args)}",
                                  node)
            try:
                return callee.function(*args)
            except LumenRuntimeError as error:
                if error.line == 0:  # builtins don't know where they were called from
                    error.line, error.col = node.line, node.col
                raise

        raise self._error(f"Can't call a {type_name(callee)}", node)

    def _map_key(self, key, node):
        if isinstance(key, str) or is_number(key):
            return key
        raise self._error(f"Map keys must be strings or numbers, not a {type_name(key)}", node)

    def _list_index(self, target, index, node):
        if not is_integer(index):
            raise self._error(f"Index must be a whole number, not a {type_name(index)}", node)
        if not -len(target) <= index < len(target):
            raise self._error(f"Index {index} is out of range for a {type_name(target)} "
                              f"of length {len(target)}", node)
        return index

    def _eval_index(self, node, env):
        target = self.evaluate(node.target, env)
        index = self.evaluate(node.index, env)
        if isinstance(target, (list, str)):
            return target[self._list_index(target, index, node)]
        if isinstance(target, dict):
            key = self._map_key(index, node)
            if key not in target:
                raise self._error(f"Key {stringify(key, True)} is not in the map", node)
            return target[key]
        raise self._error(f"Can't index into a {type_name(target)}", node)

    def _eval_set_index(self, node, env):
        target = self.evaluate(node.target, env)
        index = self.evaluate(node.index, env)
        value = self.evaluate(node.value, env)
        if isinstance(target, list):
            target[self._list_index(target, index, node)] = value
        elif isinstance(target, dict):
            target[self._map_key(index, node)] = value
        elif isinstance(target, str):
            raise self._error("Strings can't be changed; build a new string instead", node)
        else:
            raise self._error(f"Can't index into a {type_name(target)}", node)
        return value

    def _eval_list(self, node, env):
        return [self.evaluate(item, env) for item in node.items]

    def _eval_map(self, node, env):
        result = {}
        for key_node, value_node in node.entries:
            key = self._map_key(self.evaluate(key_node, env), key_node)
            result[key] = self.evaluate(value_node, env)
        return result

    def _eval_function(self, node, env):
        return LumenFunction(node, env)
