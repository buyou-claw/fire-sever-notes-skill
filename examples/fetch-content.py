#!/usr/bin/env python3
"""examples/fetch-content.py — Python + requests 的最小可运行示例。

用法（Linux / macOS 上解释器通常是 python3）：
  python fetch-content.py --base <URL> --token <TOKEN>

退出码：
  0  成功，stdout 是 markdown 正文（版本号走 stderr）
  1  失败，stderr 一行中文错误

演示了三个要点：
  1. 所有读取接口都需要凭证（这里用 Authorization: Bearer，不把令牌写进 URL）
  2. 从 manifest 读出 version（脚本不维护本地缓存；要不要按版本号短路由调用方决定）
  3. 401 与传输层失败都要变成一行中文提示，不抛栈
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import NoReturn

# Windows 控制台的默认编码常常是 GBK/cp936，中文诊断会变成乱码，而且
# 同一个脚本在两个平台上吐出的字节不一样。强制 UTF-8，让 stdout / stderr
# 在任何平台都是同一份字节 —— 调用方（agent、CI、管道）只管按 UTF-8 解。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    except (AttributeError, ValueError):
        # 老 Python 或已被重定向成非文本流：保持原样，不为此失败。
        pass

try:
    import requests
except ImportError:
    print("缺少依赖：requests。请先运行 `pip install requests`。", file=sys.stderr)
    sys.exit(1)


def die(message: str) -> NoReturn:
    """失败路径：stderr 一行中文、退出码 1。"""
    print(f"fetch-content: {message}", file=sys.stderr)
    sys.exit(1)


class UsageErrorParser(argparse.ArgumentParser):
    """argparse 默认对用法错误 exit(2)；本 Skill 的契约是 exit(1)。

    bash 版本（fetch-content.sh）对同一种情况退出 1，两个脚本的退出码
    必须一致，否则一个按退出码分支的调用方会对「参数写错」和「服务端
    出错」做出不同反应。
    """

    def error(self, message: str) -> NoReturn:  # type: ignore[override]
        self.print_usage(sys.stderr)
        die(message)


def main() -> int:
    parser = UsageErrorParser(
        description="拉取 fire-sever 当前快照的 markdown 正文"
    )
    parser.add_argument("--base", required=True, help="fire-sever 服务地址，例如 http://127.0.0.1:8787")
    parser.add_argument("--token", required=True, help="在 /register 拿到的读令牌（48 个十六进制字符）")
    args = parser.parse_args()

    base = args.base.rstrip("/")
    # 服务端对令牌**逐字匹配**：不 trim、不做 URL 编码、不折叠大小写。令牌是
    # 48 个十六进制字符，怎么给的、就怎么传。
    token = args.token
    # 令牌走 Authorization 头，不走 URL：写在 query 里会跟着请求行进服务端与
    # 反代的访问日志，而这个令牌就是账号。（服务端两种姿势都支持，本脚本用
    # 不会进日志的那种。）
    headers = {"Authorization": f"Bearer {token}"}

    # 1) 拉 manifest。
    #
    # `except requests.RequestException` 是**契约的一部分**：连不上 / DNS 失败 /
    # 超时时 requests 会抛异常，未接住就是满屏 traceback（退出 1，但违背本脚本
    # 「失败 → 一行中文」的承诺；更糟的是 traceback 里带着完整 URL，会把令牌
    # 打进 stderr 日志）。所有传输层失败都在这里收成一行中文。
    try:
        manifest_resp = requests.get(f"{base}/api/manifest", headers=headers, timeout=10)
    except requests.RequestException as exc:
        die(f"连不上服务端 {base}，请检查地址与网络。（{type(exc).__name__}）")
    if manifest_resp.status_code == 401:
        die(f"令牌无效或缺失，请重新去 {base}/register 注册。")
    if manifest_resp.status_code == 404:
        die("服务端尚无任何快照可拉。")
    if manifest_resp.status_code != 200:
        die(f"manifest 返回 HTTP {manifest_resp.status_code}。")

    try:
        manifest = manifest_resp.json()
    except json.JSONDecodeError:
        die("manifest 响应不是合法 JSON。")

    version = manifest.get("version")
    if not isinstance(version, int):
        die("manifest 缺少版本字段 version。")

    # 2) 拉内容。
    try:
        content_resp = requests.get(f"{base}/api/content", headers=headers, timeout=10)
    except requests.RequestException as exc:
        die(f"连不上服务端 {base}，请检查地址与网络。（{type(exc).__name__}）")
    if content_resp.status_code == 401:
        die(f"令牌无效或缺失，请重新去 {base}/register 注册。")
    if content_resp.status_code != 200:
        die(f"内容返回 HTTP {content_resp.status_code}。")

    # 成功。版本号走 stderr（与 .sh 版一致，且不污染 stdout 的正文），
    # markdown 正文走 stdout —— agent 通常用 print(content_resp.text, end="")
    # 接住它继续渲染。
    print(f"版本 v{version:04d}", file=sys.stderr)
    sys.stdout.write(content_resp.text)
    return 0


if __name__ == "__main__":
    sys.exit(main())