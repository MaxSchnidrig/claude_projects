"""Error types for Lumen, with helpers for pretty error messages."""


class LumenError(Exception):
    """Base class for every error Lumen reports to the user."""

    kind = "Error"

    def __init__(self, message, line=0, col=0):
        super().__init__(message)
        self.message = message
        self.line = line
        self.col = col
        # The value a Lumen `catch` block receives. `throw` replaces it.
        self.value = message
        # (function name, line it was called from), innermost call first
        self.trace = []

    def add_frame(self, function_name, call_line):
        self.trace.append((function_name, call_line))

    def format(self, source=None):
        """Build a message that points at the exact spot in the source."""
        text = f"{self.kind}: {self.message}"
        if self.line > 0:
            text = f"{self.kind} on line {self.line}, column {self.col}: {self.message}"
            lines = source.splitlines() if source else []
            if self.line <= len(lines):
                code = lines[self.line - 1]
                text += f"\n    {code}\n    {' ' * (self.col - 1)}^"
        frames = [f"\n  in {name}, called on line {line}" for name, line in self.trace]
        if len(frames) > 10:  # deep recursion: show the start and end only
            hidden = len(frames) - 8
            frames = frames[:5] + [f"\n  ... {hidden} more calls ..."] + frames[-3:]
        return text + "".join(frames)


class LumenSyntaxError(LumenError):
    kind = "SyntaxError"


class LumenRuntimeError(LumenError):
    kind = "RuntimeError"
