"""Code and prose exemptions for named-credential redaction (GH#37382).

Imported by credential-transcript-scrub.py. Mirror of
.agents/plugins/opencode-aidevops/display-redaction.mjs.
"""
import re

# GH#37382: unquoted code expressions and prose after a sensitive label are not
# literals. Quoted, bracketed, URL, PEM and token-prefix values are never
# exempted, and no entropy threshold applies (GH#35829). Unspaced dotenv/shell
# NAME=value keeps only the keyword and Markdown-emphasis exemptions. Mirror of
# .agents/plugins/opencode-aidevops/display-redaction.mjs.
LITERAL_START = re.compile(r"^[\"'(\[<]")
ARROW_FOLLOWS = re.compile(r"^\s*=>")
_KEYWORD_OR_EMPHASIS = r"(?i:async|await|false|function|lambda|new|nil|true|typeof|yield)$|[*_]+$"
UNSPACED_NON_LITERAL = re.compile(rf"^(?:{_KEYWORD_OR_EMPHASIS})")
SPACED_NON_LITERAL = re.compile(
    rf"^(?:{_KEYWORD_OR_EMPHASIS}"
    r"|[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\("
    r"|(?:process\.env|import\.meta\.env|os\.environ|ENV)(?:[.\[]|$))",
    re.ASCII,
)
TYPE_ANNOTATION = re.compile(
    r"^(?i:any|array|bool|boolean|bytes|dict|float|int|list|number|object|optional|promise|record|str|string|unknown)"
    r"(?:[\[<.]|$)"
)
CONSTANT_REFERENCE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$")
PROSE_WORD = re.compile(r"^[A-Za-z][a-z]{0,19}$")
PROSE_STOP_WORDS = {
    "a", "an", "and", "are", "as", "be", "by", "for", "if", "in", "is", "it", "not", "of", "on", "or", "the",
    "that", "this", "to", "with", "you", "your",
}
TRAILING_COMMENT = re.compile(r"^[ \t]+(?:#|//|;)")
MAX_FOLLOWING_CONTEXT = 200


def following_line_text(source: str, index: int) -> str:
    """Return the rest of the matched line, bounded for linear scanning."""
    line_end = source.find("\n", index)
    end = min(len(source) if line_end < 0 else line_end, index + MAX_FOLLOWING_CONTEXT)
    return source[index:end]


def is_prose_label_value(value: str, following: str) -> bool:
    """Return whether a label value starts an ordinary sentence."""
    if not PROSE_WORD.match(value) or following[:1] not in {" ", "\t"} or TRAILING_COMMENT.match(following):
        return False
    words = re.split(r"[ \t]+", following.lstrip(" \t"))[:4]
    return any(word.lower() in PROSE_STOP_WORDS for word in words)


def is_type_annotation(value: str, _following: str) -> bool:
    """Return whether a colon value names a type, as in `password: str`."""
    return bool(TYPE_ANNOTATION.match(value))


def is_constant_statement(value: str, following: str) -> bool:
    """Return whether an assignment copies a named constant, as in `x = NAME_TOKEN;`."""
    return bool(CONSTANT_REFERENCE.match(value)) and following.startswith(";")


OPERATOR_RULES = {":": (is_type_annotation, is_prose_label_value), "=": (is_constant_statement,)}


def is_code_or_prose_value(separator: str, value: str, following: str) -> bool:
    """Return whether an unquoted value after a sensitive name is code or prose."""
    if ARROW_FOLLOWS.match(following):
        return True
    if LITERAL_START.match(value):
        return False
    operator = separator.strip()
    if separator == operator:
        return bool(UNSPACED_NON_LITERAL.match(value))
    rules = OPERATOR_RULES.get(operator, ())
    return bool(SPACED_NON_LITERAL.match(value)) or any(rule(value, following) for rule in rules)
