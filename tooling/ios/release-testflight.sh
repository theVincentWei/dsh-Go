#!/usr/bin/env bash
# TestFlight 发版:本地基线 → 干净快照 → archive → 导出 ipa → 上传 App Store Connect。
#
# 用法:
#   tooling/ios/release-testflight.sh --build-name 1.0.18 [选项]
# 选项:
#   --build-name X.Y.Z   必填,版本名(+1 占位不参与,见 docs/release.md「发版步骤」)
#   --build-number N     缺省=构建分钟(与 Android versionCode 同一条序列,见「构建号」)
#   --ref <git-ref>      出包基线,默认本地 main 的 HEAD 提交
#   --no-upload          只出 ipa,不上传
#   --out-dir <dir>      产物目录,默认 ~/Library/Caches/dsh-ios-release
#   --team <id>          ASC team,默认 J6576Q7A3U(银阔);可用 ASC_TEAM 覆盖
#   --key-id <id>        ASC API key ID,默认读 ASC_KEY_ID
#   --api-issuer <uuid>  ASC API issuer,默认读 ASC_ISSUER_ID
#
# 基线规则:发版永远出某个「已提交状态」,默认=本地 main 最新提交。主工作树带未提交
# 改动也照常发——脚本用 `git archive` 导出干净快照构建,任何未提交内容不进包。
#
# ASC API key:.p8 放 ~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8,
# key 角色需 Admin(Developer 角色报 Cloud signing permission error)。
#
# 环境硬要求(2026-11-16 首发跑通,勿改):
# - 真 HOME:fakehome 让 xcodebuild 找不到默认钥匙串(证书错误 -25307)。
# - DerivedData 必须在工作区外:DSH File Provider 给 workspace 内文件盖 fpfs#P
#   元数据,codesign 报 resource fork detritus。缺省全新解析;SPM 解析失败时可
#   DD=<现有缓存目录> 复用。
# - 提权跑:写 ~/Library/Caches、flutter bin/cache、调真钥匙串。
# - 纯远程包(无内置引擎):不要先跑 tooling/ios/prepare-engine.sh;要带引擎再说。
# - 上传后 ASC 处理约 20-40 分钟,邮件与 ASC 构建列表可查处理状态。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
build_name='' build_number='' ref='main' upload=1
out_dir="$HOME/Library/Caches/dsh-ios-release"
team="${ASC_TEAM:-J6576Q7A3U}"
key_id="${ASC_KEY_ID:-}" issuer="${ASC_ISSUER_ID:-}"
dd="${DD:-$HOME/Library/Caches/dsh-ios-release-dd}"

while [ $# -gt 0 ]; do
  case "$1" in
    --build-name) build_name=${2:?--build-name 需要值}; shift 2 ;;
    --build-name=*) build_name=${1#*=}; shift ;;
    --build-number) build_number=${2:?--build-number 需要值}; shift 2 ;;
    --build-number=*) build_number=${1#*=}; shift ;;
    --ref) ref=${2:?--ref 需要值}; shift 2 ;;
    --ref=*) ref=${1#*=}; shift ;;
    --no-upload) upload=0; shift ;;
    --out-dir) out_dir=${2:?--out-dir 需要值}; shift 2 ;;
    --out-dir=*) out_dir=${1#*=}; shift ;;
    --team) team=${2:?--team 需要值}; shift 2 ;;
    --team=*) team=${1#*=}; shift ;;
    --key-id) key_id=${2:?--key-id 需要值}; shift 2 ;;
    --key-id=*) key_id=${1#*=}; shift ;;
    --api-issuer) issuer=${2:?--api-issuer 需要值}; shift 2 ;;
    --api-issuer=*) issuer=${1#*=}; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
[ -n "$build_name" ] || { echo "用法: release-testflight.sh --build-name X.Y.Z [--build-number N] [--ref main] [--no-upload]" >&2; exit 2; }
if [ "$upload" -eq 1 ] && { [ -z "$key_id" ] || [ -z "$issuer" ]; }; then
  echo "上传需要 ASC 认证:传 --key-id/--api-issuer 或设 ASC_KEY_ID/ASC_ISSUER_ID" >&2
  exit 2
fi

commit="$(git -C "$ROOT" rev-parse --verify "$ref^{commit}")"
echo "== 基线 $ref @ $commit(git archive 干净快照,未提交改动不进包) =="

# 构建分钟(UTC+8),与 Android versionCode 同一条序列;date -u -v+8H 即北京时间
if [ -z "$build_number" ]; then
  read -r ty tmo td th tmi < <(date -u -v+8H '+%Y %m %d %H %M')
  build_number=$(( (10#$ty - 2026) * 100000000 + 10#$tmo * 1000000 + 10#$td * 10000 + 10#$th * 100 + 10#$tmi ))
fi

mkdir -p "$out_dir"
snap="$out_dir/snapshot"
rm -rf "$snap" "$out_dir/archive-$build_name.log"
mkdir -p "$snap"
git -C "$ROOT" archive "$commit" | tar -x -C "$snap"

echo "== [1/4] flutter config-only $build_name($build_number) =="
(cd "$snap/app" && flutter build ios --release --no-codesign --config-only \
  --build-name "$build_name" --build-number "$build_number")

echo "== [2/4] xcodebuild archive =="
archive="$out_dir/wanqi-$build_name.xcarchive"
rm -rf "$archive"
mkdir -p "$dd"
xcodebuild -workspace "$snap/app/ios/Runner.xcworkspace" -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8" \
  -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
  -derivedDataPath "$dd" archive > "$out_dir/archive-$build_name.log" 2>&1
grep -q '\*\* ARCHIVE SUCCEEDED \*\*' "$out_dir/archive-$build_name.log" || {
  echo "archive 失败,日志: $out_dir/archive-$build_name.log"; grep -E ' error:|errSec|\*\* ARCHIVE' "$out_dir/archive-$build_name.log" | sort -u | head -8; exit 1
}
app_id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$archive/Info.plist")"
echo "✓ archive: $app_id $build_name($build_number) team $team"

echo "== [3/4] 导出 ipa =="
cat > "$out_dir/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
EOF
ipa_dir="$out_dir/export-$build_name"
rm -rf "$ipa_dir"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out_dir/exportOptions.plist" \
  -exportPath "$ipa_dir" -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8" \
  -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer" > /dev/null
ipa="$(find "$ipa_dir" -name '*.ipa' -maxdepth 1 | head -1)"
[ -n "$ipa" ] || { echo "导出目录没有 ipa: $ipa_dir" >&2; exit 1; }
echo "✓ ipa: $ipa ($(du -h "$ipa" | cut -f1))"

if [ "$upload" -eq 1 ]; then
  echo "== [4/4] altool 上传 =="
  xcrun altool --upload-app --type ios --file "$ipa" --apiKey "$key_id" --apiIssuer "$issuer"
  echo "✓ 已上传,ASC 处理约 20-40 分钟。"
else
  echo "== [4/4] 跳过上传(--no-upload) =="
fi
