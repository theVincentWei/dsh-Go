#!/bin/sh
# 合入后自动清理已合并的工作树与分支(对齐 CONTRIBUTING「工作提交并合并后,
# 必须清理本次创建的临时工作树与分支」)。
#
#   tooling/cleanup-merged-worktrees.sh             # 清理,并说明每个跳过原因
#   tooling/cleanup-merged-worktrees.sh --dry-run   # 只报告,不删任何东西
#   tooling/cleanup-merged-worktrees.sh --install   # 给本仓库装 post-merge 钩子
#
# 删除条件(缺一不可,其余一律跳过并写明原因):
#   - 分支已完全合入 main
#   - 不是主工作树,也不是当前所在工作树;不是 detached HEAD
#   - 没有已跟踪文件的未提交改动(未跟踪的构建产物会随工作树一起删除,
#     删除前会打印数量)
#
# 钩子只跑「git merge / git pull 之后」;手动清理随时可跑。Git 的钩子目录
# 不随仓库版本控制,换机器/新 clone 后跑一次 --install 即可。

set -u

MAIN_BRANCH=main
MODE=clean
QUIET=0

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE=dry ;;
    --install) MODE=install ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "cleanup-merged-worktrees: 未知参数 $arg"; exit 2 ;;
  esac
done

GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
MAIN_WT=$(cd "$GIT_COMMON/.." && pwd -P) || exit 0

if [ "$MODE" = install ]; then
  hook="$GIT_COMMON/hooks/post-merge"
  # 主工作树之外也认脚本:钩子里用当前工作树根定位。
  cat > "$hook" <<'HOOK'
#!/bin/sh
# 合入后自动清理已合并的工作树(规则见 tooling/cleanup-merged-worktrees.sh)。
# 合入动作本身已成功;清理出任何问题都只提示,不影响退出码。
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
script="$root/tooling/cleanup-merged-worktrees.sh"
[ -f "$script" ] || exit 0
sh "$script" --quiet
exit 0
HOOK
  chmod +x "$hook"
  printf '已安装钩子: %s\n' "$hook"
  exit 0
fi

CURRENT_WT=$(pwd -P 2>/dev/null || true)

# 主工作树不能删,当前工作树删了会让调用方 cwd 消失:先跳过后面的判断。
tmp=$(mktemp "${TMPDIR:-/tmp}/worktrees.XXXXXX") || exit 0
trap 'rm -f "$tmp"' EXIT

git worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10); branch = ""; detached = 0 }
  /^branch /   { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch) }
  /^detached$/ { detached = 1 }
  /^$/         { if (path != "") printf "%s\t%s\t%d\n", path, branch, detached; path = "" }
  END          { if (path != "") printf "%s\t%s\t%d\n", path, branch, detached }
' > "$tmp"

removed=0
while IFS= read -r line; do
  path=$(printf '%s' "$line" | cut -f1)
  branch=$(printf '%s' "$line" | cut -f2)
  detached=$(printf '%s' "$line" | cut -f3)
  [ -n "$path" ] || continue
  real=$(cd "$path" 2>/dev/null && pwd -P) || continue

  if [ "$real" = "$MAIN_WT" ]; then
    continue
  fi
  if [ "$real" = "$CURRENT_WT" ]; then
    say "跳过(当前所在工作树): $real"
    continue
  fi
  if [ "$detached" = 1 ] || [ -z "$branch" ]; then
    say "跳过(detached HEAD,没有可入库的分支): $real"
    continue
  fi
  if [ "$branch" = "$MAIN_BRANCH" ]; then
    say "跳过(main 分支自身): $real"
    continue
  fi
  if ! git merge-base --is-ancestor "refs/heads/$branch" "$MAIN_BRANCH" 2>/dev/null; then
    say "跳过($branch 尚未合入 $MAIN_BRANCH): $real"
    continue
  fi
  if [ -n "$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    say "跳过($branch 有已跟踪文件的未提交改动): $real"
    continue
  fi

  untracked=$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  if [ "$MODE" = dry ]; then
    say "[dry-run] 会删除工作树 + 分支: $branch ($real),未跟踪文件 $untracked 个"
    continue
  fi
  # 先不带 --force:干净的工作树正常删除;只剩未跟踪构建产物时强制删除,
  # 并在下面写明丢了几个文件,不静默吞掉。
  if ! git worktree remove "$path" 2>/dev/null; then
    if ! git worktree remove --force "$path" 2>/dev/null; then
      warn "删除失败(保留原地): $real"
      continue
    fi
  fi
  git branch -d "$branch" >/dev/null 2>&1 || warn "工作树已删,分支 $branch 删除失败(可能已不存在)"
  removed=$((removed + 1))
  say "已清理: $branch ($real),未跟踪文件 $untracked 个随工作树删除"
done < "$tmp"

if [ "$removed" = 0 ] && [ "$MODE" != dry ]; then
  say "没有可清理的工作树。"
elif [ "$MODE" = dry ]; then
  say "(dry-run 结束,未删除任何东西)"
fi
