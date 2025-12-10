#!/bin/bash
#
# Download and prepare benchmark test data
#
# Usage:
#   ./scripts/download_bench_data.sh
#
# Creates:
#   data/bench/small.txt       100 bytes
#   data/bench/medium.txt      10 KB
#   data/bench/large.txt       1 MB
#   data/bench/huge.txt        10 MB (optional)
#   data/bench/pathological.txt 100 KB repeated chars
#   data/bench/code.txt        500 KB source code
#   data/bench/unicode.txt     200 KB multi-language

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PROJECT_ROOT/data/bench"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create data directory
mkdir -p "$DATA_DIR"

log_info "Downloading benchmark data to $DATA_DIR"

# ==============================================================================
# War and Peace - English prose benchmark
# ==============================================================================

WAR_AND_PEACE_URL="https://www.gutenberg.org/files/2600/2600-0.txt"
WAR_AND_PEACE_FILE="$DATA_DIR/war_and_peace_full.txt"

if [[ ! -f "$WAR_AND_PEACE_FILE" ]]; then
    log_info "Downloading War and Peace..."
    if curl -sL "$WAR_AND_PEACE_URL" -o "$WAR_AND_PEACE_FILE"; then
        log_info "Downloaded $(wc -c < "$WAR_AND_PEACE_FILE" | tr -d ' ') bytes"
    else
        log_warn "Failed to download War and Peace, using generated data"
        # Generate fallback
        python3 -c "
words = 'the quick brown fox jumps over the lazy dog'.split()
text = ' '.join(words * 100000)
print(text[:3300000])
" > "$WAR_AND_PEACE_FILE"
    fi
else
    log_info "War and Peace already downloaded"
fi

# ==============================================================================
# Create size variants
# ==============================================================================

log_info "Creating size variants..."

# Small: 100 bytes
head -c 100 "$WAR_AND_PEACE_FILE" > "$DATA_DIR/small.txt"
log_info "  small.txt: $(wc -c < "$DATA_DIR/small.txt" | tr -d ' ') bytes"

# Medium: 10 KB
head -c 10240 "$WAR_AND_PEACE_FILE" > "$DATA_DIR/medium.txt"
log_info "  medium.txt: $(wc -c < "$DATA_DIR/medium.txt" | tr -d ' ') bytes"

# Large: 1 MB
head -c 1048576 "$WAR_AND_PEACE_FILE" > "$DATA_DIR/large.txt"
log_info "  large.txt: $(wc -c < "$DATA_DIR/large.txt" | tr -d ' ') bytes"

# Huge: 10 MB (optional, for stress tests)
if [[ "${INCLUDE_HUGE:-false}" == "true" ]]; then
    # Replicate War and Peace to get 10MB
    cat "$WAR_AND_PEACE_FILE" "$WAR_AND_PEACE_FILE" "$WAR_AND_PEACE_FILE" "$WAR_AND_PEACE_FILE" | head -c 10485760 > "$DATA_DIR/huge.txt"
    log_info "  huge.txt: $(wc -c < "$DATA_DIR/huge.txt" | tr -d ' ') bytes"
fi

# ==============================================================================
# Pathological input (worst case for BPE)
# ==============================================================================

log_info "Creating pathological input..."

# Repeated single character - worst case for merge operations
python3 -c "print('a' * 102400, end='')" > "$DATA_DIR/pathological.txt"
log_info "  pathological.txt: $(wc -c < "$DATA_DIR/pathological.txt" | tr -d ' ') bytes"

# ==============================================================================
# Code sample
# ==============================================================================

CODE_URL="https://raw.githubusercontent.com/torvalds/linux/master/kernel/sched/core.c"
CODE_FILE="$DATA_DIR/code.txt"

log_info "Downloading code sample..."
if curl -sL "$CODE_URL" -o "$CODE_FILE" 2>/dev/null; then
    # Truncate to ~500KB
    head -c 512000 "$CODE_FILE" > "$CODE_FILE.tmp" && mv "$CODE_FILE.tmp" "$CODE_FILE"
    log_info "  code.txt: $(wc -c < "$CODE_FILE" | tr -d ' ') bytes"
else
    log_warn "Failed to download code sample, generating synthetic code"
    python3 -c "
import random
random.seed(42)

keywords = ['if', 'else', 'for', 'while', 'return', 'int', 'void', 'struct', 'static', 'const']
identifiers = ['foo', 'bar', 'baz', 'count', 'index', 'value', 'result', 'ptr', 'ctx', 'data']
operators = ['+', '-', '*', '/', '==', '!=', '<=', '>=', '&&', '||', '=', '++', '--']

