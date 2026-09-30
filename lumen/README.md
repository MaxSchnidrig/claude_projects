# Lumen

Lumen is a small but complete programming language, written in Python with
no extra libraries. It has variables, functions, closures, recursion, lists,
maps, loops, error handling and an interactive prompt.

```
fn fib(n) {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}
print("fib(20) =", fib(20));
```

## Running it

From this `lumen/` folder:

```
python3 -m lumen                          # interactive prompt (REPL)
python3 -m lumen examples/calculator.lum  # run a program
python3 -m lumen --tokens examples/tour.lum   # see what the lexer produces
python3 -m lumen --ast examples/tour.lum      # see the syntax tree
python3 -m unittest                       # run the tests
```

## How it works

Running a program goes through three stages:

```
source text --> Lexer --> tokens --> Parser --> syntax tree --> Interpreter --> output
```

| File | Job |
| --- | --- |
| `lumen/lexer.py` | Splits the text into **tokens**: numbers, strings, names, keywords and operators, each tagged with its line and column. |
| `lumen/parser.py` | A **recursive descent parser**. It turns tokens into a tree, with one method per precedence level, so `1 + 2 * 3` becomes `1 + (2 * 3)`. |
| `lumen/ast_nodes.py` | The shapes of the tree (`Binary`, `If`, `Call`, ...). |
| `lumen/interpreter.py` | Walks the tree and runs it. Scopes are chains of `Environment`s, which is what makes closures work. |
| `lumen/values.py` | How Lumen values are stored in Python, and how they are printed. |
| `lumen/builtins.py` | Built-in functions such as `print`, `len` and `range`. |
| `lumen/errors.py` | Error messages that point at the exact spot in your code. |

Errors show where they happened and which calls led there:

```
RuntimeError on line 1, column 25: Can't add a nil and a number
    fn inner() { return nil + 1; }
                            ^
  in inner, called on line 2
  in outer, called on line 3
```

## The language

```
# Comments start with a hash
let x = 10;                  # variables
x += 5;                      # also -=, *=, /=, %=
let name = "Ada";            # strings, with \n \t \" \\ escapes
let items = [1, 2, 3];       # lists (negative indexes count from the end)
let ages = {"ada": 36};      # maps, with string or number keys
let nothing = nil;

if x > 10 and not (x == 12) {
    print("big");
} else if x > 5 {
    print("medium");
} else {
    print("small");
}

while x > 0 { x -= 1; }                  # break and continue work too
for item in items { print(item); }       # also loops over strings and map keys

fn add(a, b) { return a + b; }           # named functions
let double = fn(n) { return n * 2; };    # anonymous functions

try {
    throw "something went wrong";        # throw any value
} catch error {
    print("caught:", error);             # runtime errors are catchable too
}
```

**Operators**, from loosest to tightest: `or`, `and`, `not`,
`== !=`, `< <= > >=`, `+ -`, `* / %`, unary `-`, and `**` (power, right
associative, so `2 ** 3 ** 2` is `2 ** 9`).

`/` gives a whole number when the division is exact (`6 / 3` is `2`) and a
decimal otherwise (`7 / 2` is `3.5`). Only `nil` and `false` count as false.

**Built-in functions:** `print`, `input`, `type`, `str`, `num`, `len`,
`range`, `push`, `pop`, `keys`, `has`, `sort`, `join`, `split`, `abs`,
`floor`, `sqrt`, `random`, `random_int`, `clock`.

## Examples

- `examples/tour.lum`: a quick tour of the language.
- `examples/functional.lum`: `map`, `filter` and `reduce` written in Lumen,
  plus closures and memoization.
- `examples/algorithms.lum`: quicksort, binary search, the Sieve of
  Eratosthenes, GCD and the Towers of Hanoi.
- `examples/calculator.lum`: the week 2 calculator rebuilt in Lumen. It now
  does BEDMAS, exponents, brackets and negative numbers, using the same
  parsing technique Lumen itself uses.
