#!/bin/sh
# Build static 9router-go release assets for OpenWrt (musl, no libc).
#
# Upstream release binaries are glibc-dynamic and do not run on OpenWrt.
# CGO_ENABLED=0 produces a static ELF that works on musl and glibc alike.
#
# Usage:  ./scripts/build-static.sh [tag] [output-dir]
#   tag         upstream git tag to build (default: newest tag in the repo)
#   output-dir  where the .gz assets and SHA256SUMS.txt land (default: ./dist)
#
# Requirements on the build host: git, go >= 1.22, bun (frontend), gzip, sha256sum.
# CI uses .github/workflows/release.yml, which runs this script on a tag push.

set -eu

REPO="${REPO:-https://github.com/luqman-v1/9router-go}"
TAG="${1:-}"
OUT="${2:-$PWD/dist}"

if [ -z "$TAG" ]; then
	TAG=$(git ls-remote --tags --refs "$REPO" | sed 's#.*refs/tags/##' | sort -V | tail -n 1)
fi
[ -n "$TAG" ] || { echo "cannot determine upstream tag" >&2; exit 1; }

SRC="${SRC:-$(mktemp -d)/9router-go}"
echo "==> building $TAG from $REPO into $SRC"
[ -d "$SRC/.git" ] || git clone --depth 1 --branch "$TAG" "$REPO" "$SRC"

# Resolve the main package once; older layouts keep main at the repo root.
if [ -d "$SRC/cmd" ]; then MAINPKG="./cmd/..."; else MAINPKG="."; fi

# The frontend is embedded by the Go build. dist/ is gitignored upstream, so a
# clean clone has no assets unless we build them.
if [ ! -d "$SRC/web/dist" ]; then
	echo "==> building frontend"
	( cd "$SRC/web" && { bun install --frozen-lockfile || bun install; } && bun run build )
fi

mkdir -p "$OUT"

# arch -> GOARCH, plus ABI pinning that OpenWrt targets actually use.
# OpenWrt ARM is little-endian; mips routers are big-endian except mipsel ones.
build_one() {
	arch="$1"; goarch="$2"; extra="$3"
	out="$OUT/9router-go-linux-$arch-static"
	echo "==> $arch  GOARCH=$goarch $extra"
	# shellcheck disable=SC2086
	( cd "$SRC" && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" $extra \
		go build -trimpath -buildvcs=false -ldflags "-s -w" \
			-o "$out" "$MAINPKG" )
	[ -s "$out" ] || { echo "ERROR: build produced nothing for $arch" >&2; exit 1; }
	if command -v file >/dev/null 2>&1; then
		file "$out" | grep -q 'statically linked' || {
			echo "ERROR: $out is not statically linked" >&2
			file "$out" >&2
			exit 1
		}
	fi
	gzip -9 -c "$out" > "$out.gz"
	rm -f "$out"
}

build_one amd64    amd64   ""
build_one arm64    arm64   ""
build_one armv7    arm     "GOARM=7"
build_one armv6    arm     "GOARM=6"
build_one 386      386     ""
build_one mips     mips    "GOMIPS=softfloat"
build_one mipsle   mipsle  "GOMIPS=softfloat"
build_one mips64   mips64  "GOMIPS64=softfloat"
build_one mips64le mips64le "GOMIPS64=softfloat"

( cd "$OUT" && sha256sum ./*.gz | sed 's#\./##' > SHA256SUMS.txt )

echo "==> assets in $OUT"
ls -l "$OUT"
