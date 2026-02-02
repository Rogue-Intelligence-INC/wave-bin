#!/bin/bash
# Wave-BIN build script

set -e

echo "🌊 Building Wave-BIN..."

nasm -f bin src/wavec.asm -o wavec.bin

echo "✓ Built: wavec.bin ($(stat -c%s wavec.bin) bytes)"
