#!/bin/bash
# Build mado-browser pixel plugin
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
swiftc "$SCRIPT_DIR/mado-browser.swift" -o "$SCRIPT_DIR/mado-browser" -sdk "$(xcrun --show-sdk-path)" -framework WebKit -framework AppKit
echo "Built: $SCRIPT_DIR/mado-browser"
