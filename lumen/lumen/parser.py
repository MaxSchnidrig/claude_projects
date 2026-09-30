"""The parser: turns a list of tokens into a syntax tree.

This is a *recursive descent* parser. Each grammar rule is one method, and
each precedence level calls the next-tighter one, lowest precedence first:

    assignment   =  or_expr ( ("=" | "+=" | ...) assignment )?
    or_expr      =  and_expr ( "or" and_expr )*
    and_expr     =  not_expr ( "and" not_expr )*
    not_expr     =  "not" not_expr | equality
    equality     =  comparison ( ("==" | "!=") comparison )*
    comparison   =  term ( ("<" | "<=" | ">" | ">=") term )*
    term         =  factor ( ("+" | "-") factor )*
    factor       =  unary ( ("*" | "/" | "%") unary )*
    unary        =  "-" unary | power
    power        =  postfix ( "**" unary )?          # right associative
    postfix      =  primary ( "(" args ")" | "[" expression "]" )*
    primary      =  NUMBER | STRING | true | false | nil | IDENT
                 |  "(" expression ")" | list | map | fn
"""

from . import ast_nodes as ast
from .errors import LumenSyntaxError

COMPOUND_ASSIGN = {"+=": "+", "-=": "-", "*=": "*", "/=": "/", "%=": "%"}


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0
        # Used to reject `break` outside loops and `return` outside functions
        self.loop_depth = 0
        self.function_depth = 0

    def parse(self):
        statements = []
        while not self._at_end():
            statements.append(self._statement())
        return statements

    def parse_expression(self):
        """Parse input that must be exactly one expression (used by the REPL)."""
        expr = self._expression()
        if not self._at_end():
            raise self._error("Expected end of input")
        return expr

    # --- token helpers ------------------------------------------------------

    def _peek(self):
        return self.tokens[self.pos]

    def _at_end(self):
        return self._peek().kind == "EOF"

    def _advance(self):
        token = self.tokens[self.pos]
        if not self._at_end():
            self.pos += 1
        return token

    def _check(self, kind, value=None):
        token = self._peek()
        return token.kind == kind and (value is None or token.value == value)

    def _match(self, kind, *values):
        token = self._peek()
        if token.kind == kind and (not values or token.value in values):
            return self._advance()
        return None

    def _expect(self, kind, value, message):
        token = self._match(kind, value) if value is not None else self._match(kind)
        if token is None:
            raise self._error(message)
        return token

    def _error(self, message, token=None):
        token = token or self._peek()
        if token.kind == "EOF":
            found = "end of input"
        elif token.kind == "STRING":
            found = f'"{token.value}"'
        else:
            found = f"'{token.value}'"
        return LumenSyntaxError(f"{message}, but found {found}", token.line, token.col)

    @staticmethod
    def _at(token):
        return {"line": token.line, "col": token.col}

    # --- statements ---------------------------------------------------------

    def _statement(self):
        token = self._peek()
        if token.kind == "KEYWORD":
            word = token.value
            if word == "let":
                return self._let()
            if word == "fn" and self.tokens[self.pos + 1].kind == "IDENT":
                return self._function_declaration()
            if word == "if":
                return self._if()
            if word == "while":
                return self._while()
            if word == "for":
                return self._for()
            if word == "return":
                return self._return()
            if word in ("break", "continue"):
                return self._loop_jump()
            if word == "try":
                return self._try()
            if word == "throw":
                return self._throw()
        if self._check("OP", "{"):
            return self._block()
        expr = self._expression()
        self._expect("OP", ";", "Expected ';' after expression")
        return ast.ExprStmt(expr, **self._at(token))

    def _let(self):
        keyword = self._advance()
        name = self._expect("IDENT", None, "Expected a variable name after 'let'")
        if self._match("OP", "="):
            value = self._expression()
        else:
            value = ast.Literal(None, **self._at(name))
        self._expect("OP", ";", "Expected ';' after variable declaration")
        return ast.Let(name.value, value, **self._at(keyword))

    def _function_declaration(self):
        keyword = self._advance()
        name = self._advance()
        function = self._function_rest(name.value, keyword)
        return ast.Let(name.value, function, **self._at(keyword))

    def _function_rest(self, name, keyword):
        self._expect("OP", "(", "Expected '(' to start the parameter list")
        params = []
        if not self._check("OP", ")"):
            while True:
                param = self._expect("IDENT", None, "Expected a parameter name")
                if param.value in params:
                    raise LumenSyntaxError(
                        f"Duplicate parameter '{param.value}'", param.line, param.col
                    )
                params.append(param.value)
                if not self._match("OP", ","):
                    break
        self._expect("OP", ")", "Expected ')' after parameters")

        # A loop outside the function doesn't let you `break` inside it
        saved_loop_depth = self.loop_depth
        self.loop_depth = 0
        self.function_depth += 1
        body = self._block()
        self.function_depth -= 1
        self.loop_depth = saved_loop_depth
        return ast.FunctionExpr(name, params, body.body, **self._at(keyword))

    def _block(self):
        brace = self._expect("OP", "{", "Expected '{' to start a block")
        statements = []
        while not self._check("OP", "}") and not self._at_end():
            statements.append(self._statement())
        self._expect("OP", "}", f"Expected '}}' to close the block opened on line {brace.line}")
        return ast.Block(statements, **self._at(brace))

    def _if(self):
        keyword = self._advance()
        condition = self._expression()
        then_branch = self._block()
        else_branch = None
        if self._match("KEYWORD", "else"):
            else_branch = self._if() if self._check("KEYWORD", "if") else self._block()
        return ast.If(condition, then_branch, else_branch, **self._at(keyword))

    def _loop_body(self):
        self.loop_depth += 1
        body = self._block()
        self.loop_depth -= 1
        return body

    def _while(self):
        keyword = self._advance()
        condition = self._expression()
        return ast.While(condition, self._loop_body(), **self._at(keyword))

    def _for(self):
        keyword = self._advance()
        variable = self._expect("IDENT", None, "Expected a loop variable after 'for'")
        self._expect("KEYWORD", "in", "Expected 'in' after the loop variable")
        iterable = self._expression()
        return ast.For(variable.value, iterable, self._loop_body(), **self._at(keyword))

    def _return(self):
        keyword = self._advance()
        if self.function_depth == 0:
            raise LumenSyntaxError("'return' can only be used inside a function",
                                   keyword.line, keyword.col)
        if self._check("OP", ";"):
            value = ast.Literal(None, **self._at(keyword))
        else:
            value = self._expression()
        self._expect("OP", ";", "Expected ';' after return value")
        return ast.Return(value, **self._at(keyword))

    def _loop_jump(self):
        keyword = self._advance()
        if self.loop_depth == 0:
            raise LumenSyntaxError(f"'{keyword.value}' can only be used inside a loop",
                                   keyword.line, keyword.col)
        self._expect("OP", ";", f"Expected ';' after '{keyword.value}'")
        node_type = ast.Break if keyword.value == "break" else ast.Continue
        return node_type(**self._at(keyword))

    def _try(self):
        keyword = self._advance()
        body = self._block()
        self._expect("KEYWORD", "catch", "Expected 'catch' after the try block")
        name = self._expect("IDENT", None, "Expected a variable name after 'catch'")
        handler = self._block()
        return ast.Try(body, name.value, handler, **self._at(keyword))

    def _throw(self):
        keyword = self._advance()
        value = self._expression()
        self._expect("OP", ";", "Expected ';' after throw value")
        return ast.Throw(value, **self._at(keyword))

    # --- expressions --------------------------------------------------------

    def _expression(self):
        return self._assignment()

    def _assignment(self):
        target = self._or()
        token = self._match("OP", "=", *COMPOUND_ASSIGN)
        if token is None:
            return target
        value = self._assignment()  # right associative: a = b = 1
        if token.value in COMPOUND_ASSIGN:
            # `x += 1` is shorthand for `x = x + 1`
            value = ast.Binary(target, COMPOUND_ASSIGN[token.value], value, **self._at(token))
        if isinstance(target, ast.Variable):
            return ast.Assign(target.name, value, **self._at(token))
        if isinstance(target, ast.Index):
            return ast.SetIndex(target.target, target.index, value, **self._at(token))
        raise LumenSyntaxError("Can't assign to this expression", token.line, token.col)

    def _binary(self, next_level, operators, node_type=ast.Binary, kind="OP"):
        left = next_level()
        while token := self._match(kind, *operators):
            right = next_level()
            left = node_type(left, token.value, right, **self._at(token))
        return left

    def _or(self):
        return self._binary(self._and, ("or",), ast.Logical, "KEYWORD")

    def _and(self):
        return self._binary(self._not, ("and",), ast.Logical, "KEYWORD")

    def _not(self):
        if token := self._match("KEYWORD", "not"):
            return ast.Unary("not", self._not(), **self._at(token))
        return self._equality()

    def _equality(self):
        return self._binary(self._comparison, ("==", "!="))

    def _comparison(self):
        return self._binary(self._term, ("<", "<=", ">", ">="))

    def _term(self):
        return self._binary(self._factor, ("+", "-"))

    def _factor(self):
        return self._binary(self._unary, ("*", "/", "%"))

    def _unary(self):
        if token := self._match("OP", "-"):
            return ast.Unary("-", self._unary(), **self._at(token))
        return self._power()

    def _power(self):
        base = self._postfix()
        if token := self._match("OP", "**"):
            # Parsing the exponent with _unary makes 2 ** 3 ** 2 == 2 ** 9
            # and allows 2 ** -1, while -2 ** 2 is still -(2 ** 2)
            return ast.Binary(base, "**", self._unary(), **self._at(token))
        return base

    def _postfix(self):
        expr = self._primary()
        while True:
            if token := self._match("OP", "("):
                args = self._comma_list(")", self._expression)
                expr = ast.Call(expr, args, **self._at(token))
            elif token := self._match("OP", "["):
                index = self._expression()
                self._expect("OP", "]", "Expected ']' after index")
                expr = ast.Index(expr, index, **self._at(token))
            else:
                return expr

    def _comma_list(self, closing, parse_item):
        items = []
        while not self._check("OP", closing):
            items.append(parse_item())
            if not self._match("OP", ","):
                break
        self._expect("OP", closing, f"Expected ',' or '{closing}'")
        return items

    def _map_entry(self):
        key = self._expression()
        self._expect("OP", ":", "Expected ':' between a map key and its value")
        return (key, self._expression())

    def _primary(self):
        token = self._peek()
        where = self._at(token)
        if token.kind in ("NUMBER", "STRING"):
            self._advance()
            return ast.Literal(token.value, **where)
        if token.kind == "IDENT":
            self._advance()
            return ast.Variable(token.value, **where)
        if token.kind == "KEYWORD":
            constants = {"true": True, "false": False, "nil": None}
            if token.value in constants:
                self._advance()
                return ast.Literal(constants[token.value], **where)
            if token.value == "fn":
                self._advance()
                return self._function_rest(None, token)
        if self._match("OP", "("):
            expr = self._expression()
            self._expect("OP", ")", "Expected ')' to close '('")
            return expr
        if self._match("OP", "["):
            return ast.ListLiteral(self._comma_list("]", self._expression), **where)
        if self._match("OP", "{"):
            return ast.MapLiteral(self._comma_list("}", self._map_entry), **where)
        raise self._error("Expected an expression")
