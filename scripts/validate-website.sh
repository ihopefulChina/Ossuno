#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
site_root="$repo_root/website"
readme="$repo_root/README.md"
index="$site_root/index.html"
privacy="$site_root/privacy.html"
support="$site_root/support.html"
mcp="$site_root/mcp.html"
version_info="$("$repo_root/scripts/project-version.sh")"
version="${version_info%% *}"
arm64_build_number="${version_info##* }"
x86_64_build_number="$((arm64_build_number - 1))"
arm64_download_url="https://github.com/ihopefulChina/Ossuno/releases/download/v$version/Ossuno-$version-arm64.dmg"
x86_64_download_url="https://github.com/ihopefulChina/Ossuno/releases/download/v$version/Ossuno-$version-x86_64.dmg"
app_icon="Ossuno/Assets.xcassets/AppIcon.appiconset/Icon-v7-256.png"
website_icon="assets/ossuno-icon-v7.png"
website_favicon="assets/ossuno-favicon-v7.png"
public_visual_version="1.0.5"
browser_screenshot="assets/browser-$public_visual_version.png"
browser_dark_screenshot="assets/browser-dark-$public_visual_version.png"
account_screenshot="assets/account-$public_visual_version.png"
account_dark_screenshot="assets/account-dark-$public_visual_version.png"

