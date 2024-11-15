#!/bin/bash

cd "$(dirname "$(dirname "$0")")" || exit 1

SECRET=8p_dVm0Zn6qypTW0

dart run pnv env -k $SECRET -i example/local.yaml -o example/outputs