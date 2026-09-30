import io
import pathlib
import unittest
from contextlib import redirect_stdout, redirect_stderr

from lumen import (Interpreter, Lexer, LumenRuntimeError, LumenSyntaxError, Parser,
                   run_source)
from lumen.__main__ import main, run_repl_input
from lumen.ast_nodes import dump

EXAMPLES = pathlib.Path(__file__).resolve().parent.parent / "examples"


def run(source):
    """Run a program and return the lines it printed."""
    output = []
    run_source(source, Interpreter(output=output.append))
    return output


def result(expression):
    return run(f"print({expression});")[0]


class LexerTests(unittest.TestCase):
    def test_token_kinds(self):
        tokens = Lexer('let x = 3.5 <= "hi\\n"; # comment').tokenize()
        kinds = [(t.kind, t.value) for t in tokens]
        self.assertEqual(kinds, [
            ("KEYWORD", "let"), ("IDENT", "x"), ("OP", "="), ("NUMBER", 3.5),
            ("OP", "<="), ("STRING", "hi\n"), ("OP", ";"), ("EOF", None),
        ])

    def test_positions(self):
        tokens = Lexer("a\n  b").tokenize()
        self.assertEqual((tokens[1].line, tokens[1].col), (2, 3))

    def test_unterminated_string(self):
        with self.assertRaises(LumenSyntaxError):
            Lexer('"oops').tokenize()

    def test_unexpected_character(self):
        with self.assertRaises(LumenSyntaxError):
            Lexer("let a = $;").tokenize()


class ArithmeticTests(unittest.TestCase):
    def test_precedence(self):
        self.assertEqual(result("1 + 2 * 3"), "7")
        self.assertEqual(result("(1 + 2) * 3"), "9")
        self.assertEqual(result("10 - 4 - 3"), "3")
        self.assertEqual(result("2 * 3 % 4"), "2")

    def test_power_is_right_associative_and_beats_minus(self):
        self.assertEqual(result("2 ** 3 ** 2"), "512")
        self.assertEqual(result("-2 ** 2"), "-4")
        self.assertEqual(result("2 ** -1"), "0.5")

    def test_division(self):
        self.assertEqual(result("7 / 2"), "3.5")
        self.assertEqual(result("6 / 3"), "2")
        with self.assertRaises(LumenRuntimeError):
            run("print(1 / 0);")

    def test_comparisons_and_logic(self):
        self.assertEqual(result("1 < 2 and 2 <= 2"), "true")
        self.assertEqual(result("not (1 == 1) or false"), "false")
        self.assertEqual(result('nil or "default"'), "default")
        self.assertEqual(result("1 == true"), "false")

    def test_strings(self):
        self.assertEqual(result('"ab" + "cd"'), "abcd")
        self.assertEqual(result('"ab" * 3'), "ababab")
        self.assertEqual(result('"hello"[1]'), "e")


class VariableAndScopeTests(unittest.TestCase):
    def test_block_scope_shadowing(self):
        self.assertEqual(run("let x = 1; { let x = 2; print(x); } print(x);"), ["2", "1"])

    def test_assignment_reaches_outer_scope(self):
        self.assertEqual(run("let x = 1; { x = 5; } print(x);"), ["5"])

    def test_compound_assignment(self):
        self.assertEqual(run("let x = 10; x += 5; x *= 2; x -= 1; print(x);"), ["29"])

    def test_undefined_variable(self):
        with self.assertRaises(LumenRuntimeError):
            run("print(missing);")
        with self.assertRaises(LumenRuntimeError):
            run("missing = 3;")


class ControlFlowTests(unittest.TestCase):
    def test_if_else_chain(self):
        program = """
        fn grade(score) {
            if score >= 90 { return "A"; }
            else if score >= 70 { return "B"; }
            else { return "C"; }
        }
        print(grade(95), grade(75), grade(10));
        """
        self.assertEqual(run(program), ["A B C"])

    def test_while_with_break_and_continue(self):
        program = """
        let i = 0;
        let seen = [];
        while true {
            i += 1;
            if i == 3 { continue; }
            if i > 5 { break; }
            push(seen, i);
        }
        print(seen);
        """
        self.assertEqual(run(program), ["[1, 2, 4, 5]"])

    def test_for_over_list_string_and_map(self):
        self.assertEqual(run("for x in [1, 2] { print(x); }"), ["1", "2"])
        self.assertEqual(run('for c in "hi" { print(c); }'), ["h", "i"])
        self.assertEqual(run('for k in {"a": 1, "b": 2} { print(k); }'), ["a", "b"])

    def test_break_outside_loop_is_syntax_error(self):
        with self.assertRaises(LumenSyntaxError):
            run("break;")

    def test_return_outside_function_is_syntax_error(self):
        with self.assertRaises(LumenSyntaxError):
            run("return 1;")

    def test_break_inside_function_inside_loop_is_rejected(self):
        with self.assertRaises(LumenSyntaxError):
            run("while true { fn f() { break; } }")