lines = []
for _ in range(10000):
    line_type = random.choice(['decl', 'if', 'for', 'assign', 'return', 'comment'])
    
    if line_type == 'decl':
        lines.append(f'    int {random.choice(identifiers)} = {random.randint(0, 100)};')
    elif line_type == 'if':
        lines.append(f'    if ({random.choice(identifiers)} {random.choice([\"==\", \"!=\", \"<\", \">\"])} {random.randint(0, 100)}) {{')
    elif line_type == 'for':
        lines.append(f'    for (int i = 0; i < {random.randint(1, 100)}; i++) {{')
    elif line_type == 'assign':
        lines.append(f'    {random.choice(identifiers)} {random.choice([\"=\", \"+=\", \"-=\"])} {random.choice(identifiers)};')
    elif line_type == 'return':
        lines.append(f'    return {random.choice(identifiers)};')
    else:
        lines.append(f'    /* {\" \".join(random.choices(identifiers, k=5))} */')

print('\\n'.join(lines)[:512000])
" > "$CODE_FILE"
    log_info "  code.txt: $(wc -c < "$CODE_FILE" | tr -d ' ') bytes (synthetic)"
fi

# ==============================================================================
# Unicode / Multi-language text
# ==============================================================================

log_info "Creating multi-language sample..."

python3 -c "
# Multi-language text samples
samples = [
    # English
    'The quick brown fox jumps over the lazy dog. ',
    # German
    'Der schnelle braune Fuchs springt über den faulen Hund. ',
    # French
    'Le rapide renard brun saute par-dessus le chien paresseux. ',
    # Spanish
    'El rápido zorro marrón salta sobre el perro perezoso. ',
    # Chinese
    '快速的棕色狐狸跳过懒狗。',
    # Japanese
    '素早い茶色の狐は怠惰な犬を飛び越えます。',
    # Korean
    '빠른 갈색 여우가 게으른 개를 뛰어넘습니다. ',
    # Russian
    'Быстрая коричневая лиса перепрыгивает через ленивую собаку. ',
    # Arabic
    'الثعلب البني السريع يقفز فوق الكلب الكسول. ',
    # Hebrew
    'השועל החום המהיר קופץ מעל הכלב העצלן. ',
    # Emoji
    '🦊🐕 👋🌍 🚀✨ 🎉🔥 💻📱 ',
]

import random
random.seed(42)

result = []
size = 0
target = 204800  # 200KB

while size < target:
    sample = random.choice(samples)
    result.append(sample)
    size += len(sample.encode('utf-8'))

print(''.join(result)[:target])
" > "$DATA_DIR/unicode.txt"

log_info "  unicode.txt: $(wc -c < "$DATA_DIR/unicode.txt" | tr -d ' ') bytes"

# ==============================================================================
# JSON sample
# ==============================================================================

log_info "Creating JSON sample..."

python3 -c "
import json
import random
random.seed(42)

# Simulate OpenAI API-like JSON
data = []
for i in range(1000):
    entry = {
        'id': f'chatcmpl-{i:06d}',
        'object': 'chat.completion',
        'created': 1700000000 + i,
        'model': random.choice(['gpt-4', 'gpt-4-turbo', 'gpt-3.5-turbo']),
        'choices': [{
            'index': 0,
            'message': {
                'role': 'assistant',
                'content': ' '.join(random.choices(
                    ['Hello', 'World', 'This', 'is', 'a', 'test', 'response', 
                     'from', 'the', 'AI', 'model', 'with', 'some', 'text'],
                    k=random.randint(10, 50)
                ))
            },
            'finish_reason': 'stop'
        }],
        'usage': {
            'prompt_tokens': random.randint(10, 100),
            'completion_tokens': random.randint(50, 500),
            'total_tokens': random.randint(60, 600)
        }
    }
    data.append(entry)

# Output as JSON lines
for entry in data:
    print(json.dumps(entry))
" | head -c 512000 > "$DATA_DIR/json.txt"

log_info "  json.txt: $(wc -c < "$DATA_DIR/json.txt" | tr -d ' ') bytes"

# ==============================================================================
# Summary
# ==============================================================================

log_info ""
log_info "Benchmark data ready:"
log_info ""
ls -lh "$DATA_DIR"/*.txt
log_info ""
log_info "Total size: $(du -sh "$DATA_DIR" | cut -f1)"
