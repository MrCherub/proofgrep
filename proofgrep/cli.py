from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

TEXT_EXTENSIONS = {
    ".md",
    ".markdown",
    ".txt",
    ".tex",
    ".lean",
    ".typ",
    ".sty",
}

DEFAULT_ROOTS = [
    Path("~/ObsidianVault").expanduser(),
    Path("~/Developer/latex").expanduser(),
    Path("~/Developer/logicbox").expanduser(),
    Path("~/Documents/latex").expanduser(),
]

STOPWORDS = {
    "a", "about", "an", "and", "are", "can", "do", "does", "file", "files", "find", "for", "from",
    "give", "how", "i", "in", "is", "it", "known", "locate", "me", "my", "of", "on", "open", "or",
    "path", "pull", "say", "show", "tell", "that", "the", "their", "these", "this", "to", "what",
    "where", "which", "who", "why", "with", "your",
}

NORD = {
    "path": "38;2;136;192;208",
    "line": "38;2;180;142;173",
    "match": "38;2;235;203;139",
    "context": "38;2;216;222;233",
    "separator": "38;2;94;129;172",
    "title": "38;2;163;190;140",
    "muted": "38;2;129;161;193",
    "reset": "0",
}

HELP_EPILOG = """examples:
  proofgrep
  proofgrep ask \"What do my notes say about Navier-Stokes?\"
  proofgrep find theorem ~/Developer/logicbox --type tex --context 1
"""


@dataclass
class QuestionHit:
    path: Path
    line_number: int
    line_text: str
    before: list[tuple[int, str]]
    after: list[tuple[int, str]]
    score: int
    matched_terms: list[str]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="proofgrep",
        description="Search proof and note corpora locally",
        epilog=HELP_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command")

    find_parser = subparsers.add_parser("find", help="Find matching lines")
    find_parser.add_argument("query", help="Search query")
    find_parser.add_argument("paths", nargs="*", help="Files or directories to search")
    find_parser.add_argument("--type", dest="file_type", choices=["md", "tex", "lean", "txt", "typ", "sty", "all"], default="all")
    find_parser.add_argument("--hidden", action="store_true", help="Include hidden files")
    find_parser.add_argument("--context", type=int, default=0, help="Context lines")
    find_parser.add_argument("--ignore-case", action="store_true", help="Case-insensitive search")
    find_parser.add_argument(
        "--literal",
        action="store_true",
        help="Use the query exactly as written instead of flexible space/hyphen matching",
    )
    find_parser.set_defaults(func=run_find)

    ask_parser = subparsers.add_parser("ask", help="Ask a question and retrieve relevant snippets")
    ask_parser.add_argument("query", help="Question or search prompt")
    ask_parser.add_argument("paths", nargs="*", help="Files or directories to search")
    ask_parser.add_argument("--type", dest="file_type", choices=["md", "tex", "lean", "txt", "typ", "sty", "all"], default="all")
    ask_parser.add_argument("--hidden", action="store_true", help="Include hidden files")
    ask_parser.add_argument("--context", type=int, default=1, help="Context lines around each hit")
    ask_parser.add_argument("--limit", type=int, default=8, help="Maximum number of hits to show")
    ask_parser.set_defaults(func=run_ask)

    chat_parser = subparsers.add_parser("chat", help="Open an interactive proofgrep prompt")
    chat_parser.add_argument("paths", nargs="*", help="Files or directories to search")
    chat_parser.add_argument("--type", dest="file_type", choices=["md", "tex", "lean", "txt", "typ", "sty", "all"], default="all")
    chat_parser.add_argument("--hidden", action="store_true", help="Include hidden files")
    chat_parser.add_argument("--context", type=int, default=1, help="Context lines around each hit")
    chat_parser.add_argument("--limit", type=int, default=8, help="Maximum number of hits to show")
    chat_parser.set_defaults(func=run_chat)

    return parser


