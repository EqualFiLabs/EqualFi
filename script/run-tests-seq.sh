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

for dir in test/*/; do
  # Special-case equallend-direct: run each test file individually to avoid
  # viaIR + memoryguard stack-depth issues when compiling the whole suite.
  if [[ "$dir" == "test/equallend-direct/" ]]; then
    if compgen -G "test/equallend-direct/suite-*/*.t.sol" > /dev/null; then
      for f in test/equallend-direct/suite-*/*.t.sol; do
        run "forge test --match-path \"$f\""
      done
    fi
    continue
  fi

  if compgen -G "${dir}"*t.sol > /dev/null; then
    run "forge test --match-path \"${dir}*t.sol\""
  fi
done

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
