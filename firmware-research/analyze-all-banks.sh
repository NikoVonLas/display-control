#!/bin/zsh

set -euo pipefail

firmware=${1:?Pass the path to the stock firmware image}
ghidra=${GHIDRA_HOME:?Set GHIDRA_HOME to the Ghidra installation}/support/analyzeHeadless
script_dir=${0:A:h}/ghidra
project_dir=$(mktemp -d "${TMPDIR:-/tmp}/acer-ghidra.XXXXXX")
print "Analysis output: $project_dir"

if [[ ! -f $firmware ]]; then
  print -u2 "Firmware image not found: $firmware"
  exit 1
fi

for bank in {0..17}; do
  bank_hex=$(printf '%02x' $bank)
  bank_bin=$project_dir/xv282k-bank${bank_hex}.bin
  bank_dump=$project_dir/xv282k-bank${bank_hex}-functions.c

  if [[ ! -f $bank_bin ]]; then
    dd if=$firmware of=$bank_bin bs=65536 skip=$bank count=1 status=none
  fi

  if [[ -f $bank_dump ]]; then
    print "bank ${bank_hex}: already analyzed"
    continue
  fi

  print "bank ${bank_hex}: importing and decompiling"
  "$ghidra" "$project_dir" xv282k \
      -import $bank_bin \
      -loader BinaryLoader \
      -processor 8051:BE:16:default \
      -overwrite \
      -analysisTimeoutPerFile 600 \
      -scriptPath $script_dir \
      -postScript Bootstrap8051.java $bank \
      -postScript DumpFunctions.java $bank_dump
done
