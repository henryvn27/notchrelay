#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xcrun swift "$root_dir/Scripts/capture_launch_assets.swift" --self-check
xcrun swift "$root_dir/Scripts/validate_launch_assets.swift" --self-check
