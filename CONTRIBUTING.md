# Contributing to Ossuno

感谢你愿意改进 Ossuno。先为行为变化创建 Issue，说明用户场景、预期结果和安全边界；小型修复可以直接提交 Pull Request。

## Local setup

需要 Apple Silicon Mac、macOS 15 或更高版本，以及当前稳定版 Xcode。依赖由仓库中的 `Package.resolved` 固定。

```bash
git clone git@github.com:ihopefulChina/Ossuno.git
cd Ossuno
xcodebuild -resolvePackageDependencies \
  -project Ossuno.xcodeproj \
  -scheme Ossuno \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates
```

## Before opening a pull request

```bash
REAL_OSS_SMOKE=0 xcodebuild \
  -project Ossuno.xcodeproj \
  -scheme Ossuno \
  -destination 'platform=macOS,arch=arm64' \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  test

(cd Tools/ossuno-mcp && swift test --disable-sandbox -Xswiftc -warnings-as-errors)

scripts/validate-website.sh
bash -n scripts/*.sh
zsh -n scripts/*.sh
plutil -lint Info.plist Ossuno/PrivacyInfo.xcprivacy
```

不要把真实 OSS 凭证交给测试或 CI。只有显式设置 `REAL_OSS_SMOKE=1` 时，真实 OSS 冒烟测试才会运行；公开 CI 永远不设置该值。

## Change guidelines

- Bug 修复和新行为先写能失败的测试，再实现最小改动。
- 账号、Bucket、对象键、本地路径、URL、请求 ID 与凭证都属于敏感上下文；日志、截图、Fixture 和诊断信息必须使用虚拟数据。
- 文件操作必须保留冲突检查、路径越界防护和不完整列表保护。
- 保持原生 macOS 交互、键盘可达性、清晰焦点和 Reduce Motion 支持。
- 不修改 `Package.resolved`，除非 Pull Request 的目的就是升级依赖。

## Releases

版本号、构建号、发布说明、README、网站、DMG 与 appcast 必须保持一致。发布产物只由维护者通过仓库脚本生成；Pull Request 不应提交私钥、凭证或临时构建产物。

- 公开图标和截图更新时使用新的缓存友好文件名，同步 README、所有网站页面、favicon 和 Web App Manifest；截图只能使用虚拟测试账号与脱敏数据。
- Bundle ID 迁移必须附带偏好与钥匙串兼容验证、手动升级说明和 Sparkle 信息更新标记。Sparkle 签名密钥的 `sparkle_account` 不是 Bundle ID，身份迁移时不应随之更改。
