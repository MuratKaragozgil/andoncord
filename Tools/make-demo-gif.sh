#!/bin/bash
# Renders docs/demo.gif. A wrapper because the demo shares AgentGlyph.swift
# with the app, and `swift file.swift` runs single files only — so this
# compiles the two files together (the copy to main.swift is what lets a
# multi-file swiftc build keep top-level code).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/docs/demo.gif}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$root/Tools/make-demo-gif.swift" "$tmp/main.swift"
swiftc -O -o "$tmp/gifgen" "$tmp/main.swift" "$root/Sources/AndonKit/Models/AgentGlyph.swift"
"$tmp/gifgen" "$out"
