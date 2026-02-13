# PLAN2: NetBird Exit Node + SquidSCAS 段階導入

## 1. 目的

- NetBird 接続時のみ CASB/SWG 制御を適用する
- 既存の `ztna-poc`（Keycloak + NetBird + midPoint）に影響を与えず、`profile=exitnode` で分離導入する
- まずは PoC として「可視化 + ドメイン制御 + ICAP接続確認」を成立させる

## 2. 実装スコープ

### In Scope (Phase 1)

- Exit Node 専用サービス群（`exitnode-gw`, `squid`, `squidscas`, `memcached`）を Docker Compose へ追加
- `scripts/demo/exitnode-bootstrap.sh` で NetBird 登録 + iptables 設定を自動化
- `shadow.log` による SaaS アクセス可視化
- SaaS ドメイン拒否（`.dropbox.com`, `.box.com`, `.drive.google.com`）
- `just` タスクで起動/検証を再現可能化

### Out of Scope (Phase 1)

- フル SSL Bump 本番運用
- LDAP/LISM 連携の本番実装
- SIEM への恒久連携

## 3. 追加インターフェース

### 環境変数

- `SQUID_HOSTNAME`
- `NB_EXITNODE_SETUP_KEY`
- `SCAS_REDIR_URL`
- `SCAS_MEMCACHED_HOST`
- `EXITNODE_PROFILE_ENABLED`

### Compose サービス（`profile: exitnode`）

- `exitnode-gw`: NetBird クライアント + iptables 設定対象
- `squid`: 透過/明示プロキシ
- `memcached`: SquidSCAS キャッシュ
- `squidscas`: c-icap + SquidSCAS module

### just タスク

- `just exitnode-up`
- `just exitnode-down`
- `just demo-exitnode`
- `just demo-verify-squid`
- `just demo-verify-block`
- `just demo-shadow-log [lines]`

## 4. 実装ファイル

- `compose.yaml`
- `.env.example`
- `scripts/gen-env.sh`
- `justfile`
- `README.md`
- `exitnode/squid/squid.conf`
- `exitnode/squid/blocked_saas.txt`
- `exitnode/squidscas/Dockerfile`
- `exitnode/squidscas/conf/c-icap.conf`
- `exitnode/squidscas/conf/squidscas.conf`
- `exitnode/squidscas/conf/scas_scan.conf`
- `exitnode/squidscas/conf/scas_service.conf`
- `exitnode/squidscas/scripts/entrypoint.sh`
- `scripts/demo/exitnode-bootstrap.sh`
- `scripts/demo/demo-exitnode.sh`
- `scripts/demo/verify-squid-path.sh`
- `scripts/demo/verify-saas-block.sh`
- `scripts/demo/collect-shadow-log.sh`

## 5. 受け入れ基準

1. `just exitnode-up` で Exit Node 関連サービスが起動する
2. `just demo-verify-squid` で明示プロキシ疎通が通り、`shadow.log` にアクセスログが残る
3. `just demo-verify-block` で `dropbox.com` が拒否される
4. 既存 `just demo` のフローが維持される（`profile` 分離）

## 6. 既知の制約

- HTTPS の透過制御は運用環境で SSL Bump などの設計が必要
- SquidSCAS は upstream 前提（AlmaLinux 手順）との差分があり、コンテナ化では依存パッケージ差分の調整が必要
- 高度CASB機能（操作単位制御など）は追加連携（LDAP/ポリシーデータ）が必要
