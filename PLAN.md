rd+keycloak+midPointのIaCコード
コストと環境ポータビリティを最適化したい
思考時間: 8s

OK。コスト最小＋環境ポータビリティ最大を狙うなら、まずはこれが鉄板です：

アプリは全部 Docker Compose（どこでも動く）

設定は Nix Flake で“宣言的に生成”（差分が出にくい／再現性が高い）

公開面は 443 だけ（Traefik 1枚、他は内部ネットワーク）

下に **そのまま repo に置ける IaC 一式（雛形）**を出します。
（midPoint と Keycloak の“連携ロジック”自体は midPoint 側のコネクタ設定に寄るので、そこは 最小の前提だけ入れてあります）

リポジトリ構成（これでいく）
ztna-stack/
  flake.nix
  .env.example
  compose.yaml
  traefik/
    traefik.yaml
    dynamic.yaml
  keycloak/
    realm-netbird.json
  midpoint/
    midpoint.home/              # 初期設定を置く（必要なら）
  scripts/
    up.sh
    down.sh
    gen-env.sh

1) compose.yaml（低コスト: DBはPostgres1本でDB分割）

“1VMでまず回す”前提。将来は postgres を分けるだけでスケールできる形。

services:
  traefik:
    image: traefik:v3.1
    command:
      - --configFile=/etc/traefik/traefik.yaml
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yaml:/etc/traefik/traefik.yaml:ro
      - ./traefik/dynamic.yaml:/etc/traefik/dynamic.yaml:ro
      - traefik_letsencrypt:/letsencrypt
    networks: [edge, internal]
    restart: unless-stopped

  postgres:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_SUPERPASS}
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./scripts/init-db.sql:/docker-entrypoint-initdb.d/init-db.sql:ro
    networks: [internal]
    restart: unless-stopped

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    command: ["start", "--optimized"]
    environment:
      KC_PROXY: edge
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME: ${KC_HOSTNAME}
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KC_DB_PASSWORD}
      KEYCLOAK_ADMIN: ${KC_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: ${KC_ADMIN_PASSWORD}
    labels:
      - traefik.enable=true
      - traefik.http.routers.keycloak.rule=Host(`${KC_HOSTNAME}`)
      - traefik.http.routers.keycloak.entrypoints=websecure
      - traefik.http.routers.keycloak.tls=true
      - traefik.http.services.keycloak.loadbalancer.server.port=8080
    depends_on: [postgres]
    networks: [internal, edge]
    restart: unless-stopped

  netbird:
    image: netbirdio/management:latest
    environment:
      # NetBird Management
      NB_DOMAIN: ${NB_DOMAIN}
      NB_DISABLE_ANONYMOUS_METRICS: "true"

      # DB
      NETBIRD_STORE_ENGINE: postgres
      NETBIRD_STORE_DSN: postgres://netbird:${NB_DB_PASSWORD}@postgres:5432/netbird?sslmode=disable

      # OIDC (Keycloak)
      NETBIRD_AUTH_OIDC_CONFIGURATION_ENDPOINT: https://${KC_HOSTNAME}/realms/${KC_REALM}/.well-known/openid-configuration
      NETBIRD_AUTH_OIDC_CLIENT_ID: ${NB_OIDC_CLIENT_ID}
      NETBIRD_AUTH_OIDC_CLIENT_SECRET: ${NB_OIDC_CLIENT_SECRET}

      # OPTIONAL: enforce email domain, etc.
      # NETBIRD_AUTH_OIDC_EMAIL_CLAIM: email
      # NETBIRD_AUTH_OIDC_GROUPS_CLAIM: groups

    labels:
      - traefik.enable=true
      - traefik.http.routers.netbird.rule=Host(`${NB_DOMAIN}`)
      - traefik.http.routers.netbird.entrypoints=websecure
      - traefik.http.routers.netbird.tls=true
      - traefik.http.services.netbird.loadbalancer.server.port=80
    depends_on: [postgres, keycloak]
    networks: [internal, edge]
    restart: unless-stopped

  # 参考: NetBird Dashboard（使うなら）
  netbird-dashboard:
    image: netbirdio/dashboard:latest
    environment:
      NETBIRD_MGMT_API_ENDPOINT: https://${NB_DOMAIN}
    labels:
      - traefik.enable=true
      - traefik.http.routers.netbird-ui.rule=Host(`${NB_UI_DOMAIN}`)
      - traefik.http.routers.netbird-ui.entrypoints=websecure
      - traefik.http.routers.netbird-ui.tls=true
      - traefik.http.services.netbird-ui.loadbalancer.server.port=80
    depends_on: [netbird]
    networks: [internal, edge]
    restart: unless-stopped

  midpoint:
    image: evolveum/midpoint:4.9
    environment:
      REPO_DATABASE_TYPE: postgresql
      REPO_JDBC_URL: jdbc:postgresql://postgres:5432/midpoint
      REPO_JDBC_USERNAME: midpoint
      REPO_JDBC_PASSWORD: ${MP_DB_PASSWORD}

      # 初回セットアップ用（必要に応じて）
      MIDPOINT_NODE_ID: node1
      # MIDPOINT_PASSWORD_INITIAL_ADMIN: ${MP_ADMIN_PASSWORD}
    volumes:
      - mp_home:/opt/midpoint/var
      # - ./midpoint/midpoint.home:/opt/midpoint/var:rw  # 固定したいなら
    labels:
      - traefik.enable=true
      - traefik.http.routers.midpoint.rule=Host(`${MP_HOSTNAME}`)
      - traefik.http.routers.midpoint.entrypoints=websecure
      - traefik.http.routers.midpoint.tls=true
      - traefik.http.services.midpoint.loadbalancer.server.port=8080
    depends_on: [postgres]
    networks: [internal, edge]
    restart: unless-stopped

networks:
  edge:
  internal:
    internal: true

volumes:
  pg_data:
  mp_home:
  traefik_letsencrypt:

2) scripts/init-db.sql（DB分割でコスト最適化）
CREATE USER keycloak WITH PASSWORD '${KC_DB_PASSWORD}';
CREATE DATABASE keycloak OWNER keycloak;

