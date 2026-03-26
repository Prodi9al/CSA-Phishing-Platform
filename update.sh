#!/usr/bin/env bash
# update.sh — CSA Phishing Platform Updater

echo "=== CSA Phishing Platform — Updating ==="

# 1. Pull latest code
if [ -d .git ]; then
    echo "[+] Pulling latest changes from GitHub..."
    git pull origin master
else
    echo "[!] Not a git repository. Skip pull."
fi

# 2. Update dependencies
echo "[+] Updating dependencies (npm install)..."
npm install

echo "✅ Update complete! Run ./launch.sh to start."
