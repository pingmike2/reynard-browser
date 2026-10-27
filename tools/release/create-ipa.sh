#!/bin/sh

set -eu

CLANG_PATH="$(xcrun --sdk iphoneos --find clang)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
ARCHIVE_DIR="$ROOT_DIR/dist/Reynard.xcarchive"
APP_DIR="$ARCHIVE_DIR/Products/Applications"
WORK_DIR="$ROOT_DIR/dist/Reynard"

BUILD_TYPE="${1:-normal}"
case "$BUILD_TYPE" in
	--trollstore)
		OUTPUT_NAME="Reynard-TrollStore.tipa"
		PTRACE_JIT_NAME="ts_ptrace_jit"
		;;
	--jailbroken)
		OUTPUT_NAME="Reynard-Jailbroken.ipa"
		PTRACE_JIT_NAME="jb_ptrace_jit"
		;;
	*)
		BUILD_TYPE="normal"
		OUTPUT_NAME="Reynard.ipa"
		;;
esac

cd "$ROOT_DIR"

if [ ! -d "$APP_DIR" ]; then
	echo "Missing archive output at $APP_DIR"
	echo "Run tools/release/build-app.sh first."
	exit 1
fi

APP_PATH="$(find "$APP_DIR" -maxdepth 1 -type d -name '*.app' | head -n 1)"
if [ -z "$APP_PATH" ]; then
	echo "No .app found in $APP_DIR"
	exit 1
fi

# I absolutely hate Apple for this
# Why is my bundle identifier just become unavailable for no reason?
# 覆盖默认 bundle id 前缀（自签安装时可避开与官方包冲突）：
#   BUNDLE_ID_PREFIX=com.example ./tools/release/create-ipa.sh --jailbroken
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.minh-ton}"
plutil -replace CFBundleIdentifier -string "${BUNDLE_ID_PREFIX}.Reynard" "$APP_PATH/Info.plist"
plutil -replace CFBundleIdentifier -string "${BUNDLE_ID_PREFIX}.Reynard.Helper" "$APP_PATH/PlugIns/Reynard Helper.appex/Info.plist"
plutil -replace CFBundleIdentifier -string "${BUNDLE_ID_PREFIX}.Reynard.OpenIn" "$APP_PATH/PlugIns/OpenIn.appex/Info.plist"

rm -rf "$WORK_DIR" "$ROOT_DIR/dist/$OUTPUT_NAME"
mkdir -p "$WORK_DIR/Payload"
cp -R "$APP_PATH" "$WORK_DIR/Payload/"

cd "$WORK_DIR"

if [ "$BUILD_TYPE" != "normal" ]; then
	PTRACE_JIT_SRC="$ROOT_DIR/browser/Reynard/JIT/Unsandboxed/ptrace_jit.c"
	PTRACE_JIT_OUT="Payload/Reynard.app/$PTRACE_JIT_NAME"

	"$CLANG_PATH" \
		-arch arm64 \
		-isysroot "$SDK_PATH" \
		-miphoneos-version-min=13.0 \
		-Os \
		"$PTRACE_JIT_SRC" \
		-o "$PTRACE_JIT_OUT"

	chmod 0755 "$PTRACE_JIT_OUT"
	ldid -S"$ROOT_DIR/browser/Reynard/JIT/Unsandboxed/ptrace_jit.entitlements" "$PTRACE_JIT_OUT"
fi

ldid -S"$ROOT_DIR/browser/Reynard/Entitlements/Reynard.private.entitlements" "Payload/Reynard.app/Reynard"
ldid -S"$ROOT_DIR/browser/Helper/Entitlements/Reynard-Helper.private.entitlements" "Payload/Reynard.app/PlugIns/Reynard Helper.appex/Reynard Helper"

