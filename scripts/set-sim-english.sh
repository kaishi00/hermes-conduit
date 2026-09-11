#!/bin/zsh
# Pin all booted/available iPhone simulators to English so the test suite's
# English-copy assertions stay stable on macOS hosts whose system language
# is not English (fresh simulators inherit the Mac's locale; CI runners are
# already en_US, so this matters for local runs on e.g. zh-CN Macs).
# Usage: scripts/set-sim-english.sh [device-set-id|name]   (default: all available)

set -euo pipefail

pin() {
  local id="$1"
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl spawn "$id" defaults write "Apple Global Domain" AppleLanguages -array "en" "en-US"
  xcrun simctl spawn "$id" defaults write "Apple Global Domain" AppleLocale -string "en_US"
  xcrun simctl shutdown "$id" 2>/dev/null || true
  echo "pinned $id → en/en_US (reboot applies)"
}

if [[ $# -ge 1 ]]; then
  pin "$1"
else
  # 列出可用模拟器并全部钉住
  xcrun simctl list devices available | awk -F'[()]' '/iPhone|iPad/ {print $2}' | while read -r id; do
    [[ -n "$id" ]] && pin "$id"
  done
  echo "完成。下次启动模拟器时以英文系统语言生效。"
fi
