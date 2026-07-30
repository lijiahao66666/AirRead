#!/usr/bin/env bash
set -euo pipefail

release_directory="${1:?请传入解压后的 dist 目录}"
release_root="$(dirname "$release_directory")"
live_directory="${2:-/www/wwwroot/read.air-inc.top}"
parent_directory="$(dirname "$live_directory")"
release_id="$(date +%Y%m%d%H%M%S)-$$"
stage_directory="$parent_directory/.airread-stage-$release_id"
backup_directory="$parent_directory/.airread-backup-$release_id"
vhost_configuration="${AIRREAD_VHOST_CONFIGURATION:-/www/server/panel/vhost/nginx/html_read.air-inc.top.conf}"
proxy_configuration="$(dirname "$vhost_configuration")/airread-book-source-proxy.conf"
proxy_source="$release_root/server/book-source-proxy.conf"

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

if [[ ! -f "$vhost_configuration" || ! -f "$proxy_source" ]]; then
  echo '缺少 AirRead 书源代理配置，无法安全发布。' >&2
  exit 1
fi

if ! command -v rsync >/dev/null; then
  echo "服务器未安装 rsync，无法安全发布。" >&2
  exit 1
fi

owner_group="$(stat -c '%u:%g' "$live_directory")"
vhost_backup="$(mktemp "${TMPDIR:-/tmp}/airread-vhost.XXXXXX")"
proxy_backup="$(mktemp "${TMPDIR:-/tmp}/airread-proxy.XXXXXX")"
proxy_existed=false

cp "$vhost_configuration" "$vhost_backup"
if [[ -f "$proxy_configuration" ]]; then
  cp "$proxy_configuration" "$proxy_backup"
  proxy_existed=true
fi

cleanup_stage() {
  if [[ -d "$stage_directory" ]]; then
    rm -rf "$stage_directory"
  fi
  rm -f "$vhost_backup" "$proxy_backup"
}
trap cleanup_stage EXIT

install -m 0644 "$proxy_source" "$proxy_configuration"
if ! grep -Fqx "    include $proxy_configuration;" "$vhost_configuration"; then
  vhost_candidate="$(mktemp "${TMPDIR:-/tmp}/airread-vhost-candidate.XXXXXX")"
  if ! awk -v include_line="    include $proxy_configuration;" '
    /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/ && !inserted { print include_line; inserted = 1 }
    { print }
    END { if (!inserted) exit 1 }
  ' "$vhost_configuration" > "$vhost_candidate"; then
    rm -f "$vhost_candidate"
    echo '未能定位 AirRead 站点的默认路由，未修改 Nginx 配置。' >&2
    exit 1
  fi
  mv "$vhost_candidate" "$vhost_configuration"
fi

if ! nginx -t; then
  cp "$vhost_backup" "$vhost_configuration"
  if [[ "$proxy_existed" == true ]]; then
    cp "$proxy_backup" "$proxy_configuration"
  else
    rm -f "$proxy_configuration"
  fi
  nginx -t >&2 || true
  echo '书源代理配置校验失败，已恢复原有 Nginx 配置。' >&2
  exit 1
fi
nginx -s reload

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
rm -f "$vhost_backup" "$proxy_backup"

printf 'AirRead 已发布。当前目录：%s\n回滚副本：%s\n' "$live_directory" "$backup_directory"
