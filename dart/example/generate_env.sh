#!/bin/bash
#
# Regenerates example/outputs/local.env from example/local.yaml.
#
# Pass an output directory to write somewhere else instead. That makes the example checkable:
# generate into a temp dir and diff the result against the committed output, and the example can no
# longer drift away from what the CLI actually emits.
#
#   bash example/generate_env.sh "$TMPDIR/pnv-example"
#   diff -u example/outputs/local.env "$TMPDIR/pnv-example/local.env"

cd "$(dirname "$(dirname "$0")")" || exit 1

SECRET=8p_dVm0Zn6qypTW0
OUTPUT="${1:-example/outputs}"

dart run pnv generate env -k $SECRET -i example/local.yaml -o "$OUTPUT"
