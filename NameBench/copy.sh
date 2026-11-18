#!/bin/sh
# F021 · Copies the cases into the bench's test target, and the converted model if it is in
# NameBench/Model/ (ignored), so a device runs the same cases as the Mac. NameBenchTests pins
# each copy's SHA-256 to the Mac's original. Downloads nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
from="$here/../Tests/DisguiseTests/Fixtures"
to="$here/Tests/NameBenchTests/Cases"
mkdir -p "$to"
for f in disguise-corpus.jsonl disguise-unseen.jsonl detection-tiers.jsonl bench-names.jsonl; do
    cp "$from/$f" "$to/$f"
done
rm -rf "$to/Model"
if [ -d "$here/Model/NameNER.mlmodelc" ]; then
    mkdir -p "$to/Model"
    cp -R "$here/Model/." "$to/Model/"
    echo "the model is copied"
else
    echo "no model in NameBench/Model/: the Core ML candidate prints \"not available there\""
fi
shasum -a 256 "$to"/*.jsonl
