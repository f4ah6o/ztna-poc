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
just certs-dns01-import
just certs-dns01-apply
just certs-dns01-check
just demo-dns01
just demo-dns01-fresh
just netsim-up
just obs-up
just obs-ps
just obs-logs
just obs-down
just netsim-create
just netsim-status
just netsim-verify
just netsim-preset degraded
just netsim-link gateway veth-gw-saas down
just netsim-link gateway veth-gw-saas up
just netsim-destroy
just netsim-down
just exitnode-up
just exitnode-down
just demo-exitnode
just demo-verify-squid
just demo-verify-block
just demo-shadow-log 100
```

`dns01` の証明書 (`../dns01-poc/out.pem`) を使う場合:

- `just certs-dns01-import` で `traefik/certs/localtest.pem` / `localtest-key.pem` に取り込み
- `just certs-dns01-apply` で取り込み後に `traefik` を再作成して証明書反映
- `just demo-dns01` で証明書取り込み後に demo 実行
- `just demo-dns01-fresh` で NetBird 関連クリーン + 証明書取り込み + demo 実行
- 取り込み元を変える場合: `DNS01_CERT_BUNDLE_PATH=/path/to/out.pem just certs-dns01-import`

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

`.env` の設定値を使ったアクセス先:

- `https://${KC_HOSTNAME}` (Keycloak)
- `https://${NB_DOMAIN}` (NetBird Management API)
- `https://${NB_UI_DOMAIN}` (NetBird Dashboard / SSO)
- `https://${MP_HOSTNAME}` (midPoint)

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

## Observability (Prometheus + Grafana + Loki)

`profile=observability` で、全サービス横断のメトリクス/ログ監視を起動できます。

- `just obs-up`: observability サービス群を起動
- `just obs-ps`: observability サービス状態を確認
- `just obs-logs [service]`: observability ログを確認
- `just obs-down`: observability サービス群を停止

主要アクセス先 (docker host ローカル限定):

- `http://127.0.0.1:3000` (Grafana)
- `http://127.0.0.1:9090` (Prometheus)
- `http://127.0.0.1:3100` (Loki API)

Grafana 初期認証情報:

- User: `${GRAFANA_ADMIN_USER}` (default: `admin`)
- Password: `${GRAFANA_ADMIN_PASSWORD}` (default は `.env` 参照)

同梱ダッシュボード:

- `Platform Overview`
- `Auth & Access Audit`
- `SCIM Bridge API`
- `Exitnode / Squid`

監査向け LogQL 例:

- Keycloak 認証失敗: `{compose_service="keycloak"} |= "invalid_user_credentials"`
- Squid ブロック記録: `{compose_service="squid"} |= "TCP_DENIED"`

## Exit Node + SquidSCAS PoC

`profile=exitnode` で、NetBird Exit Node コンテナに Squid + SquidSCAS(ICAP) を接続する PoC を実行できます。

- `just exitnode-up`: Exit Node 関連サービスを起動
- `just demo-exitnode`: 起動 + NetBird 登録 + iptables + プロキシ検証を一括実行
- `just demo-verify-squid`: 明示プロキシ経由の疎通と `shadow.log` 記録を検証
- `just demo-verify-block`: `dropbox.com` ブロックを検証
- `just demo-shadow-log 100`: `shadow.log` を末尾100行確認

最短実行手順:

```bash
just exitnode-up
just demo-exitnode
```

期待される確認ポイント:

- `verify-squid-path` が `Example Domain` 到達を確認
- `verify-saas-block` が `dropbox.com` 拒否を確認
- `demo-shadow-log` でアクセス記録が取得できる

既知の注意:

- `exitnode-bootstrap.sh` 実行時に `sysctl: ... Read-only file system` が出る場合があります（コンテナ制約による警告）。PoC フロー継続には影響しません。
- 現在の PoC は通信成立を優先し、Squid の ICAP は `bypass=1`（ICAP 異常時はフェイルオープン）で設定しています。厳格運用にする場合は `exitnode/squid/squid.conf` の `bypass` を見直してください。
- `midpoint` が `OOMKilled (exit 137)` になる場合は `.env` の `MP_JAVA_XMS` / `MP_JAVA_XMX` を下げてください（例: `MP_JAVA_XMS=192m`, `MP_JAVA_XMX=512m`）。

追加ファイル:

- `exitnode/squid/squid.conf`
- `exitnode/squid/blocked_saas.txt`
- `exitnode/squidscas/` (Dockerfile, c-icap/squidscas 設定)
- `scripts/demo/exitnode-bootstrap.sh`
- `scripts/demo/verify-squid-path.sh`
- `scripts/demo/verify-saas-block.sh`

## pyroute2 NetSim PoC

`profile=netsim` で、`pyroute2` を使った仮想ネットワークシミュレータを実行できます。

- `client`, `gateway`, `saas` の3つのnetwork namespaceを作成
- `veth` 接続 + route + gateway NAT(MASQUERADE) を構成
- 障害注入: `tc netem`（遅延/ロス）と link down/up（断線）

最短実行手順:

```bash
just netsim-up
just netsim-create
just netsim-status
```

障害注入例:

```bash
# プリセット適用 (delay 200ms, loss 10%)
just netsim-preset degraded

# 断線
just netsim-link gateway veth-gw-saas down
# 復旧
just netsim-link gateway veth-gw-saas up
```

疎通と障害注入をまとめて検証する場合:

```bash
just netsim-verify
```

クリーンアップ:

```bash
just netsim-destroy
just netsim-down
```

プリセット定義は `netsim/config.yaml` で変更できます。

## 補足

- 外部公開ポートは Traefik の `80/443` のみです。
- 内部サービスは Docker `internal` ネットワークに配置されます。
- 証明書自動化 (Let's Encrypt / 社内 CA) は未設定です。`traefik` 配下設定を差し替えてください。
- `postgres` 初回初期化時に midPoint native schema (`midpoint/sql/native/*.sql`) を自動適用します。既存 `pg_data` ボリュームには再適用されないため、スキーマ不整合時は `pg_data` を削除して再作成してください。
