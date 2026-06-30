#!/usr/bin/env bash
#
# flash.sh - 左右両方の CLine46 キーボードへファームウェアを書き込む。
#
# ローカル HEAD のコミットに対応する GitHub Actions ビルドを使用する。
# ビルドが無ければ workflow_dispatch でビルドを起動し、完了を待ってから
# firmware artifact を取得し、左手側・右手側を順に書き込む。
#
# --reset 指定時は settings_reset ファームを書き込み、保存済み設定
# (Bluetooth ペアリング情報など) を初期化する。
#
# 依存: gh (GitHub CLI / 認証済み), jq, unzip, git
# 対応OS: macOS (/Volumes), Linux (/media, /run/media)。bash 3.2 で動作。
#
set -euo pipefail

REPO="progfay/zmk_config_CLine46"
WORKFLOW="build.yml"
ARTIFACT_NAME="firmware"

# 共通状態
KEEP=0
RUN_ID=""
WORKDIR=""

# 書き込みキー -> artifact 内の .uf2 ファイル名
# (bash 3.2 には連想配列が無いため関数で引く)
uf2_file() {
  case "$1" in
    left)  echo "CLine46_L rgbled_adapter-seeeduino_xiao_ble-zmk.uf2" ;;
    right) echo "CLine46_R rgbled_adapter-seeeduino_xiao_ble-zmk.uf2" ;;
    reset) echo "settings_reset-seeeduino_xiao_ble-zmk.uf2" ;;
    *)     return 1 ;;
  esac
}

# ---- 出力ヘルパ -------------------------------------------------------------
if [ -t 1 ]; then
  C_R='\033[31m'; C_G='\033[32m'; C_Y='\033[33m'; C_B='\033[36m'; C_0='\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi
info()  { printf "${C_B}==>${C_0} %s\n" "$*"; }
ok()    { printf "${C_G}OK ${C_0} %s\n" "$*"; }
warn()  { printf "${C_Y}!! ${C_0} %s\n" "$*"; }
die()   { printf "${C_R}ERR${C_0} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
使い方: ./flash.sh [オプション]

左右両方の CLine46 キーボードへファームウェアを書き込みます。
ローカル HEAD のビルドが無ければ自動でビルドを起動し、完了を待ちます。
(事前にコミットを push しておくこと)

オプション:
  --reset      settings_reset を書き込み、保存済み設定を初期化する
  -k, --keep   ダウンロードした一時ファイルを削除しない
  -h, --help   このヘルプを表示
EOF
}

# ---- 引数パース -------------------------------------------------------------
# 第1引数に --reset 指定の有無を受け取る変数名を渡す（0/1 が書き込まれる）。
parse_args() {
  local _reset_var="$1"; shift   # 結果(0/1)を書き込む変数名
  local _reset=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reset)    _reset=1 ;;
      -k|--keep)  KEEP=1 ;;
      -h|--help)  usage; exit 0 ;;
      *)          usage; die "不明な引数: $1" ;;
    esac
    shift
  done
  eval "$_reset_var=$_reset"     # bash 3.2 は nameref 非対応のため eval で返す
}

# ---- 依存チェック -----------------------------------------------------------
check_deps() {
  for cmd in gh jq unzip git; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd が見つかりません。インストールしてください。"
  done
  gh auth status >/dev/null 2>&1 || die "gh が未認証です。'gh auth login' を実行してください。"
}

# ---- run 検索ヘルパ ---------------------------------------------------------
# 指定 SHA のビルド run を "databaseId status conclusion" 形式で返す（無ければ空）
find_run_by_sha() {
  gh run list -R "$REPO" --workflow "$WORKFLOW" -L 40 \
    --json databaseId,headSha,status,conclusion \
    -q "[.[] | select(.headSha==\"$1\")] | first | select(.) | \"\(.databaseId) \(.status) \(.conclusion)\"" \
    2>/dev/null || echo ""
}

