#!/usr/bin/env bash
# examples/fetch-content.sh — bash + curl 的最小可运行示例。
#
# 用法：
#   bash examples/fetch-content.sh --base <URL> --token <TOKEN>
#
# 退出码：
#   0  成功，stdout 是 markdown 正文（版本号走 stderr）
#   1  失败，stderr 一行中文错误
#
# 演示了三个要点：
#   1. 所有读取接口都需要凭证（这里用 Authorization: Bearer）
#   2. 从 manifest 读出 version（脚本不维护本地缓存；要不要按版本号短路由调用方决定）
#   3. 401 与「连不上」都要变成一行中文提示，不抛栈
#
# 为什么用 Authorization 头、而不是 ?token=<token>：
#   令牌写在 URL 里会跟着请求行进服务端与反代的访问日志，而这个令牌就是账号。
#   服务端两种姿势都支持（?token= 更适合本地调试），本脚本用不会进日志的那种。

set -euo pipefail

BASE=""
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      # `set -u` 会把 `BASE="$2"` 在缺值时变成英文的
      # `line N: $2: unbound variable` —— 那既不是中文也不是一行可读的错误，
      # 而本脚本承诺的是「失败 → stderr 一行中文」。所以自己先看值在不在。
      if [[ $# -lt 2 ]]; then
        echo "缺少 --base 的值。" >&2
        exit 1
      fi
      BASE="$2"
      shift 2
      ;;
    --token)
      if [[ $# -lt 2 ]]; then
        echo "缺少 --token 的值。" >&2
        exit 1
      fi
      TOKEN="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
用法：bash fetch-content.sh --base <URL> --token <TOKEN>

  --base <URL>     fire-sever 服务地址，例如 http://127.0.0.1:8787
  --token <TOKEN>  在 /register 拿到的读令牌（48 个十六进制字符）

成功：stdout 输出 markdown 正文，退出码 0。
失败：stderr 一行中文错误，退出码 1。
USAGE
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BASE" || -z "$TOKEN" ]]; then
  echo "缺少 --base 或 --token。" >&2
  exit 1
fi

# 去掉 base 末尾的 /，避免拼出 //api/manifest
BASE="${BASE%/}"

# 服务端对令牌**逐字匹配**：不 trim、不做 URL 编码、不折叠大小写。
# 令牌是 48 个十六进制字符，怎么给的、就怎么传。
AUTH_HEADER="Authorization: Bearer ${TOKEN}"

# 临时文件：body 走 -o 写文件、状态码走 -w 打 stdout。
#
# 为什么不用更眼熟的 `curl -w '\n%{http_code}'` 然后 `head -n -1`：
# 那个 `head -n -1` 是 **GNU 专有**的，BSD/macOS 的 head 不认，脚本会在
# macOS 订阅者手里静默地把状态码当成 body。分成两个通道没有这个问题，
# 而且 body 里有换行也不会串味。
#
# 为什么是 `curl -s` 而不是 `-sS`：本脚本承诺「失败 → stderr 一行中文」。
# `-S` 会把 curl 自己的英文错误也写到 stderr，那一行就变成两行（实测：
# 连不上时先来一行 `curl: (7) Failed to connect …`）。静默掉 curl 的输出，
# 由下面自己打印那一行中文。
TMPDIR_RUN="$(mktemp -d 2>/dev/null || mktemp -d -t fire-sever)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# 拉 manifest。
#
# `|| { … }` 这一段是**契约的一部分**：curl 连不上 / DNS 失败时退出码不是 0，
# 而 `set -e` 会直接把脚本干掉（退出 7）。本脚本承诺的是「失败 → stderr
# 一行中文 + 退出 1」，所以传输层失败要自己接住。
manifest_code="$(curl -s -o "$TMPDIR_RUN/manifest.json" -w '%{http_code}' \
  -H "$AUTH_HEADER" "${BASE}/api/manifest")" || {
  echo "连不上服务端 ${BASE}，请检查地址与网络。" >&2
  exit 1
}

if [[ "$manifest_code" == "401" ]]; then
  echo "令牌无效或缺失，请重新去 ${BASE}/register 注册。" >&2
  exit 1
fi
if [[ "$manifest_code" == "404" ]]; then
  echo "服务端尚无任何快照可拉。" >&2
  exit 1
fi
if [[ "$manifest_code" != "200" ]]; then
  echo "manifest 返回 HTTP ${manifest_code}。" >&2
  exit 1
fi

# 从 manifest 提取 version 字段。这里用 grep 演示，不依赖 jq。
# 真实 agent 通常用 jq：manifest_version="$(jq -r '.version' "$TMPDIR_RUN/manifest.json")"
manifest_version="$(grep -oE '"version"[[:space:]]*:[[:space:]]*[0-9]+' "$TMPDIR_RUN/manifest.json" \
  | grep -oE '[0-9]+')"

if [[ -z "$manifest_version" ]]; then
  echo "manifest 响应缺少 version 字段。" >&2
  exit 1
fi

# 拉内容。同样接住传输层失败。
content_code="$(curl -s -o "$TMPDIR_RUN/content.md" -w '%{http_code}' \
  -H "$AUTH_HEADER" "${BASE}/api/content")" || {
  echo "连不上服务端 ${BASE}，请检查地址与网络。" >&2
  exit 1
}

if [[ "$content_code" == "401" ]]; then
  echo "令牌无效或缺失，请重新去 ${BASE}/register 注册。" >&2
  exit 1
fi
if [[ "$content_code" != "200" ]]; then
  echo "内容返回 HTTP ${content_code}。" >&2
  exit 1
fi

# 成功。版本号打 stderr（不污染 stdout 的正文），markdown 正文打 stdout。
printf '版本 v%04d\n' "$manifest_version" >&2
cat "$TMPDIR_RUN/content.md"
