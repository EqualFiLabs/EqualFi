#!/usr/bin/env bash
set -u -o pipefail

failures=()

run() {
  local cmd="$1"
  echo ">>> $cmd"
  if ! eval "$cmd"; then
    failures+=("$cmd")
  fi
}

run 'forge test --match-path "test/admin/*t.sol"'
run 'forge test --match-path "test/equallend-direct/*t.sol"'
run 'forge test --match-path "test/facets/*t.sol"'
run 'forge test --match-path "test/gas/*t.sol"'
run 'forge test --match-path "test/libraries/*t.sol"'
run 'forge test --match-path "test/maintenance/*t.sol"'
run 'forge test --match-path "test/managed-pools/*t.sol"'
run 'forge test --match-path "test/mocks/*t.sol"'
run 'forge test --match-path "test/penalty/*t.sol"'
run 'forge test --match-path "test/root/*t.sol"'
run 'forge test --match-path "test/treasury/*t.sol"'
run 'forge test --match-path "test/views/*t.sol"'
run 'forge test --match-path "test/derivatives/*t.sol"'

if (( ${#failures[@]} > 0 )); then
  echo
  echo "Test failures (${#failures[@]}):"
  for cmd in "${failures[@]}"; do
    echo "- $cmd"
  done
  exit 1
fi

echo
echo "All test groups passed."
