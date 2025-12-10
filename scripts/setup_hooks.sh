#!/bin/sh
set -e

HOOK_DIR=".git/hooks"
PRE_PUSH="$HOOK_DIR/pre-push"

echo "Installing pre-push hook to $PRE_PUSH..."

mkdir -p "$HOOK_DIR"

cat << 'EOF' > "$PRE_PUSH"
#!/bin/sh
set -e

echo "🤖 [pre-push] Checking formatting..."

# Check formatting for build.zig and src/
# zig fmt --check returns error if files are not formatted
~/.zvm/bin/zig fmt --check build.zig src/

echo "✅ [pre-push] Formatting looks good."
EOF

chmod +x "$PRE_PUSH"
echo "✅ Hook installed successfully."
