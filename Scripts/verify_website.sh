#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$script_directory/build_website.sh"
python3 "$script_directory/verify_website.py"

printf 'Cowlick website verification passed.\n'
