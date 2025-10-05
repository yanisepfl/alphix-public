#!/bin/bash

# Alphix - Slither Analysis Script
# This script runs Slither static analysis on the Alphix contracts

echo "Running Slither Static Analysis..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Clean previous build artifacts
echo "Cleaning build artifacts..."
forge clean

# Remove old report if exists
rm -f slither-report.json

echo ""
echo "Running Slither analysis..."
echo ""

# Run Slither
slither . \
  --filter-paths "lib/|test/|script/" \
  --json slither-report.json

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Analysis complete!"
echo ""
echo "Reports generated:"
echo "  - slither-report.json (full JSON report)"
echo ""