def use_color() -> bool:
    force_color = os.environ.get("FORCE_COLOR")
    if force_color:
        return True
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def paint(text: str, color: str, enabled: bool) -> str:
    if not enabled:
        return text
    return f"\033[{color}m{text}\033[{NORD['reset']}m"


def highlight_text(line: str, matcher: re.Pattern[str], enabled: bool) -> str:
    if not enabled:
        return line

    def repl(match: re.Match[str]) -> str:
        return paint(match.group(0), NORD["match"], True)

    return matcher.sub(repl, line)


def format_line(path: Path, line_number: int, text: str, is_match: bool, matcher: re.Pattern[str], enabled: bool) -> str:
    prefix = ">" if is_match else "-"
    prefix_colored = paint(prefix, NORD["match"] if is_match else NORD["separator"], enabled)
    path_colored = paint(str(path), NORD["path"], enabled)
    line_colored = paint(str(line_number), NORD["line"], enabled)
    body = highlight_text(text, matcher, enabled) if is_match else paint(text, NORD["context"], enabled)
    return f"{prefix_colored} {path_colored}:{line_colored}:{body}"


def allowed_extensions(file_type: str) -> set[str]:
    return TEXT_EXTENSIONS if file_type == "all" else {f".{file_type}"}


def normalize_paths(raw_paths: list[str], *, defaults: list[Path] | None = None) -> list[Path]:
    if raw_paths:
        return [Path(os.path.expanduser(path)).resolve() for path in raw_paths]
    if defaults is not None:
        return [path.resolve() for path in defaults if path.exists()]
    return [Path.cwd()]


def iter_files(paths: Iterable[Path], file_type: str, include_hidden: bool) -> Iterable[Path]:
    allowed = allowed_extensions(file_type)
    for root in paths:
        if root.is_file():
            if root.suffix.lower() in allowed:
                yield root
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            if not include_hidden and any(part.startswith(".") for part in path.parts):
                continue
            if path.suffix.lower() in allowed:
                yield path


def build_pattern(query: str, literal: bool) -> str:
    if literal:
        return query
    parts = [re.escape(part) for part in query.split() if part]
    if not parts:
        return re.escape(query)
    if len(parts) == 1:
        return parts[0]
    return r"[-\\s]+".join(parts)


def extract_terms(query: str) -> list[str]:
    terms = re.findall(r"[a-zA-Z0-9][a-zA-Z0-9+_-]*", query.lower())
    cleaned = [term for term in terms if term not in STOPWORDS and len(term) > 1]
    seen: set[str] = set()
    result: list[str] = []
    for term in cleaned:
        if term in seen:
            continue
        seen.add(term)
        result.append(term)
    return result


def run_rg(query: str, paths: list[Path], file_type: str, include_hidden: bool, context: int, ignore_case: bool, literal: bool) -> int:
    cmd = ["rg", "--line-number", "--color=never"]
    if context:
        cmd.extend(["--context", str(context)])
    if include_hidden:
        cmd.append("--hidden")
    if ignore_case:
        cmd.append("--ignore-case")
    if literal:
        cmd.append("--fixed-strings")
        pattern = query
    else:
        cmd.append("--pcre2")
        pattern = build_pattern(query, literal=False)
    if file_type != "all":
        cmd.extend(["-g", f"*.{file_type}"])
    else:
        for glob in ["*.md", "*.markdown", "*.txt", "*.tex", "*.lean", "*.typ", "*.sty"]:
            cmd.extend(["-g", glob])
    cmd.append(pattern)
    cmd.extend(str(path) for path in paths)
    return subprocess.run(cmd).returncode