# Gecko dylibs/XUL 与 GeckoView.framework 需要 ldid 伪签名
# （无证书 CI 构建时 AddGecko.sh 跳过了 codesign）
SIGN_FAILED=0
if [ -d "Payload/Reynard.app/Frameworks/GeckoView.framework" ]; then
	for fw_file in "Payload/Reynard.app/Frameworks/GeckoView.framework/Frameworks/"*.dylib "Payload/Reynard.app/Frameworks/GeckoView.framework/Frameworks/XUL" "Payload/Reynard.app/Frameworks/GeckoView.framework/Frameworks/"*.rs "Payload/Reynard.app/Frameworks/GeckoView.framework/XUL" "Payload/Reynard.app/Frameworks/GeckoView.framework/"*.so; do
		if [ -f "$fw_file" ]; then
			if ! ldid -S "$fw_file"; then
				echo "::error::ldid failed to pseudo-sign $fw_file"
				SIGN_FAILED=1
			fi
		fi
	done
	if ! ldid -S "Payload/Reynard.app/Frameworks/GeckoView.framework"; then
		echo "::error::ldid failed to pseudo-sign GeckoView.framework"
		SIGN_FAILED=1
	fi
	if [ "${SIGN_FAILED:-0}" -ne 0 ]; then
		echo "Refusing to package an IPA with unsigned Gecko binaries."
		exit 1
	fi
fi

if [ "$BUILD_TYPE" = "--jailbroken" ]; then
	# libhooker 系越狱拒绝加载 adhoc 签名的 libswift_Concurrency.dylib，
	# 从最后一个正式签名的 0.10.0 里取原版
	SWIFT_CONCURRENCY_DYLIB="Payload/Reynard.app/Frameworks/libswift_Concurrency.dylib"
	if [ ! -f "$SWIFT_CONCURRENCY_DYLIB" ]; then
		echo "$SWIFT_CONCURRENCY_DYLIB is missing from the archive; the jailbroken build would crash on launch under libhooker."
		exit 1
	fi
	{
		SIGNED_IPA="Reynard-0.10.0.ipa"
		SIGNED_DYLIB="Reynard-0.10.0.libswift_Concurrency.dylib"
		cleanup_signed_ipa() {
			rm -f "$SIGNED_IPA" "$SIGNED_DYLIB"
		}
		trap cleanup_signed_ipa EXIT

		if ! curl --fail --location --retry 3 --output "$SIGNED_IPA" \
			"https://github.com/minh-ton/reynard-browser/releases/download/0.10.0/Reynard.ipa"; then
			echo "Failed to download the signed 0.10.0 IPA; refusing to produce a broken build."
			exit 1
		fi

		if ! unzip -p "$SIGNED_IPA" "$SWIFT_CONCURRENCY_DYLIB" > "$SIGNED_DYLIB"; then
			echo "Failed to extract $SWIFT_CONCURRENCY_DYLIB from the signed IPA."
			exit 1
		fi

		if [ ! -s "$SIGNED_DYLIB" ]; then
			echo "Extracted $SWIFT_CONCURRENCY_DYLIB is empty."
			exit 1
		fi

		# 供应链校验：0.10.0 的 dylib 是固定产物，hash 不符就说明
		# release 资产被替换或下载被截断，宁可失败也不出坏包。
		SWIFT_CONCURRENCY_SHA256="cab2c1c922f659d8d96fb2b4b0717e646dca432895443998beadda9a3532386e"
		ACTUAL_SHA256="$(shasum -a 256 "$SIGNED_DYLIB" | awk '{print $1}')"
		if [ "$ACTUAL_SHA256" != "$SWIFT_CONCURRENCY_SHA256" ]; then
			echo "Checksum mismatch for $SWIFT_CONCURRENCY_DYLIB"
			echo "  expected $SWIFT_CONCURRENCY_SHA256"
			echo "  actual   $ACTUAL_SHA256"
			exit 1
		fi

		mv "$SIGNED_DYLIB" "$SWIFT_CONCURRENCY_DYLIB"
		rm -f "$SIGNED_IPA"
	}
fi

zip -r "../$OUTPUT_NAME" Payload -x "._*" -x ".DS_Store" -x "__MACOSX"
