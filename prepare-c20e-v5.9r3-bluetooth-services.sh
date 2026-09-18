#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' '=== C20e V5.9r3 Bluetooth deployment retired ==='
printf '%s\n' 'ERROR: skwbt caused repeatable kernel memory corruption on the V5.9r2 hybrid stack.' >&2
printf '%s\n' 'Bluetooth must remain disabled until a compatible upper module is available.' >&2
exit 1