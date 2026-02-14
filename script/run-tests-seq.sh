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
