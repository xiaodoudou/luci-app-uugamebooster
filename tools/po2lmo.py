#!/usr/bin/env python3
"""Compile a .po file into the .lmo catalogue LuCI loads at runtime.

LuCI ships po2lmo for this, but it is a host tool built from the LuCI tree and is
not on a router or in a plain checkout. The format is small enough to reproduce.

Layout, from LuCI's po2lmo.c and template_lmo.c:

    [ value strings, each padded with NULs to a 4-byte boundary ]
    [ index: one 16-byte entry per string, sorted by key_id     ]
    [ uint32: byte offset at which the index starts             ]

Every field is big-endian. An index entry is four uint32s:

    key_id   SuperFastHash of the msgid
    val_id   SuperFastHash of the msgstr
    offset   where the value starts
    length   value length, not counting the padding

The runtime hashes the string it wants and binary-searches the index, which is
why the entries have to be sorted. An entry whose key and value hash the same is
dropped, matching po2lmo: translating a string to itself is a no-op.

Usage: tools/po2lmo.py <input.po> <output.lmo>
"""
import re
import struct
import sys

MASK = 0xFFFFFFFF


def sfh_hash(data: bytes) -> int:
    """Paul Hsieh's SuperFastHash, as LuCI's template_lmo.c computes it."""
    length = len(data)
    if length == 0:
        return 0

    def u16(i):
        return data[i] | (data[i + 1] << 8)

    def sc(i):
        """The reference hash reads the odd trailing byte as a signed char, so
        anything above 0x7f sign-extends. Every non-ASCII string depends on it."""
        b = data[i]
        return b - 256 if b > 127 else b

    hashv = length
    rem = length & 3
    n = length >> 2
    pos = 0

    for _ in range(n):
        hashv = (hashv + u16(pos)) & MASK
        tmp = ((u16(pos + 2) << 11) ^ hashv) & MASK
        hashv = ((hashv << 16) ^ tmp) & MASK
        pos += 4
        hashv = (hashv + (hashv >> 11)) & MASK

    if rem == 3:
        hashv = (hashv + u16(pos)) & MASK
        hashv ^= (hashv << 16) & MASK
        hashv ^= (sc(pos + 2) << 18) & MASK
        hashv = (hashv + (hashv >> 11)) & MASK
    elif rem == 2:
        hashv = (hashv + u16(pos)) & MASK
        hashv ^= (hashv << 11) & MASK
        hashv = (hashv + (hashv >> 17)) & MASK
    elif rem == 1:
        hashv = (hashv + sc(pos)) & MASK
        hashv ^= (hashv << 10) & MASK
        hashv = (hashv + (hashv >> 1)) & MASK

    hashv ^= (hashv << 3) & MASK
    hashv = (hashv + (hashv >> 5)) & MASK
    hashv ^= (hashv << 4) & MASK
    hashv = (hashv + (hashv >> 17)) & MASK
    hashv ^= (hashv << 25) & MASK
    hashv = (hashv + (hashv >> 6)) & MASK
    return hashv & MASK


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


def unescape(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            out.append(ESCAPES.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


STR = re.compile(r'^\s*"(.*)"\s*$')


def parse_po(path):
    """Yield (msgid, msgstr) for every translated entry."""
    entries = []
    key = val = None
    target = None

    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if line.startswith("#") or not line.strip():
            continue
        if line.startswith("msgid_plural") or line.startswith("msgstr["):
            # Plural forms are not used by this package; skip rather than
            # mistranslate them.
            target = None
            continue
        if line.startswith("msgid"):
            if key is not None and val:
                entries.append((key, val))
            key, val = "", ""
            target = "key"
            line = line[len("msgid"):].strip()
        elif line.startswith("msgstr"):
            target = "val"
            line = line[len("msgstr"):].strip()

        m = STR.match(line)
        if not m or target is None:
            continue
        if target == "key":
            key += unescape(m.group(1))
        else:
            val += unescape(m.group(1))

    if key is not None and val:
        entries.append((key, val))
    # The header entry has an empty msgid.
    return [(k, v) for k, v in entries if k]


def build(entries):
    blob = bytearray()
    index = []

    for msgid, msgstr in entries:
        kb = msgid.encode("utf-8")
        vb = msgstr.encode("utf-8")
        key_id = sfh_hash(kb)
        val_id = sfh_hash(vb)
        if key_id == val_id:
            continue
        offset = len(blob)
        blob += vb
        while len(blob) % 4:
            blob += b"\0"
        index.append((key_id, val_id, offset, len(vb)))

    index.sort(key=lambda e: e[0])

    out = bytearray(blob)
    for entry in index:
        out += struct.pack(">IIII", *entry)
    out += struct.pack(">I", len(blob))
    return bytes(out), len(index)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    entries = parse_po(sys.argv[1])
    data, count = build(entries)
    with open(sys.argv[2], "wb") as f:
        f.write(data)
    print("wrote %s (%d translations, %d bytes)" % (sys.argv[2], count, len(data)))


if __name__ == "__main__":
    main()