CREATE USER netbird WITH PASSWORD '${NB_DB_PASSWORD}';
CREATE DATABASE netbird OWNER netbird;

CREATE USER midpoint WITH PASSWORD '${MP_DB_PASSWORD}';
CREATE DATABASE midpoint OWNER midpoint;


注意：Postgres公式イメージの init スクリプトは環境変数展開しないので、上の ${...} はそのままだと動きません。
なのでこの repo では Nix で init-db.sql を実体値で生成する想定にします（次）。

3) flake.nix（ポータブルに“envとinit-db.sql”を生成して起動）

どの環境でも nix run .#up で起動できる

.env と init-db.sql を 確実に同じ値で生成する（再現性UP）

{
  description = "NetBird + Keycloak + midPoint portable IaC (compose + nix)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forAll = f: nixpkgs.lib.genAttrs systems (system: f system);
  in
  {
    packages = forAll (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        gen = pkgs.writeShellApplication {
          name = "gen";
          runtimeInputs = [ pkgs.coreutils pkgs.gnused pkgs.openssl ];
          text = ''
            set -euo pipefail
            mkdir -p scripts

            # 1) .env を生成（必要ならここを sops-nix に差し替え）
            if [ ! -f .env ]; then
              cp -n .env.example .env
              echo "[gen] created .env (edit secrets!)"
            fi

            # 2) init-db.sql を .env の値で実体化
            #    (POSIXで雑に読む。必要なら python/dotenv にしてもOK)
            set -a
            . ./.env
            set +a

            cat > scripts/init-db.sql <<EOF
            CREATE USER keycloak WITH PASSWORD '$KC_DB_PASSWORD';
            CREATE DATABASE keycloak OWNER keycloak;

            CREATE USER netbird WITH PASSWORD '$NB_DB_PASSWORD';
            CREATE DATABASE netbird OWNER netbird;

            CREATE USER midpoint WITH PASSWORD '$MP_DB_PASSWORD';
            CREATE DATABASE midpoint OWNER midpoint;
            EOF

            chmod 600 .env scripts/init-db.sql
            echo "[gen] scripts/init-db.sql generated"
          '';
        };

        up = pkgs.writeShellApplication {
          name = "up";
          runtimeInputs = [ pkgs.docker pkgs.docker-compose ];
          text = ''
            set -euo pipefail
            ${self.packages.${system}.gen}/bin/gen
            docker compose up -d
            docker compose ps
          '';
        };

        down = pkgs.writeShellApplication {
          name = "down";
          runtimeInputs = [ pkgs.docker pkgs.docker-compose ];
          text = ''
            set -euo pipefail
            docker compose down
          '';
        };
      });

    apps = forAll (system: {
      gen = { type = "app"; program = "${self.packages.${system}.gen}/bin/gen"; };
      up  = { type = "app"; program = "${self.packages.${system}.up}/bin/up"; };
      down= { type = "app"; program = "${self.packages.${system}.down}/bin/down"; };
    });
  };
}

4) .env.example（最低限）
# Superuser for postgres (one time)
POSTGRES_SUPERPASS=change-me-super

# Hostnames (public)
KC_HOSTNAME=keycloak.example.com
NB_DOMAIN=netbird.example.com
NB_UI_DOMAIN=netbird-ui.example.com
MP_HOSTNAME=midpoint.example.com

# Keycloak
KC_ADMIN=admin
KC_ADMIN_PASSWORD=change-me-admin
KC_REALM=master   # まずは master でPoCでもOK。本番は専用realm推奨
KC_DB_PASSWORD=change-me-kcdb

# NetBird OIDC client in Keycloak
NB_OIDC_CLIENT_ID=netbird
NB_OIDC_CLIENT_SECRET=change-me-oidc

# DB passwords
NB_DB_PASSWORD=change-me-nbdb
MP_DB_PASSWORD=change-me-mpdb

5) Traefik 最小（TLS終端だけ）
traefik/traefik.yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic.yaml

api:
  dashboard: true

traefik/dynamic.yaml（自己署名でも/社内CAでも/LEでも差し替え可）
tls:
  options:
    default:
      minVersion: VersionTLS12
