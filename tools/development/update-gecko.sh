#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h:h}"
SUBMODULE_PATH="engine/firefox"
FIREFOX_URL="https://github.com/mozilla-firefox/firefox"

cd "$ROOT_DIR"

if [[ ! -f "engine/release.txt" ]]; then
	echo "Cannot get Firefox release tag: Missing engine/release.txt."
	exit 1
fi

RELEASE_TAG="$(tr -d '\000\r' < "engine/release.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [[ -z "$RELEASE_TAG" ]]; then
	echo "Cannot get Firefox release tag: engine/release.txt is empty."
	exit 1
fi

if ! git submodule status -- "$SUBMODULE_PATH" >/dev/null 2>&1; then
	echo "Missing submodule $SUBMODULE_PATH. Add it first, then run this script."
	exit 1
fi

if ! git ls-remote --exit-code --tags "$FIREFOX_URL" "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
	echo "Release tag $RELEASE_TAG does not exist in $FIREFOX_URL."
	exit 1
fi

TAG_REF="refs/tags/$RELEASE_TAG"

echo "Updating existing submodule at $SUBMODULE_PATH"
git submodule set-url -- "$SUBMODULE_PATH" "$FIREFOX_URL"
git submodule sync -- "$SUBMODULE_PATH"

# gecko-dev 即使 --depth 1 也有数 GB，GitHub 到 runner 的链路偶尔会
# 在中途被重置（curl 56 / early EOF / invalid index-pack），而
# `git submodule update --init` 不会自己重试，一次断连就要重跑整个
# 五小时的 job。这里最多试 4 次，失败后删掉半成品再重来。
clone_attempt=1
max_attempts=4
until git submodule update --init --depth 1 -- "$SUBMODULE_PATH"; do
	if (( clone_attempt >= max_attempts )); then
		echo "Failed to clone $SUBMODULE_PATH after $max_attempts attempts."
		exit 1
	fi
	echo "Clone attempt $clone_attempt failed; retrying ($((clone_attempt + 1))/$max_attempts)..."
	rm -rf "$SUBMODULE_PATH"
	rm -rf ".git/modules/$SUBMODULE_PATH"
	sleep $((clone_attempt * 15))
	clone_attempt=$((clone_attempt + 1))
done

echo "Fetching and checking out tag $RELEASE_TAG..."
fetch_attempt=1
until git -C "$SUBMODULE_PATH" fetch --depth 1 origin tag "$RELEASE_TAG"; do
	if (( fetch_attempt >= max_attempts )); then
		echo "Failed to fetch $RELEASE_TAG after $max_attempts attempts."
		exit 1
	fi
	echo "Fetch attempt $fetch_attempt failed; retrying ($((fetch_attempt + 1))/$max_attempts)..."
	sleep $((fetch_attempt * 15))
	fetch_attempt=$((fetch_attempt + 1))
done
git -C "$SUBMODULE_PATH" checkout --detach "$TAG_REF^{commit}"

EXPECTED_COMMIT="$(git -C "$SUBMODULE_PATH" rev-parse "$TAG_REF^{commit}")"
HEAD_COMMIT="$(git -C "$SUBMODULE_PATH" rev-parse HEAD)"

if [[ "$HEAD_COMMIT" != "$EXPECTED_COMMIT" ]]; then
	echo "Failed to checkout the expected commit for $RELEASE_TAG."
	echo "Expected: $EXPECTED_COMMIT"
	echo "Actual:   $HEAD_COMMIT"
	exit 1
fi
