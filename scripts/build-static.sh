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
if [ -d "$SRC/cmd/9router-go" ]; then
	MAINPKG="./cmd/9router-go/"
elif [ -d "$SRC/cmd" ]; then
	# cmd/ holds helper binaries too; ./cmd/... is not a single package.
	MAINPKG="./cmd/9router-go/"
else
	MAINPKG="."
fi
[ -d "$SRC${MAINPKG#.}" ] || MAINPKG="."

# The frontend is embedded by the Go build. dist/ is gitignored upstream, so a
# clean clone has no assets unless we build them.
if [ ! -d "$SRC/web/dist" ]; then
	echo "==> building frontend"
	( cd "$SRC/web" && { bun install --frozen-lockfile || bun install; } && bun run build )
fi

mkdir -p "$OUT"
# Relative output dirs are resolved before build_one cd's into the source tree,
# otherwise the binary lands in $SRC/dist and the size check looks in the wrong
# place (this is what broke the first CI run).
case "$OUT" in
	/*) ;;
	*) OUT="$PWD/$OUT" ;;
esac

# Upstream prints the version with a leading "v" of its own; strip ours so the
# banner does not read "vv1.9.15".
VERSION="${TAG#v}"

# arch -> GOARCH, plus ABI pinning that OpenWrt targets actually use.
# OpenWrt ARM is little-endian; mips routers are big-endian except mipsel ones.
build_one() {
	arch="$1"; goarch="$2"; extra="$3"
	out="$OUT/9router-go-linux-$arch-static"
	echo "==> $arch  GOARCH=$goarch $extra"
	# shellcheck disable=SC2086
	( cd "$SRC" && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" $extra \
		go build -trimpath -buildvcs=false \
			-ldflags "-s -w -X 9router/proxy/internal/updater.CurrentVersion=$VERSION" \
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

# ARCHES lets a caller build a subset (e.g. ARCHES=arm64 for a quick router
# test). Only amd64 and arm64 are supported: upstream v1.9.15 uses 64-bit-sized
# int constants, so 32-bit targets (armv7, 386, mips, ...) do not compile.
WANTED=" ${ARCHES:-amd64 arm64} "
want() {
	case "$WANTED" in
		*" $1 "*) return 0 ;;
		*) echo "==> skipping $1 (not in ARCHES)" >&2; return 1 ;;
	esac
}

want amd64    && build_one amd64    amd64   ""
want arm64    && build_one arm64    arm64   ""

( cd "$OUT" && sha256sum ./*.gz | sed 's#\./##' > SHA256SUMS.txt )

echo "==> assets in $OUT"
ls -l "$OUT"
