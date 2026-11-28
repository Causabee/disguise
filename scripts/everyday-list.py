#!/usr/bin/env python3
"""Builds Sources/Disguise/Resources/Names/everyday.lzfse: the everyday words the rules ask after a
role and in an address line (fix, 28 Nov 2026). The same file on every device, so every device sends
the same text.

From the shipped lists, nothing fetched: the 30,000 commonest words of words.lzfse (Mozilla Common
Voice, German, CC0), without every word the first-name list holds (Wikidata, CC0), so no person's
name is in it. Folded, one a line, sorted by bytes, as NameKnowledge reads an unranked list.

    python3 scripts/everyday-list.py
"""
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NAMES = os.path.join(HERE, "..", "Sources", "Disguise", "Resources", "Names")
TOP = 30_000


def unpack(name, folder):
    out = os.path.join(folder, name + ".txt")
    subprocess.run(["compression_tool", "-decode", "-a", "lzfse", "-i", os.path.join(NAMES, name + ".lzfse"), "-o", out], check=True)
    with open(out, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


with tempfile.TemporaryDirectory() as folder:
    words = unpack("words", folder)[:TOP]
    first = set(unpack("first-names", folder))
    kept = sorted({w for w in words if w not in first}, key=lambda w: w.encode("utf-8"))
    plain = os.path.join(folder, "everyday.txt")
    with open(plain, "w", encoding="utf-8") as f:
        f.write("\n".join(kept) + "\n")
    subprocess.run(["compression_tool", "-encode", "-a", "lzfse", "-i", plain, "-o", os.path.join(NAMES, "everyday.lzfse")], check=True)
    print(len(kept), "words")