# 現ブランチを ref に workflow_dispatch でビルドを起動し、RUN_ID を確定する
trigger_build() {
  local branch="$1" before
  before=$(gh run list -R "$REPO" --workflow "$WORKFLOW" -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
  gh workflow run "$WORKFLOW" -R "$REPO" --ref "$branch" \
    || die "ビルドのトリガーに失敗しました (workflow_dispatch が有効か / ブランチが push 済みか確認)"
  info "新しい run の出現を待っています..."
  for _ in $(seq 1 30); do
    sleep 3
    RUN_ID=$(gh run list -R "$REPO" --workflow "$WORKFLOW" -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
    [ -n "$RUN_ID" ] && [ "$RUN_ID" != "$before" ] && return 0
    RUN_ID=""
  done
  die "新しい run を検出できませんでした"
}

# ---- run の解決 -------------------------------------------------------------
# HEAD SHA のビルドが既にあればそれを使い、無ければ workflow_dispatch でビルド。
# 実行中なら完了を待ち、過去ビルドが失敗していれば再ビルドする。
resolve_run() {
  local head_sha branch run_status run_concl
  head_sha=$(git rev-parse HEAD 2>/dev/null) || die "git リポジトリ内で実行してください"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ "$branch" != "HEAD" ] && [ -n "$branch" ] || die "detached HEAD では実行できません。ブランチ上で実行してください。"

  # push 済みか確認（未 push だと別コミットでビルドされる）
  if [ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]; then
    die "HEAD (${head_sha:0:7}) がリモートにありません。先に 'git push' してください。"
  fi

  info "HEAD (${head_sha:0:7}) のビルドを確認しています..."
  read -r RUN_ID run_status run_concl <<<"$(find_run_by_sha "$head_sha")"

  if [ -z "$RUN_ID" ]; then
    info "このコミットのビルドはまだありません。ビルドを開始します。"
    trigger_build "$branch"
    info "ビルド実行中: https://github.com/$REPO/actions/runs/$RUN_ID"
    gh run watch -R "$REPO" "$RUN_ID" --exit-status || die "ビルドが失敗しました"
    ok "ビルド完了"
  elif [ "$run_status" != "completed" ]; then
    info "ビルドが実行中です。完了を待ちます: https://github.com/$REPO/actions/runs/$RUN_ID"
    gh run watch -R "$REPO" "$RUN_ID" --exit-status || die "ビルドが失敗しました"
    ok "ビルド完了"
  elif [ "$run_concl" != "success" ]; then
    warn "このコミットの既存ビルドは失敗しています ($run_concl)。再ビルドします。"
    trigger_build "$branch"
    info "ビルド実行中: https://github.com/$REPO/actions/runs/$RUN_ID"
    gh run watch -R "$REPO" "$RUN_ID" --exit-status || die "ビルドが失敗しました"
    ok "ビルド完了"
  else
    ok "HEAD のビルドは成功済みです。これを使用します。"
  fi
  info "使用する run: $RUN_ID"
}

# ---- Artifact ダウンロード --------------------------------------------------
# 引数: 必要な uf2_file のキー（存在確認用）
download_artifact() {
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/cline46-flash.XXXXXX")
  trap '[ "$KEEP" -eq 1 ] || rm -rf "$WORKDIR"' EXIT
  [ "$KEEP" -eq 0 ] || info "一時ディレクトリ: $WORKDIR (削除しません)"

  info "firmware artifact をダウンロードしています..."
  gh run download -R "$REPO" "$RUN_ID" -n "$ARTIFACT_NAME" -D "$WORKDIR" \
    || die "artifact のダウンロードに失敗 (期限切れの可能性)"
  ok "ダウンロード完了"

  local key fname
  for key in "$@"; do
    fname=$(uf2_file "$key")
    [ -f "$WORKDIR/$fname" ] \
      || die "ファイルが artifact 内に見つかりません: $fname"
  done
}

# ---- ブートローダー検出 -----------------------------------------------------
# UF2 ブートローダーはルートに INFO_UF2.TXT を持つ。これを検出キーにする。
find_uf2_volume() {
  local base vol
  for base in /Volumes /media/"$USER" /media /run/media/"$USER"; do
    [ -d "$base" ] || continue
    for vol in "$base"/*; do
      [ -d "$vol" ] && [ -f "$vol/INFO_UF2.TXT" ] && { printf '%s\n' "$vol"; return 0; }
    done
  done
  return 1
}

wait_for_bootloader() {
  local timeout=120 elapsed=0 vol
  while ! vol=$(find_uf2_volume); do
    sleep 1; elapsed=$((elapsed + 1))
    [ "$elapsed" -ge "$timeout" ] && return 1
  done
  printf '%s\n' "$vol"
}

# ---- 1台への書き込み --------------------------------------------------------
# 引数: 表示ラベル, uf2_file のキー
flash_one() {
  local label="$1" key="$2" src
  src="$WORKDIR/$(uf2_file "$2")"
  echo
  info "[$label] キーボードをブートローダーに入れてください (RESET を素早く2回)。"
  warn "別のキーボードがブートローダーで接続中なら取り外してください。"

  local vol
  vol=$(wait_for_bootloader) || { warn "[$label] ブートローダーを検出できませんでした。スキップします。"; return 1; }
  ok "[$label] ブートローダー検出: $vol"

  info "[$label] 書き込み中..."
  # XIAO は書き込み完了で自動的にリセット/アンマウントするため、cp の失敗は許容して判定する
  cp "$src" "$vol/" 2>/dev/null || true
  sync 2>/dev/null || true

  # ボリュームが消える = 書き込み成功してリブートした合図
  local waited=0
  while [ -d "$vol" ] && [ -f "$vol/INFO_UF2.TXT" ]; do
    sleep 1; waited=$((waited + 1))
    [ "$waited" -ge 30 ] && { warn "[$label] 自動リセットを確認できませんでしたが、書き込みは行われた可能性があります。"; break; }
  done
  ok "[$label] 書き込み完了"
}

# ---- メイン: 複数台へ順に書き込み -------------------------------------------
# 引数: "ラベル|キー" の並び (例: "左手|left" "右手|right")
run_flash() {
  check_deps
  resolve_run

  local pairs=("$@") keys=() pair
  for pair in "${pairs[@]}"; do keys+=("${pair##*|}"); done
  download_artifact "${keys[@]}"

  local failed=()
  for pair in "${pairs[@]}"; do
    flash_one "${pair%%|*}" "${pair##*|}" || failed+=("${pair%%|*}")
  done

  echo
  if [ ${#failed[@]} -eq 0 ]; then
    ok "すべての書き込みが完了しました 🎉"
  else
    warn "未完了: ${failed[*]}"
    exit 1
  fi
}

# ---- エントリポイント -------------------------------------------------------
parse_args do_reset "$@"

# reset 指定時は左右それぞれ「settings_reset → 通常ファーム」の順で書き込む。
# (reset 後はボードが通常リブートするため、各書き込み前に再度ブートローダーへ入れる)
# 通常時は左右で別ファイル・順序が意味を持つので「左手/右手」で書き込む。
if [ "$do_reset" -eq 1 ]; then
  warn "settings_reset を書き込むと Bluetooth ペアリング等の保存設定が消えます。"
  warn "リセット後に通常ファームを書き戻すため、左右それぞれ 2 回ずつ書き込みます。"
  printf "続行しますか? [y/N] "
  read -r ans
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *) info "中止しました。"; exit 0 ;;
  esac
  run_flash "左手 reset|reset" "左手 flash|left" "右手 reset|reset" "右手 flash|right"
else
  run_flash "左手|left" "右手|right"
fi
