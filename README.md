# ZTNA PoC Stack (NetBird + Keycloak + midPoint)

Docker Compose ベースの IaC 雛形です。Ubuntu/WSL2 上での実行を前提に、`just` でタスクを統一しています。

## 前提

- Ubuntu 22.04+ または WSL2(Ubuntu)
- Docker Engine + Docker Compose v2
- `bash`
- `just` (task runner)
- 任意: Nix (`nix run .#up` 用)

## インストール例 (Ubuntu)

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 curl
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## 主要ファイル

- `compose.yaml`: サービス定義
- `.env.example`: 必須環境変数テンプレート
- `justfile`: タスクランナー定義
- `scripts/gen-env.sh`: `.env` から `scripts/init-db.sql` 生成
- `scripts/up.sh`: 起動
- `scripts/down.sh`: 停止

## クイックスタート

```bash
just check-tools
just up
```

`.env` が無い場合は、`just up` / `just demo` 実行時にローカルデモ用デフォルト値で自動生成されます。

停止:

```bash
just down
```

## just タスク

```bash
just
just init-env
just config
just up
just down
just restart
just ps
just logs
just logs keycloak
just demo-clean-netbird
```

## 任意: Nix コマンド

```bash
nix run .#gen
nix run .#up
nix run .#down
```

## DNS / Hostname

以下のホスト名を Traefik 実行ホストに向けてください (DNS または `/etc/hosts`)。

- `KC_HOSTNAME`
- `NB_DOMAIN`
- `NB_UI_DOMAIN`
- `MP_HOSTNAME`

`.env` の既定値を使う場合のアクセス先:

- `https://keycloak.localtest.me` (Keycloak)
- `https://netbird.localtest.me` (NetBird Management API)
- `https://netbird-ui.localtest.me` (NetBird Dashboard / SSO)
- `https://midpoint.localtest.me` (midPoint)

`just demo` 実行後の最終確認:

- NetBird の SSO を完了
- `demo-client` から `nb-router` 配下の内部ページ `hello internal world` を取得できることをスクリプトが検証

デモの認証分担:

- `nb-router`: setup key で非対話登録
- `demo-client`: ブラウザ SSO で対話登録

`just demo` が失敗したときの最短切り分け:

- `just demo-logs-once nb-router`
- `just demo-logs-once netbird`
- `just demo-logs-once netbird-signal`
- NetBird 関連状態を掃除して再試行する場合: `just demo-clean-netbird`

## 補足

- 外部公開ポートは Traefik の `80/443` のみです。
- 内部サービスは Docker `internal` ネットワークに配置されます。
- 証明書自動化 (Let's Encrypt / 社内 CA) は未設定です。`traefik` 配下設定を差し替えてください。
