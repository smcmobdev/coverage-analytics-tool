#!/bin/bash
# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Create public folder if not exists
mkdir -p public

# 2. Copy the auth gate, login, and dashboard templates to public directory
cp "$SCRIPT_DIR/auth_gate.js" public/auth_gate.js
cp "$SCRIPT_DIR/login.html" public/login.html
cp "$SCRIPT_DIR/dashboard.html" public/index.html

# 3. Run the Dart coverage parser to generate summary.json, history.json, and inject auth scripts
echo "Running Dart coverage parser..."
dart "$SCRIPT_DIR/parse_coverage.dart"
