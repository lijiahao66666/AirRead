# AirRead 发布说明

AirRead 是纯静态 PWA。发布时只上传本机构建好的 `dist/`，不在腾讯云服务器拉取 GitHub，也不在服务器构建 Node 项目。这样避开 GitHub 网络抖动，发布只需上传一个约数百 KB 的压缩包并执行一次原子切换。

生产站点：`https://read.air-inc.top`  
腾讯云 Lighthouse 实例：`lhins-9bk8aogy`  
线上静态目录：`/www/wwwroot/read.air-inc.top`

## 标准发布

1. 完成功能后先验证、提交和推送。发布包必须从干净的 Git 工作区生成，保证线上版本可以按提交准确追溯。

   ```bash
   npm test -- --run
   git add <changed-files>
   git commit -m "..."
   git push origin main
   npm run release:package
   ```

2. 最后一条命令会构建应用，并在 `releases/` 生成单个 `airread-release-<时间>-<提交>.tar.gz`。它还会在终端输出上传路径和完整的服务器执行命令。

3. 在 Lighthouse 的「文件管理」上传这个 `.tar.gz` 到 `/root/`，然后在「执行命令」原样粘贴并运行终端输出的命令。该命令会校验包内容、复制到临时目录、继承当前站点的 UID/GID，并通过目录改名原子切换站点。

4. 发布后验证：

   ```bash
   curl -fsSI https://read.air-inc.top
   curl -fsS https://read.air-inc.top/manifest.webmanifest
   ```

发布脚本会保留一个 `/www/wwwroot/.airread-backup-<时间>-<进程号>` 回滚副本。不要在刚发布后立即删除它。

## 回滚

先在腾讯云「执行命令」查看备份，并确认需要回滚的目录：

```bash
ls -dt /www/wwwroot/.airread-backup-*
```

将下面命令中的 `BACKUP` 改成确认过的完整目录后执行。失败版本会被保留，便于后续排查：

```bash
LIVE=/www/wwwroot/read.air-inc.top
BACKUP=/www/wwwroot/.airread-backup-<确认的版本>
FAILED=/www/wwwroot/.airread-failed-$(date +%Y%m%d%H%M%S)
mv "$LIVE" "$FAILED"
mv "$BACKUP" "$LIVE"
```

## 后续提速

目前实例未配置可用的 SSH 密钥，因此最稳定的方式是 Lighthouse 文件管理上传。若后续在实例中配置 SSH 公钥，就可以把第 3 步替换为本机 `scp`/`ssh` 自动上传和执行，进一步省去控制台操作；不再尝试让服务器从 GitHub 克隆或构建。
