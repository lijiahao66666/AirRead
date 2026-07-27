#!/usr/bin/env bash
set -euo pipefail

release_directory="${1:?请传入解压后的 dist 目录}"
live_directory="${2:-/www/wwwroot/read.air-inc.top}"
parent_directory="$(dirname "$live_directory")"
release_id="$(date +%Y%m%d%H%M%S)-$$"
stage_directory="$parent_directory/.airread-stage-$release_id"
backup_directory="$parent_directory/.airread-backup-$release_id"

for required_file in index.html manifest.webmanifest sw.js; do
  if [[ ! -f "$release_directory/$required_file" ]]; then
    echo "发布包不完整，缺少 $required_file。" >&2
    exit 1
  fi
done

if [[ ! -d "$live_directory" ]]; then
  echo "线上站点目录不存在：$live_directory" >&2
  exit 1
fi

if ! command -v rsync >/dev/null; then
  echo "服务器未安装 rsync，无法安全发布。" >&2
  exit 1
fi

owner_group="$(stat -c '%u:%g' "$live_directory")"

cleanup_stage() {
  if [[ -d "$stage_directory" ]]; then
    rm -rf "$stage_directory"
  fi
}
trap cleanup_stage EXIT

mkdir -p "$stage_directory"
rsync -a --delete --exclude='.DS_Store' "$release_directory/" "$stage_directory/"
chown -R "$owner_group" "$stage_directory"

mv "$live_directory" "$backup_directory"
if ! mv "$stage_directory" "$live_directory"; then
  mv "$backup_directory" "$live_directory" || true
  echo "新版本切换失败，已尝试恢复原站点。" >&2
  exit 1
fi

trap - EXIT

printf 'AirRead 已发布。当前目录：%s\n回滚副本：%s\n' "$live_directory" "$backup_directory"
