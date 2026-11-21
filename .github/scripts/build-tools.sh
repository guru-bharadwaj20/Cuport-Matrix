#!/usr/bin/env bash
# Build the tools under test from the commits pinned in matrix/tools.yaml,
# into the layout the adapters in runner/cuport/adapters/ expect:
#
#   $CUPORT_TOOLS/mvcc-v1.3.0/bin/nvcc        (checkout in $CUPORT_TOOLS/src/mvcc)
#   $CUPORT_TOOLS/cumetal-v0.8.0/bin/cumetalc (checkout in $CUPORT_TOOLS/src/cuda-metal)
#
#   .github/scripts/build-tools.sh [all|mvcc|cumetal]
#
# $CUPORT_TOOLS defaults to ~/.local/cuport-tools. A tool whose install is
# already at the pinned commit, and still starts, is not rebuilt, so a restored
# CI cache costs little. Its Homebrew dependencies are installed either way:
# the cache holds only $CUPORT_TOOLS, and both tools load Homebrew LLVM, z3
# and zstd at run time. Needs Homebrew, and full Xcode (or the Metal
# Toolchain component) for CuMetal's `xcrun metal`.
set -euo pipefail

want=${1:-all}
case $want in
  all) tools="mvcc cumetal" ;;
  mvcc|cumetal) tools=$want ;;
  *) echo "unknown tool: $want (want all, mvcc or cumetal)" >&2; exit 2 ;;
esac

repo=$(git rev-parse --show-toplevel)
TOOLS=${CUPORT_TOOLS:-$HOME/.local/cuport-tools}
mkdir -p "$TOOLS/src"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
jobs=$(sysctl -n hw.ncpu)

# pin <id> <field>: a field of one tool entry in matrix/tools.yaml.
pin() {
  awk -v id="$1" -v key="$2" '
    $1 == "-" && $2 == "id:" { cur = $3 }
    cur == id && $1 == key ":" { gsub(/"/, "", $2); print $2; exit }
  ' "$repo/matrix/tools.yaml"
}

# checkout <repo url> <dir> <commit>: a clean tree at exactly <commit>.
checkout() {
  if [ ! -d "$2/.git" ]; then
    git clone -q "$1" "$2"
  fi
  git -C "$2" fetch -q origin "$3"
  git -C "$2" checkout -q --force "$3"
  git -C "$2" submodule update -q --init --recursive
  git -C "$2" clean -qfdx
}

stamp_ok() { [ -f "$1/.cuport-commit" ] && [ "$(cat "$1/.cuport-commit")" = "$2" ]; }

build_mvcc() {
  local version commit prefix src
  version=$(pin mvcc version); commit=$(pin mvcc commit)
  prefix="$TOOLS/mvcc-$version"; src="$TOOLS/src/mvcc"
  brew install --quiet llvm z3 zstd cmake ninja rust
  if stamp_ok "$prefix" "$commit" && "$prefix/bin/nvcc" --version >/dev/null 2>&1; then
    echo "mvcc $version already built at $commit"; return
  fi
  echo "== mvcc $version ($commit)"
  checkout "$(pin mvcc repo)" "$src" "$commit"
  cd "$src"  # install_toolkit.sh runs cargo in the current directory
  LLVM_DIR="$(brew --prefix llvm)/lib/cmake/llvm" \
  MVCC_Z3_LIB="$(brew --prefix z3)/lib" \
  MVCC_ZSTD_LIB="$(brew --prefix zstd)/lib" \
  MVCC_DYLIB_ID="$prefix/lib64/libcudart.dylib" \
  MVCC_PREFIX="$prefix" \
    "$src/tools/install_toolkit.sh" release
  echo "$commit" > "$prefix/.cuport-commit"
  "$prefix/bin/nvcc" --version | tail -1
}

build_cumetal() {
  local version commit prefix src
  version=$(pin cumetal version); commit=$(pin cumetal commit)
  prefix="$TOOLS/cumetal-$version"; src="$TOOLS/src/cuda-metal"
  if ! xcrun --find metal >/dev/null 2>&1; then
    echo "xcrun metal missing; downloading the Metal Toolchain component"
    xcodebuild -downloadComponent MetalToolchain
  fi
  xcrun --find metal && xcrun --find metallib
  brew install --quiet llvm lz4 zstd cmake
  if stamp_ok "$prefix" "$commit" && "$prefix/bin/cumetalc" --version >/dev/null 2>&1; then
    echo "cumetal $version already built at $commit"; return
  fi
  echo "== cumetal $version ($commit)"
  checkout "$(pin cumetal repo)" "$src" "$commit"
  cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCUMETAL_BUILD_TESTS=OFF -DCUMETAL_ENABLE_BINARY_SHIM=OFF \
    -DLLVM_DIR="$(brew --prefix llvm)/lib/cmake/llvm"
  cmake --build "$src/build" --parallel "$jobs"
  rm -rf "$prefix"
  cmake --install "$src/build"
  echo "$commit" > "$prefix/.cuport-commit"
  "$prefix/bin/cumetalc" --version
}

# For `all`, build each tool in its own process (set -e is ignored inside an
# `||` list), so one failed build does not stop the other.
if [ "$want" = all ]; then
  status=0
  for t in $tools; do
    "$0" "$t" || { echo "build of $t failed" >&2; status=1; }
  done
  exit $status
fi
"build_$want"