def run_python(query: str, paths: list[Path], file_type: str, include_hidden: bool, context: int, ignore_case: bool, literal: bool) -> int:
    flags = re.IGNORECASE if ignore_case else 0
    pattern = re.escape(query) if literal else build_pattern(query, literal=False)
    matcher = re.compile(pattern, flags)
    matched = False
    colors = use_color()

    for path in iter_files(paths, file_type, include_hidden):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue

        context_ranges: list[tuple[int, int]] = []
        for index, line in enumerate(lines):
            if not matcher.search(line):
                continue
            matched = True
            start = max(0, index - context)
            end = min(len(lines), index + context + 1)
            if context_ranges and start <= context_ranges[-1][1]:
                prev_start, prev_end = context_ranges[-1]
                context_ranges[-1] = (prev_start, max(prev_end, end))
            else:
                context_ranges.append((start, end))

        for range_index, (start, end) in enumerate(context_ranges):
            if range_index > 0:
                print(paint("--", NORD["separator"], colors))
            for ctx_index in range(start, end):
                is_match = matcher.search(lines[ctx_index]) is not None
                print(format_line(path, ctx_index + 1, lines[ctx_index], is_match, matcher, colors))
    return 0 if matched else 1


def query_has_file_intent(query: str) -> bool:
    return any(word in query.lower().split() for word in {"file", "files", "path", "locate", "open"})


def score_path(path: Path, terms: list[str], phrase_matcher: re.Pattern[str], file_intent: bool) -> tuple[int, list[str]]:
    path_lower = str(path).lower()
    name_lower = path.name.lower()
    stem_lower = path.stem.lower()
    matched_terms: list[str] = []
    score = 0

    if phrase_matcher.search(name_lower):
        score += 60 if file_intent else 36
    elif phrase_matcher.search(path_lower):
        score += 30 if file_intent else 18

    for term in terms:
        if term == stem_lower:
            score += 72 if file_intent else 42
            matched_terms.append(term)
        elif term in name_lower:
            score += 28 if file_intent else 16
            matched_terms.append(term)
        elif term in path_lower:
            score += 10 if file_intent else 6
            matched_terms.append(term)

    if file_intent and path.suffix.lower() in TEXT_EXTENSIONS:
        score += 8

    return score, list(dict.fromkeys(matched_terms))


def score_line(line_lower: str, terms: list[str], phrase_matcher: re.Pattern[str]) -> tuple[int, list[str]]:
    matched_terms = [term for term in terms if term in line_lower]
    phrase_hit = phrase_matcher.search(line_lower) is not None
    if not matched_terms and not phrase_hit:
        return 0, []

    score = len(matched_terms) * 14
    if phrase_hit:
        score += 24
    if line_lower.strip().startswith("#"):
        score += 6
    return score, matched_terms


def search_question(query: str, paths: list[Path], file_type: str, include_hidden: bool, context: int, limit: int) -> list[QuestionHit]:
    terms = extract_terms(query)
    if not terms:
        terms = [query.lower()]
    phrase_pattern = build_pattern(" ".join(terms), literal=False)
    phrase_matcher = re.compile(phrase_pattern, re.IGNORECASE)
    file_intent = query_has_file_intent(query)

    hits: list[QuestionHit] = []
    for path in iter_files(paths, file_type, include_hidden):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue

        path_score, path_terms = score_path(path, terms, phrase_matcher, file_intent)
        if path_score:
            hits.append(
                QuestionHit(
                    path=path,
                    line_number=1,
                    line_text=f"file match: {path.name}",
                    before=[],
                    after=[],
                    score=path_score,
                    matched_terms=path_terms,
                )
            )

        for index, line in enumerate(lines):
            line_lower = line.lower()
            score, matched_terms = score_line(line_lower, terms, phrase_matcher)
            if score == 0:
                continue
            before = [(n + 1, lines[n]) for n in range(max(0, index - context), index)]
            after = [(n + 1, lines[n]) for n in range(index + 1, min(len(lines), index + context + 1))]
            hits.append(
                QuestionHit(
                    path=path,
                    line_number=index + 1,
                    line_text=line,
                    before=before,
                    after=after,
                    score=score,
                    matched_terms=matched_terms,
                )
            )

    hits.sort(key=lambda hit: (-hit.score, str(hit.path), hit.line_number))
    return hits[:limit]


