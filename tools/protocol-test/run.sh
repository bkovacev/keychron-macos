#!/usr/bin/env bash
# Cross-language protocol test: compiles the real firmware source on the host,
# drives it through known states, and decodes its output with the real Swift
# decoders.
#
#   ./run.sh [path-to-keychron-qmk-checkout]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
QMK="${1:-$ROOT/firmware/qmk}"
BT="$QMK/keyboards/keychron/bluetooth"

if [[ ! -f "$BT/battery.h" ]]; then
    echo "error: no Keychron QMK checkout at $QMK" >&2
    echo "       run firmware/install.sh --no-build first, or pass the path" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> compiling firmware source on the host"
clang -std=gnu11 -Wall -Wextra -Wno-unused-parameter -O0 \
    -DSTM32_SERIAL_USE_USART2=1 -DSTM32_SERIAL_USE_USART1=0 -DSTM32_SERIAL_USE_USART3=0 \
    -DSTM32_SERIAL_USE_UART4=0 -DSTM32_SERIAL_USE_UART5=0 -DSTM32_SERIAL_USE_USART6=0 \
    -DSTM32_SERIAL_USE_UART7=0 -DSTM32_SERIAL_USE_UART8=0 -DSTM32_SERIAL_USE_LPUART1=0 \
    -DCKBT51_INT_INPUT_PIN=1 \
    -I "$HERE/stubs" -I "$BT" -I "$ROOT/firmware/src" \
    "$HERE/harness.c" "$ROOT/firmware/src/battery_report.c" \
    -o "$WORK/harness"

echo "==> compiling swift decoders"
# The decoders pull in the action vocabulary and the permission helper, so
# those come along; the menu bar and power-source code does not.
swiftc -O \
    "$ROOT/macos/Sources/K10ProBattery/BatteryState.swift" \
    "$ROOT/macos/Sources/K10ProBattery/Control.swift" \
    "$ROOT/macos/Sources/K10ProBattery/Permission.swift" \
    "$ROOT/macos/Sources/K10ProBattery/KeyboardMonitor.swift" \
    "$HERE/main.swift" \
    -o "$WORK/decode_check"

echo "==> running"
"$WORK/harness" | "$WORK/decode_check"
