#!/bin/bash
set -e

FLUTTER_VERSION="3.41.2"
FLUTTER_DIR="$HOME/flutter"

# Vercel runs as root — Flutter requires this flag
export FLUTTER_ALLOW_ROOT=true

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

# Build --dart-define flags only for env vars that are actually set
DART_DEFINES=""
[ -n "${SUPABASE_URL}" ]      && DART_DEFINES="$DART_DEFINES --dart-define=SUPABASE_URL=${SUPABASE_URL}"
[ -n "${SUPABASE_ANON_KEY}" ] && DART_DEFINES="$DART_DEFINES --dart-define=SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}"
[ -n "${FMP_API_KEY}" ]       && DART_DEFINES="$DART_DEFINES --dart-define=FMP_API_KEY=${FMP_API_KEY}"
[ -n "${SEC_API_KEY}" ]       && DART_DEFINES="$DART_DEFINES --dart-define=SEC_API_KEY=${SEC_API_KEY}"

echo "→ Building for web (release)..."
flutter build web --release $DART_DEFINES

echo "✓ Build complete → build/web"
