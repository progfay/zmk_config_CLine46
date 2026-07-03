# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

CLine46(46キー分割キーボード、Seeed XIAO BLE、右手に PMW3610 トラックボール)の ZMK ファームウェア設定リポジトリ。

**ZMK 本体は progfay/zmk fork(`retro-tap-pointer-cancel-v0.3` ブランチ)を使用している**(`config/west.yml`)。zmkfirmware/zmk v0.3 に「retro-tap をポインタ入力で解除する」パッチを当てたもので、ZMK 更新時はこのブランチを rebase する。

## ビルド・書き込み

ローカルビルドは行わない。GitHub Actions(`build.yml`、workflow_dispatch のみ)が `build.yaml` のマトリクスでビルドする。
キーボードへの書き込みは `./flash.sh` を使う。

- `./flash.sh` — HEAD に対応するビルドを取得(無ければ起動して待機)し、左手→右手の順に UF2 を書き込む。コミットを push 済みであることが前提。依存: gh, jq, unzip
- `./flash.sh --reset` — settings_reset で保存設定(BLE ペアリング等)を初期化してから通常ファームを書き戻す

キーマップ図(`keymap-drawer/`)は `draw.yml` が keymap 変更の push 時に自動生成・コミットするため、手動更新は不要。

## 構成

- `config/CLine46.keymap` — キーマップと behaviors(hjkl→矢印の mod-morph、スクロール用 scaler など)
- `config/west.yml` — 依存モジュール(ZMK fork、PMW3610 ドライバ、NiMH バッテリ管理、rgbled widget)
- `boards/shields/CLine46/` — シールド定義。右手(`_R`)が split central でトラックボール搭載
- 電源は NiMH。non-LiPo battery management モジュールを使い、デフォルトの `vbatt` は無効化している

### Kconfig の注意

`Kconfig.defconfig` の `default` は ZMK コア側の default に負けて反映されないことがある。確実に効かせたい値は `CLine46_L.conf` / `CLine46_R.conf` に明示的に書く(`CONFIG_ZMK_IDLE_SLEEP_TIMEOUT` のコメント参照)。