def print_question_results(query: str, hits: list[QuestionHit]) -> int:
    colors = use_color()
    terms = extract_terms(query)
    pattern = build_pattern(" ".join(terms) if terms else query, literal=False)
    matcher = re.compile(pattern, re.IGNORECASE)

    if not hits:
        print(paint("No relevant notes found.", NORD["muted"], colors))
        return 1

    print(paint(f"Query: {query}", NORD["title"], colors))
    last_path: Path | None = None
    for index, hit in enumerate(hits, start=1):
        if hit.path != last_path:
            if last_path is not None:
                print()
            print(paint(f"[{index}] {hit.path}", NORD["path"], colors))
            last_path = hit.path
        else:
            print(paint(f"[{index}]", NORD["muted"], colors))

        for line_number, text in hit.before:
            print(format_line(hit.path, line_number, text, False, matcher, colors))
        print(format_line(hit.path, hit.line_number, hit.line_text, True, matcher, colors))
        for line_number, text in hit.after:
            print(format_line(hit.path, line_number, text, False, matcher, colors))
        terms_label = ", ".join(hit.matched_terms) if hit.matched_terms else "phrase"
        print(paint(f"  score={hit.score} terms={terms_label}", NORD["muted"], colors))
    return 0


def open_hit(hit: QuestionHit) -> int:
    path_str = str(hit.path)
    if shutil.which("nvim") is not None:
        cmd = ["nvim", path_str]
    else:
        editor = os.environ.get("EDITOR")
        if editor:
            cmd = shlex.split(editor) + [path_str]
        elif sys.platform == "darwin":
            cmd = ["open", path_str]
        else:
            cmd = ["xdg-open", path_str]
    return subprocess.run(cmd).returncode


def run_find(args: argparse.Namespace) -> int:
    paths = normalize_paths(args.paths)
    if shutil.which("rg") is not None:
        return run_rg(args.query, paths, args.file_type, args.hidden, args.context, args.ignore_case, args.literal)
    return run_python(args.query, paths, args.file_type, args.hidden, args.context, args.ignore_case, args.literal)


def run_ask(args: argparse.Namespace) -> int:
    paths = normalize_paths(args.paths, defaults=DEFAULT_ROOTS)
    hits = search_question(args.query, paths, args.file_type, args.hidden, args.context, args.limit)
    return print_question_results(args.query, hits)


def run_chat(args: argparse.Namespace) -> int:
    paths = normalize_paths(args.paths, defaults=DEFAULT_ROOTS)
    colors = use_color()
    last_hits: list[QuestionHit] = []
    print(paint("∀ ∃ proofgrep", NORD["title"], colors))
    print(paint("Ask about your notes. Type :q to quit.", NORD["muted"], colors))
    print(paint("Type a result number to open that file.", NORD["muted"], colors))
    while True:
        try:
            query = input(paint("proofgrep> ", NORD["match"], colors))
        except EOFError:
            print()
            return 0
        query = query.strip()
        if not query:
            continue
        if query in {":q", "quit", "exit"}:
            return 0
        if query in {":help", "help"}:
            print("Type a question like: What do my notes say about Navier-Stokes?")
            print("After results appear, type a number like 1 to open that file.")
            continue
        if query.isdigit():
            if not last_hits:
                print(paint("No previous results to open.", NORD["muted"], colors))
                continue
            index = int(query)
            if not 1 <= index <= len(last_hits):
                print(paint(f"No result {index}.", NORD["muted"], colors))
                continue
            hit = last_hits[index - 1]
            print(paint(f"Opening {hit.path}", NORD["title"], colors), flush=True)
            returncode = open_hit(hit)
            if returncode != 0:
                print(paint("Failed to open result.", NORD["muted"], colors))
            continue
        hits = search_question(query, paths, args.file_type, args.hidden, args.context, args.limit)
        last_hits = hits
        print_question_results(query, hits)
        print()


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command is None:
        if not sys.stdin.isatty():
            parser.print_help(sys.stderr)
            return 2
        chat_args = argparse.Namespace(paths=[], file_type="all", hidden=False, context=1, limit=8)
        return run_chat(chat_args)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
