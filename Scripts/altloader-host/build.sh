#!/bin/sh
# Costruisce il prototipo. x86_64 perche' deve dlopen moduli Wine x86_64.
set -e
cd "$(dirname "$0")"
clang -arch x86_64 -O1 -o host host.c -Wl,-no_pie \
  -Wl,-pagezero_size,0x1000 -Wl,-image_base,0x200000000 \
  -Wl,-segaddr,WINE_RESERVE,0x1000 -Wl,-segaddr,WINE_TOP_DOWN,0x7ff000000000 2>&1 | grep -v deprecated || true
