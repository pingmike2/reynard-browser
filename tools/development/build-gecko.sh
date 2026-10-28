#!/bin/sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/engine/firefox"

TARGET="aarch64-apple-ios"
USE_SCCACHE=false
AUTO_CLOBBER=false
DISABLE_JEMALLOC=false
DISABLE_WASM_SANDBOXED=false

for arg in "$@"; do
	case "$arg" in
		--use-sccache)
			USE_SCCACHE=true
			;;
		--auto-clobber)
			AUTO_CLOBBER=true
			;;
		--disable-jemalloc)
			DISABLE_JEMALLOC=true
			;;
		# CI 诊断构建不需要 Gecko 可选的 WASM 沙箱库，跳过它
		# 可以省掉一整套 WASI SDK 依赖。
		--without-wasm-sandboxed-libraries)
			DISABLE_WASM_SANDBOXED=true
			;;
	esac
done

if [ "$USE_SCCACHE" = true ]; then
	SCCACHE_BIN="${SCCACHE_PATH:-$(command -v sccache)}"
fi

cd "$ROOT_DIR"

if [ ! -d "$FIREFOX_DIR" ]; then
	echo "Missing firefox source at $FIREFOX_DIR"
	echo "Add the submodule, then run tools/development/update-gecko.sh."
	exit 1
fi

if [ -f "$FIREFOX_DIR/.mozconfig" ]; then
	mv "$FIREFOX_DIR/.mozconfig" "$FIREFOX_DIR/.mozconfig.bak"
fi

{
	echo "ac_add_options --enable-application=mobile/ios"
	echo "ac_add_options --target=$TARGET"
	# bootstrap 工具链是 LLVM22，Xcode 26 自带的 ld64 只认 LLVM21，
	# 读不了它产出的 bitcode；lld 与编译器同版本，故改用它。
	echo "ac_add_options --enable-linker=lld"
	echo "ac_add_options --enable-ios-target=13.0"
	echo "ac_add_options --enable-optimize"
	echo "ac_add_options --enable-release"
	echo "ac_add_options --enable-rust-simd"
	echo "ac_add_options --enable-lto"
	echo "ac_add_options --disable-debug"
	echo "ac_add_options --disable-tests"
	echo "ac_add_options --enable-bootstrap"
	if [ "$USE_SCCACHE" = true ]; then
		echo "mk_add_options 'export RUSTC_WRAPPER=$SCCACHE_BIN'"
		echo "ac_add_options --with-ccache=$SCCACHE_BIN"
	fi
	if [ "$DISABLE_JEMALLOC" = true ]; then
		echo "ac_add_options --disable-jemalloc"
	fi
	if [ "$DISABLE_WASM_SANDBOXED" = true ]; then
		echo "ac_add_options --without-wasm-sandboxed-libraries"
	fi
	if [ "$AUTO_CLOBBER" = true ]; then
		echo "mk_add_options AUTOCLOBBER=1"
	fi
} > "$FIREFOX_DIR/.mozconfig"

if ! rustup target list | grep -q "^$TARGET (installed)"; then
	rustup target add "$TARGET"
fi

cd "$FIREFOX_DIR"
./mach build

rm "$FIREFOX_DIR/.mozconfig"
if [ -f "$FIREFOX_DIR/.mozconfig.bak" ]; then
	mv "$FIREFOX_DIR/.mozconfig.bak" "$FIREFOX_DIR/.mozconfig"
fi
