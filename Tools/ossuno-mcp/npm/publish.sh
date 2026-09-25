#!/bin/bash
# 发布 ossuno-mcp 到 npm（三个包：两个平台二进制 + 主包）。
# 版本唯一来源：Sources/ossuno-mcp/OssunoMCPVersion.swift。
# 用法：在 Terminal.app 中运行 ./npm/publish.sh [version]
# 可选 version 只用于防止误发，必须与源码版本完全一致。
# 前置：已 npm login；Xcode 命令行工具可用。
set -euo pipefail

cd "$(dirname "$0")"
NPM_DIR="$PWD"
SWIFT_DIR="$(cd .. && pwd)"
VERSION_FILE="$SWIFT_DIR/Sources/ossuno-mcp/OssunoMCPVersion.swift"
VERSION="$(sed -nE 's/^[[:space:]]*static let current = "([^"]+)".*/\1/p' "$VERSION_FILE")"

if [ -z "$VERSION" ]; then
  echo "错误：无法从 $VERSION_FILE 读取版本号。" >&2; exit 1
fi
if [ "$#" -gt 1 ]; then
  echo "用法：publish.sh [version]" >&2; exit 64
fi
if [ "$#" -eq 1 ] && [ "$1" != "$VERSION" ]; then
  echo "错误：参数版本 $1 与源码唯一版本 $VERSION 不一致。请先修改 OssunoMCPVersion.swift。" >&2
  exit 1
fi

if ! command -v npm >/dev/null; then
  echo "错误：未找到 npm。" >&2; exit 1
fi
copy_release_binary() {
  local arch="$1"
  local dest="$2"
  swift build --disable-sandbox -c release --arch "$arch"
  local binary
  binary="$(swift build --disable-sandbox -c release --arch "$arch" --show-bin-path)/ossuno-mcp"
  if [ ! -f "$binary" ]; then
    echo "错误：未找到 $arch 发布二进制：$binary" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$binary" "$dest"
}

echo "==> 构建 arm64..."
cd "$SWIFT_DIR"
swift package clean
copy_release_binary arm64 "$NPM_DIR/ossuno-mcp-darwin-arm64/bin/ossuno-mcp"

echo "==> 交叉编译 x86_64..."
copy_release_binary x86_64 "$NPM_DIR/ossuno-mcp-darwin-x64/bin/ossuno-mcp"

echo "==> 同步版本号到 $VERSION ..."
cd "$NPM_DIR"
node -e '
const fs = require("fs");
const version = process.argv[1];
for (const name of ["ossuno-mcp-darwin-arm64", "ossuno-mcp-darwin-x64"]) {
  const file = `${name}/package.json`;
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  json.version = version;
  fs.writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
}
const main = JSON.parse(fs.readFileSync("ossuno-mcp/package.json", "utf8"));
main.version = version;
for (const key of Object.keys(main.optionalDependencies)) {
  main.optionalDependencies[key] = version;
}
fs.writeFileSync("ossuno-mcp/package.json", JSON.stringify(main, null, 2) + "\n");
' "$VERSION"

echo "==> 校验源码、二进制和 npm 包版本..."
ARM_BINARY="$NPM_DIR/ossuno-mcp-darwin-arm64/bin/ossuno-mcp"
X64_BINARY="$NPM_DIR/ossuno-mcp-darwin-x64/bin/ossuno-mcp"
lipo "$ARM_BINARY" -verify_arch arm64
lipo "$X64_BINARY" -verify_arch x86_64
ARM_VERSION="$(/usr/bin/arch -arm64 "$ARM_BINARY" --version)"
EXPECTED="ossuno-mcp $VERSION"
if [ "$ARM_VERSION" != "$EXPECTED" ]; then
  echo "错误：二进制版本不一致。期望 '$EXPECTED'，arm64='$ARM_VERSION'。" >&2
  exit 1
fi
if X64_VERSION="$(/usr/bin/arch -x86_64 "$X64_BINARY" --version 2>/dev/null)" && [ -n "$X64_VERSION" ]; then
  if [ "$X64_VERSION" != "$EXPECTED" ]; then
    echo "错误：二进制版本不一致。期望 '$EXPECTED'，x64='$X64_VERSION'。" >&2
    exit 1
  fi
else
  # Apple Silicon without Rosetta cannot execute the x86_64 binary.
  # Swift may store the banner as one C string or as adjacent strings
  # ("ossuno-mcp" then the version). A lone version number is not enough.
  if ! strings -a "$X64_BINARY" | awk -v version="$VERSION" '
    $0 == "ossuno-mcp " version { found = 1 }
    (prev == "ossuno-mcp" || prev == "ossuno-mcp ") && $0 == version { found = 1 }
    { prev = $0 }
    END { exit found ? 0 : 1 }
  '; then
    echo "错误：x86_64 二进制缺少版本标识 'ossuno-mcp $VERSION'，且本机无法运行该架构。" >&2
    exit 1
  fi
fi
node -e '
const fs = require("fs");
const expected = process.argv[1];
const arm = JSON.parse(fs.readFileSync("ossuno-mcp-darwin-arm64/package.json", "utf8"));
const x64 = JSON.parse(fs.readFileSync("ossuno-mcp-darwin-x64/package.json", "utf8"));
const main = JSON.parse(fs.readFileSync("ossuno-mcp/package.json", "utf8"));
const actual = [arm.version, x64.version, main.version, ...Object.values(main.optionalDependencies)];
if (actual.some(version => version !== expected)) {
  console.error(`错误：npm 包版本不一致。期望 ${expected}，实际 ${actual.join(", ")}`);
  process.exit(1);
}
' "$VERSION"

echo "==> 校验 npm 包内容..."
(cd ossuno-mcp-darwin-arm64 && npm pack --dry-run >/dev/null)
(cd ossuno-mcp-darwin-x64 && npm pack --dry-run >/dev/null)
(cd ossuno-mcp && npm pack --dry-run >/dev/null)

if [ "$(npm whoami 2>/dev/null || true)" = "" ]; then
  echo "错误：未登录 npm，请先运行 npm login。" >&2; exit 1
fi

echo "==> 发布平台包（arm64 / x64）..."
(cd ossuno-mcp-darwin-arm64 && npm publish --access public)
(cd ossuno-mcp-darwin-x64 && npm publish --access public)

echo "==> 发布主包 ossuno-mcp..."
(cd ossuno-mcp && npm publish --access public)

echo
echo "完成：ossuno-mcp@$VERSION 已发布。"
echo "提醒：同步提交 npm/ 下 package.json 的版本号变更并推送仓库。"
