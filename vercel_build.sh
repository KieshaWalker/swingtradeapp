#!/bin/bash
set -e

FLUTTER_VERSION="3.41.2"
FLUTTER_DIR="$HOME/flutter"

echo "→ Installing Flutter $FLUTTER_VERSION..."
git clone https://github.com/flutter/flutter.git \
  --branch "$FLUTTER_VERSION" \
  --single-branch \
  --depth 1 \
  "$FLUTTER_DIR"

export PATH="$PATH:$FLUTTER_DIR/bin"

echo "→ Enabling web..."
flutter config --enable-web --no-analytics

echo "→ Getting dependencies..."
flutter pub get

echo "→ Building for web (release)..."
flutter build web --release \
  --web-renderer canvaskit \
  --dart-define=SUPABASE_URL="${SUPABASE_URL}" \
  --dart-define=SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY}" \
  --dart-define=FMP_API_KEY="${FMP_API_KEY}" \
  --dart-define=SEC_API_KEY="${SEC_API_KEY}"

echo "✓ Build complete → build/web"
