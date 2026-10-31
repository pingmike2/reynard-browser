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
DISABLE_LTO=false

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
		# LTO 在 iOS 全量构建里耗时最多，且 6 小时 job 上限下没有余量。
		--disable-lto)
			DISABLE_LTO=true
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
	# d952c21 曾在此显式选 ld64，因为 Gecko 157 的 bootstrap 工具链是 LLVM21，
	# 与 Xcode 26 的 ld64 同版本。Gecko 158 起 bootstrap 升到 LLVM22，ld64 读不了
	# 它产出的 bitcode（"Unknown attribute kind (105)"），故交给 lld —— 与编译器同版本。
	# 链接器二进制由工作流通过 LD 环境变量指定。
	echo "ac_add_options --enable-ios-target=13.0"
	echo "ac_add_options --enable-optimize"
	echo "ac_add_options --enable-release"
	echo "ac_add_options --enable-rust-simd"
	if [ "$DISABLE_LTO" = true ]; then
		# Gecko 全量编译在 macos-26 runner 上要 340 分钟上下，6 小时 job
		# 上限下没有余量。LTO 是其中最贵的环节，链接期还要把全量 bitcode
		# 重新优化一遍；关掉后 iOS 产物变大一些，但能稳定落在时限内。
		echo "ac_add_options --disable-lto"
	else
		echo "ac_add_options --enable-lto"
	fi
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
