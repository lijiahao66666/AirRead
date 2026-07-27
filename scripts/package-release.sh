#!/usr/bin/env bash
set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_dir"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "发布包只能从已提交的工作区生成。请先提交并推送当前改动。" >&2
  exit 1
fi

npm run build

for required_file in dist/index.html dist/manifest.webmanifest dist/sw.js; do
  if [[ ! -f "$required_file" ]]; then
    echo "构建产物不完整，缺少 $required_file。" >&2
    exit 1
  fi
done

revision="$(git rev-parse --short HEAD)"
created_at="$(date +%Y%m%d%H%M%S)"
bundle_name="airread-release-${created_at}-${revision}"
release_directory="${AIRREAD_RELEASE_DIR:-$repository_dir/releases}"
archive_path="$release_directory/${bundle_name}.tar.gz"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/airread-release.XXXXXX")"

cleanup() {
  rm -rf "$staging_directory"
}
trap cleanup EXIT

mkdir -p "$release_directory" "$staging_directory/$bundle_name"
cp -R dist "$staging_directory/$bundle_name/dist"
cp scripts/deploy-release.sh "$staging_directory/$bundle_name/deploy-release.sh"
printf '{"application":"AirRead","revision":"%s","createdAt":"%s"}\n' \
  "$revision" "$created_at" > "$staging_directory/$bundle_name/release.json"

if tar --no-xattrs --no-mac-metadata -czf "$archive_path" -C "$staging_directory" "$bundle_name"; then
  :
else
  echo "当前 tar 不支持 macOS 元数据过滤，已使用兼容模式重新打包。" >&2
  COPYFILE_DISABLE=1 tar -czf "$archive_path" -C "$staging_directory" "$bundle_name"
fi

if ! tar -tzf "$archive_path" | grep -qx "$bundle_name/dist/index.html"; then
  echo "发布包校验失败：未找到 dist/index.html。" >&2
  exit 1
fi

checksum="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$archive_path")" > "$archive_path.sha256"

cat <<EOF

发布包已生成：$archive_path
SHA-256：$checksum

在腾讯云 Lighthouse 文件管理中上传到：/root/$(basename "$archive_path")
随后在「执行命令」粘贴并运行：

ARCHIVE=/root/$(basename "$archive_path")
WORKDIR=\$(mktemp -d)
trap 'rm -rf "\$WORKDIR"' EXIT
tar -xzf "\$ARCHIVE" -C "\$WORKDIR"
bash "\$WORKDIR/$bundle_name/deploy-release.sh" "\$WORKDIR/$bundle_name/dist"
rm -f "\$ARCHIVE"
EOF
