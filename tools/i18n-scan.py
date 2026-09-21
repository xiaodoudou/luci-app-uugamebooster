#!/usr/bin/env python3
"""Collect every translatable string in the package into a .pot template.

LuCI's own build ships i18n-scan.pl, but it needs the build tree. This does the
same job for just this package: it reads the Lua sources for translate(...) and
the views for the two template translation forms.

Usage: tools/i18n-scan.py [output.pot]     (default: po/templates/uugamebooster.pot)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "luci-app-uugamebooster", "luasrc")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, "po", "templates", "uugamebooster.pot")

# translate("a" .. "b") - the argument is often concatenated across lines, so the
# whole call is matched first and the pieces joined afterwards.
LUA_CALL = re.compile(r'translate\(\s*((?:"(?:[^"\\]|\\.)*"\s*(?:\.\.\s*)?)+)\)')
LUA_PART = re.compile(r'"((?:[^"\\]|\\.)*)"')

# <%:escaped%> and <%_raw%>
TPL = re.compile(r"<%[:_]((?:[^%]|%(?!>))*)%>")


def walk(root, exts):
    for base, _dirs, files in os.walk(root):
        for f in sorted(files):
            if f.endswith(exts):
                yield os.path.join(base, f)


def collect():
    """Return [(string, [locations])] in the order the strings were found."""
    found = {}
    order = []

    def add(text, where):
        text = text.strip()
        if not text:
            return
        if text not in found:
            found[text] = []
            order.append(text)
        if where not in found[text]:
            found[text].append(where)

    for path in walk(SRC, (".lua",)):
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        src = open(path, encoding="utf-8").read()
        for m in LUA_CALL.finditer(src):
            joined = "".join(LUA_PART.findall(m.group(1)))
            add(joined, "%s:%d" % (rel, src.count("\n", 0, m.start()) + 1))

    for path in walk(SRC, (".htm",)):
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        src = open(path, encoding="utf-8").read()
        for m in TPL.finditer(src):
            add(m.group(1), "%s:%d" % (rel, src.count("\n", 0, m.start()) + 1))

    return [(s, found[s]) for s in order]


def po_escape(s):
    return (s.replace("\\", "\\\\")
             .replace('"', '\\"')
             .replace("\n", "\\n")
             .replace("\t", "\\t"))


def main():
    entries = collect()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write('msgid ""\nmsgstr ""\n'
                '"Content-Type: text/plain; charset=UTF-8\\n"\n\n')
        for text, where in entries:
            for w in where:
                f.write("#: %s\n" % w)
            f.write('msgid "%s"\nmsgstr ""\n\n' % po_escape(text))
    print("wrote %s (%d strings)" % (OUT, len(entries)))


if __name__ == "__main__":
    main()
