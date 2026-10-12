#!/usr/bin/env python3
"""Scan supabase/migrations/*.sql for jsonb_build_object / json_build_object
calls that exceed the PostgreSQL function-argument limit.

PostgreSQL allows at most 100 arguments per function call. Every key AND
every value of a *_build_object call is an argument, so a flat call tops
out at 50 keys. We fail at >80 arguments (>40 keys) to leave headroom.

Split big objects and join them with || instead — see
supabase/migrations/094_get_exchange_action_split.sql.

Usage: python3 scripts/check_jsonb_args.py
Exit code 0 = all calls within the limit; 1 = at least one violation.
"""

import glob
import re
import sys

LIMIT = 80
CALL_RE = re.compile(r"\bjsonb?_build_object\s*\(")


def call_end(sql: str, open_paren: int) -> int:
    """Return the index just past the ')' matching sql[open_paren], handling
    nested parens, '...' strings ('' escape), $tag$ dollar-quoting, and
    -- / /* */ comments."""
    i = open_paren
    depth = 0
    n = len(sql)
    while i < n:
        c = sql[i]
        if c == "'":
            i += 1
            while i < n:
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if c == "$":
            m = re.match(r"\$[A-Za-z_0-9]*\$", sql[i:])
            if m:
                tag = m.group(0)
                close = sql.find(tag, i + len(tag))
                if close != -1:
                    i = close + len(tag)
                    continue
        if c == "-" and i + 1 < n and sql[i + 1] == "-":
            nl = sql.find("\n", i)
            i = n if nl == -1 else nl + 1
            continue
        if c == "/" and i + 1 < n and sql[i + 1] == "*":
            close = sql.find("*/", i + 2)
            i = n if close == -1 else close + 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def count_args(sql: str, open_paren: int, end: int) -> int:
    """Count top-level commas inside the call's parens -> argument count."""
    i = open_paren + 1
    depth = 0
    commas = 0
    saw_content = False
    n = end - 1  # exclude the closing paren
    while i < n:
        c = sql[i]
        if c == "'":
            saw_content = True
            i += 1
            while i < n:
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if c == "$":
            m = re.match(r"\$[A-Za-z_0-9]*\$", sql[i:])
            if m:
                tag = m.group(0)
                close = sql.find(tag, i + len(tag))
                if close != -1 and close < n:
                    saw_content = True
                    i = close + len(tag)
                    continue
        if c == "-" and i + 1 < n and sql[i + 1] == "-":
            nl = sql.find("\n", i)
            i = n if nl == -1 else nl + 1
            continue
        if c == "/" and i + 1 < n and sql[i + 1] == "*":
            close = sql.find("*/", i + 2)
            i = n if close == -1 else close + 2
            continue
        if c == "(":
            depth += 1
            saw_content = True
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            commas += 1
        elif not c.isspace():
            saw_content = True
        i += 1
    return commas + 1 if saw_content else 0


def main() -> int:
    failures = []
    rows = []
    for path in sorted(glob.glob("supabase/migrations/*.sql")):
        sql = open(path, encoding="utf-8").read()
        for m in CALL_RE.finditer(sql):
            open_paren = sql.index("(", m.start())
            end = call_end(sql, open_paren)
            args = count_args(sql, open_paren, end)
            line = sql.count("\n", 0, m.start()) + 1
            rows.append((path, line, args, args > LIMIT))
            if args > LIMIT:
                failures.append((path, line, args))

    for path, line, args, over in rows:
        flag = "  <-- OVER LIMIT" if over else ""
        print(f"{path}:{line}: {args} args{flag}")

    if failures:
        print(
            f"\nFAIL: {len(failures)} call(s) exceed {LIMIT} arguments "
            f"(Postgres limit is 100). Split them and join with ||.",
            file=sys.stderr,
        )
        return 1
    print(f"\nOK: {len(rows)} call(s), all within {LIMIT} arguments.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