class FunctionTests(unittest.TestCase):
    def test_recursion(self):
        program = "fn fib(n) { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }"
        self.assertEqual(run(program + "print(fib(15));"), ["610"])

    def test_closures_keep_their_own_state(self):
        program = """
        fn counter() { let n = 0; return fn() { n += 1; return n; }; }
        let a = counter();
        let b = counter();
        a(); a();
        print(a(), b());
        """
        self.assertEqual(run(program), ["3 1"])

    def test_loop_closures_capture_each_iteration(self):
        program = """
        let fs = [];
        for i in range(3) { push(fs, fn() { return i; }); }
        print(fs[0](), fs[1](), fs[2]());
        """
        self.assertEqual(run(program), ["0 1 2"])

    def test_function_without_return_gives_nil(self):
        self.assertEqual(run("fn f() {} print(f());"), ["nil"])

    def test_wrong_number_of_arguments(self):
        with self.assertRaises(LumenRuntimeError) as caught:
            run("fn f(a, b) {} f(1);")
        self.assertIn("takes 2 arguments but was given 1", caught.exception.message)

    def test_deep_recursion_is_a_clean_error(self):
        with self.assertRaises(LumenRuntimeError) as caught:
            run("fn f(n) { return f(n + 1); } f(0);")
        self.assertIn("Stack overflow", caught.exception.message)


class CollectionTests(unittest.TestCase):
    def test_list_indexing(self):
        self.assertEqual(run("let a = [1, 2, 3]; a[0] = 9; print(a, a[-1]);"), ["[9, 2, 3] 3"])

    def test_index_out_of_range(self):
        with self.assertRaises(LumenRuntimeError):
            run("print([1][5]);")

    def test_maps(self):
        program = 'let m = {"x": 1}; m["y"] = 2; print(m, has(m, "y"), len(m));'
        self.assertEqual(run(program), ['{"x": 1, "y": 2} true 2'])

    def test_missing_map_key(self):
        with self.assertRaises(LumenRuntimeError):
            run('print({}["nope"]);')

    def test_nested_printing(self):
        self.assertEqual(result('[1, "a", [nil, true], {"k": 2.5}]'),
                         '[1, "a", [nil, true], {"k": 2.5}]')

    def test_builtins(self):
        self.assertEqual(result("range(1, 10, 3)"), "[1, 4, 7]")
        self.assertEqual(result("sort([3, 1, 2])"), "[1, 2, 3]")
        self.assertEqual(result('join(split("a b c"), "-")'), "a-b-c")
        self.assertEqual(result('num("42") + 1'), "43")
        self.assertEqual(result("type(fn() {})"), "function")


class ErrorHandlingTests(unittest.TestCase):
    def test_catch_runtime_error(self):
        self.assertEqual(run("try { 1 / 0; } catch e { print(e); }"), ["Division by zero"])

    def test_throw_any_value(self):
        program = 'try { throw {"code": 7}; } catch e { print(e["code"]); }'
        self.assertEqual(run(program), ["7"])

    def test_syntax_error_position_and_format(self):
        source = "let x = 1;\nlet y = x +;"
        with self.assertRaises(LumenSyntaxError) as caught:
            run(source)
        error = caught.exception
        self.assertEqual(error.line, 2)
        self.assertIn("^", error.format(source))

    def test_runtime_error_has_call_trace(self):
        source = "fn inner() { return nil + 1; }\nfn outer() { return inner(); }\nouter();"
        with self.assertRaises(LumenRuntimeError) as caught:
            run(source)
        text = caught.exception.format(source)
        self.assertIn("in inner, called on line 2", text)
        self.assertIn("in outer, called on line 3", text)


class ToolingTests(unittest.TestCase):
    def test_repl_echoes_expression_values(self):
        interpreter = Interpreter(output=lambda text: None)
        self.assertIsNone(run_repl_input("let x = 4;", interpreter))
        self.assertEqual(run_repl_input("x * 2", interpreter), 8)

    def test_ast_dump(self):
        tree = Parser(Lexer("1 + 2 * 3;").tokenize()).parse()
        text = dump(tree)
        self.assertIn("Binary(op='+')", text)
        self.assertIn("Binary(op='*')", text)

    def test_command_line_reports_errors(self):
        path = EXAMPLES.parent / "tests" / "_broken.lum"
        path.write_text("print(1 +);\n")
        try:
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(main([str(path)]), 1)
            self.assertIn("SyntaxError on line 1", err.getvalue())
        finally:
            path.unlink()


class ExampleProgramTests(unittest.TestCase):
    def run_example(self, name):
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([str(EXAMPLES / name)]), 0)
        return out.getvalue()

    def test_all_examples_run(self):
        for path in EXAMPLES.glob("*.lum"):
            with self.subTest(example=path.name):
                self.run_example(path.name)

    def test_calculator_does_bedmas(self):
        output = self.run_example("calculator.lum")
        self.assertIn("1 + 2 * 3 = 7", output)
        self.assertIn("2 * (3 + 4) ^ 2 - 1 = 97", output)
        self.assertIn("(1 + 2 -> error: missing a closing bracket", output)


if __name__ == "__main__":
    unittest.main()
