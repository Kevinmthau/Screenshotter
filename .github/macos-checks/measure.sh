#!/bin/bash
# Temporary: before/after measurements for the idle-scan change on a GitHub-hosted Mac.
# Prints SPOTLIGHT, SCAN, APP and RESULT lines; raw logs stay in /tmp/logs.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
logs=/tmp/logs
work=/tmp/scan-measure
support="$HOME/Library/Application Support/Screenshot Renamer"
window=45
mkdir -p "$logs"
rm -rf "$work"
mkdir -p "$work"
trap 'jobs -p | xargs kill 2>/dev/null' EXIT

base="$(git -C "$root" merge-base origin/main HEAD)"
echo "RESULT before = $base, after = $(git -C "$root" rev-parse HEAD)"
git -C "$root" worktree add --detach "$work/before" "$base" >/dev/null 2>&1 || { echo "RESULT worktree failed"; exit 1; }

compile() { # checkout output [swiftc flags...]
  local checkout="$1" output="$2"
  shift 2
  xcrun swiftc -O -parse-as-library -swift-version 5 -module-name Bench "$@" \
    "$checkout"/Sources/RenamerCore/*.swift "$root/.github/macos-checks/bench.swift" -o "$output"
}
compile "$work/before" "$work/bench-before" || { echo "RESULT before bench build failed"; exit 1; }
compile "$root" "$work/bench-after" -D METADATA_HOOK || { echo "RESULT after bench build failed"; exit 1; }
bench="$work/bench-after"

# Runner images disable Spotlight indexing, so use a small indexed disk image when possible.
folders="$HOME/ScanBench"
if hdiutil create -quiet -size 64m -fs APFS -volname ScanBench "$work/ScanBench.dmg" &&
   hdiutil attach -quiet "$work/ScanBench.dmg" && [ -d /Volumes/ScanBench ]; then
  folders=/Volumes/ScanBench
  sudo mdutil -i on "$folders" >/dev/null 2>&1 || true
fi
mkdir -p "$folders"
echo "RESULT folders in $folders: $(mdutil -s "$folders" 2>&1 | tail -1 | xargs)"
plain="$folders/Plain"
desktop="$folders/Desktop"
if ! "$bench" prepare "$plain" 200 0 || ! "$bench" prepare "$desktop" 200 1; then echo "RESULT prepare failed"; exit 1; fi
if mdutil -s "$folders" 2>&1 | grep -q "Indexing enabled"; then
  mdimport "$plain" "$desktop" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    answers="$("$bench" answers "$desktop")"
    [[ "$answers" == *"true=200 "* ]] && break
    sleep 1
  done
fi
"$bench" answers "$plain"
"$bench" answers "$desktop"

for round in 1 2; do
  for folder in "$plain" "$desktop"; do
    for version in before after; do
      "$work/bench-$version" scan "$folder" "$version $(basename "$folder") round $round" 30
    done
  done
done

build_app() { # checkout scratch
  (cd "$1" && swift build -c release --product ScreenshotRenamer --scratch-path "$2" >"$logs/build-$(basename "$2").log" 2>&1) &&
    echo "$(cd "$1" && swift build -c release --scratch-path "$2" --show-bin-path)/ScreenshotRenamer"
}
appBefore="$(build_app "$work/before" "$work/app-before")" || { echo "RESULT before app build failed"; tail -20 "$logs/build-app-before.log"; exit 1; }
appAfter="$(build_app "$root" "$work/app-after")" || { echo "RESULT after app build failed"; tail -20 "$logs/build-app-after.log"; exit 1; }

cpu_seconds() { ps -o time= -p "$1" | awk -F: '{ print $(NF-1) * 60 + $NF }'; }

# Runs the real app, enabled and watching the metadata folder with nothing pending, then samples
# it with top (CPU, idle wakeups, energy impact) and counts its scans with fs_usage.
measure_app() { # label binary folder
  local label="$1" binary="$2" folder="$3" pid="" known=0 scoped cpu0 cpu1 opens lstats
  for scoped in 0 1; do
    rm -rf "$support"
    "$bench" settings "$folder" "$support/settings.json" "$scoped" || continue
    "$binary" >"$logs/app-$label.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 30); do
      known="$("$bench" known "$support/settings.json" 2>/dev/null)" || known=0
      [ "$known" -ge 200 ] && break
      sleep 1
    done
    [ "$known" -ge 200 ] && break
    echo "RESULT app $label did not scan with scoped=$scoped bookmark"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
  done
  if [ -z "$pid" ]; then tail -20 "$logs/app-$label.log"; return 1; fi
  sleep 5
  cpu0="$(cpu_seconds "$pid")"
  # shellcheck disable=SC2024 # root is needed for the tools, not for writing the runner's logs
  sudo top -l 2 -s "$window" -stats pid,command,cpu,time,idlew,power >"$logs/top-$label.txt" 2>&1
  cpu1="$(cpu_seconds "$pid")"
  # shellcheck disable=SC2024
  sudo fs_usage -w -f filesys -t "$window" "$pid" >"$logs/fs-$label.txt" 2>&1
  kill "$pid"
  wait "$pid" 2>/dev/null
  echo "APP $label: $(awk -v a="$cpu0" -v b="$cpu1" 'BEGIN { printf "%.2f", b - a }') s CPU time in ${window} s idle"
  awk -v pid="$pid" '$1 == "PID" { block++; if (block == 2) print } block == 2 && ($1 == pid || $2 ~ /^md(s|s_stores|worker)/)' \
    "$logs/top-$label.txt" | sed "s/^/APP $label top: /"
  opens="$(grep -F "$folder " "$logs/fs-$label.txt" | grep -c " open")"
  lstats="$(grep -F "$folder/" "$logs/fs-$label.txt" | grep -c "lstat")"
  echo "APP $label: fs_usage in ${window} s: $opens opens of the folder, $lstats lstat calls on its files"
  if [ "$opens" -eq 0 ]; then head -5 "$logs/fs-$label.txt" | sed "s/^/APP $label fs_usage: /"; fi
  grep -F "$folder" "$logs/fs-$label.txt" | head -2 | sed "s/^/APP $label fs_usage sample: /"
}
measure_app before "$appBefore" "$desktop"
measure_app after "$appAfter" "$desktop"
