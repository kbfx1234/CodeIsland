#!/usr/bin/env bash
set -euo pipefail

fail=0

check_command() {
  local name="$1"
  local command_path
  command_path="$(command -v "$name" || true)"
  if [[ -z "$command_path" ]]; then
    printf 'MISSING %-10s\n' "$name"
    fail=1
    return
  fi
  printf 'FOUND   %-10s %s\n' "$name" "$command_path"
}

check_command codex
check_command kiro-cli
check_command kiro

printf '\nVersions:\n'
codex --version 2>&1 | head -1 || true
kiro-cli --version 2>&1 | head -1 || true
kiro --version 2>&1 | head -1 || true

printf '\ncmux context:\n'
printf 'CMUX_SURFACE_ID=%s\n' "${CMUX_SURFACE_ID:-<unset>}"
printf 'CMUX_WORKSPACE_ID=%s\n' "${CMUX_WORKSPACE_ID:-<unset>}"

printf '\nCodeIsland source checks:\n'
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="$root_dir/Sources/CodeIsland/ConfigInstaller.swift"
rg -q 'source: "codex"' "$config_file" && printf 'OK      Codex hook installer present\n' || { printf 'FAIL    Codex hook installer missing\n'; fail=1; }
rg -q 'source: "kiro"' "$config_file" && rg -q 'case \.kiroAgent' "$config_file" && printf 'OK      Kiro CLI hook installer present\n' || { printf 'FAIL    Kiro CLI hook installer missing\n'; fail=1; }
rg -q 'CMUX_SURFACE_ID|cmux' "$root_dir/Sources/CodeIsland" && printf 'OK      cmux integration symbols present\n' || { printf 'FAIL    cmux integration symbols missing\n'; fail=1; }

printf '\nResult: '
if [[ "$fail" -eq 0 ]]; then
  printf 'PASS (preflight)\n'
else
  printf 'FAIL\n'
  exit 1
fi