required_files=(
  "$index"
  "$privacy"
  "$support"
  "$mcp"
  "$site_root/styles.css"
  "$site_root/download.js"
  "$site_root/site.webmanifest"
  "$site_root/sitemap.xml"
  "$site_root/robots.txt"
  "$site_root/.nojekyll"
  "$site_root/appcast.xml"
  "$site_root/$website_icon"
  "$site_root/$website_favicon"
  "$site_root/$browser_screenshot"
  "$site_root/$browser_dark_screenshot"
  "$site_root/$account_screenshot"
  "$site_root/$account_dark_screenshot"
  "$site_root/assets/author-blog.png"
  "$repo_root/$app_icon"
  "$repo_root/docs/browser-$public_visual_version.png"
  "$repo_root/docs/account-$public_visual_version.png"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing website file: ${file#"$repo_root/"}" >&2
    exit 1
  fi
done

python3 - "$site_root/appcast.xml" "$site_root/sitemap.xml" <<'PY'
from pathlib import Path
from xml.etree import ElementTree
import sys


for value in sys.argv[1:]:
    path = Path(value)
    try:
        ElementTree.parse(path)
    except ElementTree.ParseError as error:
        raise SystemExit(f"Invalid XML in {path}: {error}") from error
PY
python3 -m json.tool "$site_root/site.webmanifest" >/dev/null
if ! cmp -s "$repo_root/appcast.xml" "$site_root/appcast.xml"; then
  echo "Root and website appcasts differ." >&2
  exit 1
fi

for build_and_url in \
  "$x86_64_build_number|$x86_64_download_url" \
  "$arm64_build_number|$arm64_download_url"; do
  build_number="${build_and_url%%|*}"
  expected_url="${build_and_url#*|}"
  item_xpath="//*[local-name()='item' and *[local-name()='version' and text()='$build_number']]"
  item_count="$(xmllint --xpath "count($item_xpath)" "$repo_root/appcast.xml")"
  short_version="$(xmllint --xpath "string($item_xpath/*[local-name()='shortVersionString'])" "$repo_root/appcast.xml")"
  download_url="$(xmllint --xpath "string($item_xpath/*[local-name()='enclosure']/@url)" "$repo_root/appcast.xml")"
  informational_count="$(xmllint --xpath "count($item_xpath/*[local-name()='informationalUpdate']/*[local-name()='belowVersion' and text()='12'])" "$repo_root/appcast.xml")"
  if [[ "$item_count" != "1" || "$short_version" != "$version" || "$download_url" != "$expected_url" ]]; then
    echo "Appcast is missing the current $version build $build_number item or its download URL." >&2
    exit 1
  fi
  if [[ "$informational_count" != "1" ]]; then
    echo "Appcast build $build_number must be informational for legacy hosts below build 12." >&2
    exit 1
  fi
done

required_html=(
  'lang="zh-CN"'
  '<meta name="description"'
  '<link rel="canonical" href="https://ihopefulchina.github.io/Ossuno/"'
  '<meta property="og:title"'
  '<link rel="manifest" href="site.webmanifest"'
  '<a class="skip-link" href="#main">'
  '<main id="main">'
  'aria-label="主导航"'
  'id="mcp"'
  'id="features"'
  'id="security"'
  'id="start"'
  'id="faq"'
  '<details>'
  'alt="在 Ossuno 中浏览虚拟测试 Bucket 的对象"'
  'alt="在 Ossuno 中添加虚拟测试账号"'
  "href=\"$website_favicon\""
  "href=\"$website_icon\""
  "src=\"$browser_screenshot\""
  "srcset=\"$browser_dark_screenshot\""
  "src=\"$account_screenshot\""
  "srcset=\"$account_dark_screenshot\""
  "$arm64_download_url"
  "$x86_64_download_url"
  'src="download.js" defer'
  'data-auto-download'
  'data-download-url-arm64'
  'data-download-url-intel'
  'href="privacy.html"'
  'href="support.html"'
  'href="mcp.html"'
  'npx ossuno-mcp install'
  'macOS 15'
  'Apple Silicon'
  'Intel'
  'MIT License'
)

for pattern in "${required_html[@]}"; do
  if ! grep -Fq -- "$pattern" "$index"; then
    echo "Missing required HTML marker: $pattern" >&2
    exit 1
  fi
done

for page_and_canonical in \
  "$privacy|https://ihopefulchina.github.io/Ossuno/privacy.html" \
  "$support|https://ihopefulchina.github.io/Ossuno/support.html" \
  "$mcp|https://ihopefulchina.github.io/Ossuno/mcp.html"; do
  page="${page_and_canonical%%|*}"
  canonical="${page_and_canonical#*|}"
  for pattern in \
    "<link rel=\"canonical\" href=\"$canonical\"" \
    '<a class="skip-link" href="#main">' \
    '<main id="main"' \
    "href=\"$website_favicon\"" \
    'href="index.html"' \
    'href="mcp.html"' \
    'href="privacy.html"' \
    'href="support.html"'; do
    if ! grep -Fq -- "$pattern" "$page"; then
      echo "Missing policy page marker in ${page#"$repo_root/"}: $pattern" >&2
      exit 1
    fi
  done
done

for marker in \
  "src=\"$app_icon\"" \
  "src=\"docs/browser-$public_visual_version.png\"" \
  "srcset=\"website/$browser_dark_screenshot\"" \
  "src=\"docs/account-$public_visual_version.png\"" \
  "srcset=\"website/$account_dark_screenshot\""; do
  if ! grep -Fq -- "$marker" "$readme"; then
    echo "README is missing current public visual: $marker" >&2
    exit 1
  fi
done

if ! grep -Fq -- "\"src\": \"$website_icon\"" "$site_root/site.webmanifest"; then
  echo "Web App Manifest is missing the current icon: $website_icon" >&2
  exit 1
fi

if grep -REn --include='*.html' --include='site.webmanifest' \
  'assets/(ossuno-(icon|favicon)|browser(-dark)?|account(-dark)?)\.png' "$site_root"; then
  echo "Website still references an unversioned public icon or screenshot." >&2
  exit 1
fi

if grep -Eini -- \
  'npm.{0,24}(尚未发布|未发布)|发布后.{0,24}(可用|可运行)|计划.{0,24}发布到 npm|正式发布前|not yet published|coming soon' \
  "$readme" "$repo_root/docs/mcp.md" "$site_root"/*.html; then
  echo "MCP documentation still contains pre-release transition copy." >&2
  exit 1
fi

previous_brand="$(printf '\154\165\155\145\156')"
if grep -RIni --include='*.html' -- "$previous_brand" "$site_root"; then
  echo "Website still contains the previous brand." >&2
  exit 1
fi

unexpected_versions="$(grep -RhoE --include='*.html' 'Ossuno [0-9]+\.[0-9]+\.[0-9]+' "$site_root" | grep -Fvx -- "Ossuno $version" || true)"
if [[ -n "$unexpected_versions" ]]; then
  echo "Website contains mismatched release versions:" >&2
  echo "$unexpected_versions" >&2
  exit 1
fi

for download_url in "$arm64_download_url" "$x86_64_download_url"; do
  if ! grep -Fq -- "$download_url" "$readme"; then
    echo "README is missing a website download URL for version $version: $download_url" >&2
    exit 1
  fi
done

unexpected_downloads="$(grep -RhoE --include='*.html' 'https://github\.com/ihopefulChina/Ossuno/releases/(latest/download|download/v[0-9.]+)/Ossuno-[0-9.]+-(arm64|x86_64)\.dmg' "$site_root" | grep -Fvx -- "$arm64_download_url" | grep -Fvx -- "$x86_64_download_url" || true)"
if [[ -n "$unexpected_downloads" ]]; then
  echo "Website contains mismatched download URLs:" >&2
  echo "$unexpected_downloads" >&2
  exit 1
fi

if grep -RhoE --include='*.html' 'https://github\.com/ihopefulChina/Ossuno/releases/(latest/download|download/v[0-9.]+)/Ossuno-[0-9.]+\.dmg' "$site_root" | grep -q .; then
  echo "Website still contains a legacy architecture-neutral DMG URL." >&2
  exit 1
fi

release_notes="$repo_root/docs/releases/$version.md"
if [[ ! -f "$release_notes" ]]; then
  echo "Missing release notes for version $version: ${release_notes#"$repo_root/"}" >&2
  exit 1
fi

if [[ "$version" == "1.0.5" ]]; then
  for migration_file in "$readme" "$release_notes" "$index" "$support"; do
    for migration_marker in 'studio.ossuno.oss' 'app.ihopeful.Ossuno' '1.0.4' '1.0.5' '手动'; do
      if ! grep -Fq -- "$migration_marker" "$migration_file"; then
        echo "Missing Bundle ID migration guidance in ${migration_file#"$repo_root/"}: $migration_marker" >&2
        exit 1
      fi
    done
  done
fi

for distribution_file in "$readme" "$release_notes" "$index" "$support"; do
  for distribution_marker in 'ad-hoc' '不是 Developer ID 签名' '未经 Apple 公证'; do
    if ! grep -Fq -- "$distribution_marker" "$distribution_file"; then
      echo "Missing distribution disclosure in ${distribution_file#"$repo_root/"}: $distribution_marker" >&2
      exit 1
    fi
  done
done

for opening_guide in "$readme" "$release_notes" "$support"; do
  for opening_marker in '系统设置 → 隐私与安全' '仍要打开'; do
    if ! grep -Fq -- "$opening_marker" "$opening_guide"; then
      echo "Missing first-open guidance in ${opening_guide#"$repo_root/"}: $opening_marker" >&2
      exit 1
    fi
  done
done

if grep -Eini -- \
  '使用 Developer ID 签名并通过 Apple 公证|已通过 Apple 公证|已经 Apple 公证|可由 macOS Gatekeeper 正常验证' \
  "$readme" "$release_notes" "$site_root"/*.html; then
  echo "Distribution copy incorrectly claims Developer ID signing or Apple notarization." >&2
  exit 1
fi

if grep -En '(fonts\.(googleapis|gstatic)\.com|TODO|Lorem ipsum|href="/|src="/)' "$site_root"/*.html "$site_root"/*.css; then
  echo "Website contains a forbidden dependency, placeholder, or root-relative URL." >&2
  exit 1
fi

if ! grep -Fq -- '@media (prefers-reduced-motion: reduce)' "$site_root/styles.css"; then
  echo "Missing reduced-motion support." >&2
  exit 1
fi

python3 - "$index" "$privacy" "$support" "$mcp" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys


class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.errors = []
        self.ids = set()
        self.links = []
        self.images = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "id" in values:
            if values["id"] in self.ids:
                self.errors.append(f"duplicate id: {values['id']}")
            self.ids.add(values["id"])
        if tag == "a" and "href" in values:
            self.links.append(values["href"])
        if tag == "script" and values.get("type") != "application/ld+json":
            if values.get("src") != "download.js" or "defer" not in values:
                self.errors.append("only the deferred local architecture detector is allowed")
        if tag == "img":
            self.images.append(values)
            for required in ("src", "alt", "width", "height"):
                if required not in values:
                    self.errors.append(f"img missing {required}: {values.get('src', '<unknown>')}")


totals = [0, 0, 0]
for raw_path in sys.argv[1:]:
    page = Path(raw_path)
    parser = SiteParser()
    source = page.read_text(encoding="utf-8")
    parser.feed(source)

    if page.name == "index.html" and source.find('id="mcp"') > source.find('id="features"'):
        parser.errors.append("ossuno-mcp must appear before the App feature chapters")

    for href in parser.links:
        if href.startswith("#") and href[1:] not in parser.ids:
            parser.errors.append(f"broken anchor: {href}")

    for image in parser.images:
        source = image["src"]
        if source.startswith(("http://", "https://", "data:")):
            parser.errors.append(f"image must be local: {source}")
        elif not (page.parent / source).is_file():
            parser.errors.append(f"missing image target: {source}")

    if parser.errors:
        raise SystemExit(f"{page.name}:\n" + "\n".join(parser.errors))
    totals[0] += len(parser.links)
    totals[1] += len(parser.images)
    totals[2] += len(parser.ids)

print(f"Validated {totals[0]} links, {totals[1]} images, and {totals[2]} unique IDs across {len(sys.argv) - 1} pages.")
PY

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required to validate download architecture detection." >&2
  exit 1
fi

node - "$site_root/download.js" <<'JS'
const assert = require("node:assert/strict");
const download = require(process.argv[2]);

class FakeClassList {
  constructor(initial) {
    this.values = new Set(initial || []);
  }

  toggle(value, enabled) {
    if (enabled) this.values.add(value);
    else this.values.delete(value);
  }

  contains(value) {
    return this.values.has(value);
  }
}

class FakeElement {
  constructor({ dataset = {}, href = "", classes = [] } = {}) {
    this.dataset = dataset;
    this.href = href;
    this.classList = new FakeClassList(classes);
    this.attributes = new Map();
    this.listeners = new Map();
    this.mark = { textContent: "" };
    this.textContent = "";
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  setAttribute(name, value) {
    this.attributes.set(name, value);
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  querySelector(selector) {
    return selector === ".download-choice-mark" ? this.mark : null;
  }
}

(async () => {
  assert.equal(download.normalizeArchitecture("arm", "64"), "arm64");
  assert.equal(download.normalizeArchitecture("aarch64", ""), "arm64");
  assert.equal(download.normalizeArchitecture("x86", "64"), "x86_64");
  assert.equal(download.normalizeArchitecture("x86", "32"), null);

  const armResult = await download.detectArchitecture({
    userAgentData: {
      platform: "macOS",
      getHighEntropyValues: async () => ({ architecture: "arm", bitness: "64" }),
    },
  });
  assert.deepEqual(armResult, { kind: "detected", architecture: "arm64" });

  const intelResult = await download.detectArchitecture({
    userAgentData: {
      platform: "macOS",
      getHighEntropyValues: async () => ({ architecture: "x86", bitness: "64" }),
    },
  });
  assert.deepEqual(intelResult, { kind: "detected", architecture: "x86_64" });

  const safariResult = await download.detectArchitecture({
    platform: "MacIntel",
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
  });
  assert.deepEqual(safariResult, { kind: "ambiguous", architecture: null });

  let resolveHints;
  const hints = new Promise((resolve) => { resolveHints = resolve; });
  const armURL = "https://example.test/Ossuno-1.0.0-arm64.dmg";
  const intelURL = "https://example.test/Ossuno-1.0.0-x86_64.dmg";
  const automaticLink = new FakeElement({
    dataset: {
      labelArm64: "下载 Apple Silicon 版",
      labelX86_64: "下载 Intel 版",
    },
    href: armURL,
  });
  const status = new FakeElement({ dataset: { state: "checking" } });
  const statusCopy = { textContent: "" };
  const fakeDocument = {
    documentElement: {
      dataset: {
        downloadUrlArm64: armURL,
        downloadUrlIntel: intelURL,
      },
    },
    querySelectorAll(selector) {
      if (selector === "[data-download-choice]") return [];
      if (selector === "[data-auto-download]") return [automaticLink];
      return [];
    },
    querySelector(selector) {
      if (selector === "[data-download-status]") return status;
      if (selector === "[data-download-status-copy]") return statusCopy;
      return null;
    },
  };
  const navigations = [];
  const controller = download.enhanceDownloads(
    fakeDocument,
    {
      userAgentData: {
        platform: "macOS",
        getHighEntropyValues: () => hints,
      },
    },
    {
      detectionTimeoutMilliseconds: 5000,
      navigate: (url) => navigations.push(url),
    }
  );

  let prevented = false;
  const clickCompletion = automaticLink.listeners.get("click")({
    preventDefault() { prevented = true; },
  });
  assert.equal(prevented, true, "an early click must wait for architecture detection");
  assert.deepEqual(navigations, [], "an early click must not navigate to the arm64 fallback");

  resolveHints({ architecture: "x86", bitness: "64" });
  await controller.detectionPromise;
  await clickCompletion;

  assert.equal(automaticLink.href, intelURL);
  assert.equal(automaticLink.textContent, "下载 Intel 版");
  assert.deepEqual(navigations, [intelURL]);

  console.log("Download architecture detection tests passed.");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
JS

echo "Website validation passed."
