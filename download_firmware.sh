#!/usr/bin/env bash
# 下载 nio (XT2125-4) 原厂固件包到当前目录。
# 支持断点续传：中断后重跑本脚本会接着下，不用重头来。
set -euo pipefail

URL="https://mirrors-obs-1.lolinet.com/firmware/lenomola/2021/nio_retcn/official/RETCN/XT2125-4_NIO_RETCN_12_S1RN32.55-16-13_subsidy-DEFAULT_regulatory-DEFAULT_CFC.xml.zip"
OUT="$(basename "$URL")"

echo "目标文件: $OUT"
echo "下载地址: $URL"
echo

# -C -  断点续传； -L 跟随跳转； --retry 网络抖动自动重试； 显示进度条
curl -L -C - --retry 5 --retry-delay 3 --progress-bar -o "$OUT" "$URL"

echo
echo "=== 下载完成 ==="
ls -lh "$OUT"
echo
echo "=== 文件类型 ==="
file "$OUT"
echo
echo "=== zip 完整性校验 ==="
if unzip -t "$OUT" >/dev/null 2>&1; then
  echo "OK: zip 完整"
else
  echo "警告: zip 校验未通过，可能没下完。重跑本脚本可继续下载。"
fi
