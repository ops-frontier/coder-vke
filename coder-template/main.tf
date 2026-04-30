terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

# Coder が K8s 上で動作しているため in-cluster 設定を使用
provider "kubernetes" {}

# ---- Coder データソース ----
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# GitHub 外部認証 (repo スコープの git clone に必要)
data "coder_external_auth" "github" {
  id = "github"
}

# ---- テンプレート変数 ----
variable "domain" {
  description = "ワークスペース URL のベースドメイン"
  type        = string
}

variable "gh_organization" {
  description = "リポジトリを選択する GitHub 組織"
  type        = string
}

variable "workspace_image" {
  description = "ワークスペースコンテナイメージ (registry/image:tag)"
  type        = string
}

variable "namespace" {
  description = "ワークスペース Pod を作成する Kubernetes namespace"
  type        = string
  default     = "coder-workspaces"
}

variable "cluster_issuer" {
  description = "TLS 証明書発行に使用する cert-manager ClusterIssuer 名"
  type        = string
  default     = "letsencrypt-production"
}

# ---- ユーザーパラメータ ----
data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "GitHub リポジトリ名"
  description  = "${var.gh_organization} 内のリポジトリ名を入力してください (例: my-app)"
  type         = "string"
  mutable      = false
  order        = 1
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "ディスクサイズ (GB)"
  description  = "ワークスペース用の永続ディスクサイズ"
  type         = "number"
  default      = "20"
  mutable      = false
  order        = 2

  validation {
    min = 10
    max = 100
  }
}

# ---- ローカル変数 ----
locals {
  workspace_name = data.coder_workspace.me.name
  owner_name     = data.coder_workspace_owner.me.name
  hostname       = "ws-${local.workspace_name}-${local.owner_name}.${var.domain}"
}

# ---- Coder エージェント ----
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  env = {
    GITHUB_TOKEN = data.coder_external_auth.github.access_token
    GH_ORG       = var.gh_organization
    REPO_NAME    = data.coder_parameter.git_repo.value
    OWNER_NAME   = local.owner_name
    OWNER_EMAIL  = data.coder_workspace_owner.me.email
    DOCKER_HOST  = "unix:///var/run/docker.sock"
  }

  # エージェント起動後に実行されるスクリプト
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -eo pipefail

    # ---- git 認証設定 ----
    git config --global credential.helper store
    printf "https://oauth2:%s@github.com\n" "$GITHUB_TOKEN" > ~/.git-credentials
    chmod 600 ~/.git-credentials
    git config --global user.name "$OWNER_NAME"
    git config --global user.email "$OWNER_EMAIL"
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true

    # ---- リポジトリをクローン ----
    REPO_DIR="/workspace/$REPO_NAME"
    if [ ! -d "$REPO_DIR/.git" ]; then
      git clone "https://github.com/$GH_ORG/$REPO_NAME" "$REPO_DIR"
    fi

    # ---- Docker デーモン (DinD) 待機 ----
    CODE_SERVER_PORT=8080
    if timeout 30 sh -c 'until docker info >/dev/null 2>&1; do sleep 2; done'; then
      DOCKER_OK=true
    else
      DOCKER_OK=false
      echo "警告: Docker デーモンに接続できません。devcontainer は使用できません。"
    fi

    # ---- devcontainer.json が存在する場合は devcontainer を使用 ----
    if [ "$DOCKER_OK" = "true" ] && [ -f "$REPO_DIR/.devcontainer/devcontainer.json" ]; then
      echo "==> devcontainer.json を検出。devcontainer を起動します..."

      DEVCONTAINER_OUT=$(devcontainer up \
        --workspace-folder "$REPO_DIR" \
        --log-format json 2>&1 || true)
      CONTAINER_ID=$(echo "$DEVCONTAINER_OUT" \
        | grep '"containerId"' \
        | grep -o '"containerId":[[:space:]]*"[^"]*"' \
        | cut -d'"' -f4 \
        | tail -1)

      if [ -n "$CONTAINER_ID" ]; then
        # devcontainer 内に code-server をインストールして起動
        docker exec "$CONTAINER_ID" sh -c \
          'command -v code-server >/dev/null 2>&1 \
            || curl -fsSL https://code-server.dev/install.sh | sh >/dev/null 2>&1'
        docker exec -d "$CONTAINER_ID" \
          code-server --bind-addr "0.0.0.0:$CODE_SERVER_PORT" --auth none /workspace

        # devcontainer の内部 IP を取得して socat でポートフォワード
        CONTAINER_IP=$(docker inspect \
          -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
          "$CONTAINER_ID")
        socat "TCP-LISTEN:$CODE_SERVER_PORT,fork,reuseaddr" \
              "TCP:$CONTAINER_IP:$CODE_SERVER_PORT" &
        echo "==> devcontainer 内の code-server をポート $CODE_SERVER_PORT で公開しました"
      else
        echo "==> devcontainer の起動に失敗。直接 code-server を起動します..."
        code-server --bind-addr "0.0.0.0:$CODE_SERVER_PORT" --auth none "$REPO_DIR" &
      fi
    else
      # devcontainer なし: code-server を直接起動
      code-server --bind-addr "0.0.0.0:$CODE_SERVER_PORT" --auth none "$REPO_DIR" &
    fi

    echo "==> ワークスペース準備完了: https://${local.hostname}"
  EOT

  metadata {
    display_name = "CPU 使用率"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "メモリ使用率"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# code-server へのリンク (Coder ダッシュボードから開く)
resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "https://${local.hostname}"
  external     = true
  share        = "owner"
}

# ---- Kubernetes リソース ----

# 永続ボリューム (停止しても保持)
resource "kubernetes_persistent_volume_claim" "workspace" {
  metadata {
    name      = "ws-${local.workspace_name}-${local.owner_name}"
    namespace = var.namespace
    labels = {
      "coder.workspace.name"  = local.workspace_name
      "coder.workspace.owner" = local.owner_name
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.disk_size.value}Gi"
      }
    }
  }

  wait_until_bound = false
}

# ワークスペース Deployment (起動中のみ作成)
resource "kubernetes_deployment" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "ws-${local.workspace_name}-${local.owner_name}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"  = "coder-workspace"
      "coder.workspace.name"    = local.workspace_name
      "coder.workspace.owner"   = local.owner_name
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "coder.workspace.name"  = local.workspace_name
        "coder.workspace.owner" = local.owner_name
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"  = "coder-workspace"
          "coder.workspace.name"    = local.workspace_name
          "coder.workspace.owner"   = local.owner_name
        }
      }

      spec {
        # セキュリティコンテキスト: coder ユーザ (UID 1000) で実行
        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }

        # ---- ワークスペースコンテナ ----
        container {
          name  = "workspace"
          image = var.workspace_image

          # Coder エージェントをダウンロードして起動
          command = ["sh", "-c"]
          args = [
            <<-EOT
              set -e
              curl -fsSL "${data.coder_workspace.me.access_url}/bin/coder-linux-amd64" \
                -o /usr/local/bin/coder-agent
              chmod +x /usr/local/bin/coder-agent
              exec /usr/local/bin/coder-agent agent --auth token
            EOT
          ]

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          env {
            name  = "DOCKER_HOST"
            value = "unix:///var/run/docker.sock"
          }
          env {
            name  = "GITHUB_TOKEN"
            value = data.coder_external_auth.github.access_token
          }
          env {
            name  = "GH_ORG"
            value = var.gh_organization
          }
          env {
            name  = "REPO_NAME"
            value = data.coder_parameter.git_repo.value
          }
          env {
            name  = "OWNER_NAME"
            value = local.owner_name
          }
          env {
            name  = "OWNER_EMAIL"
            value = data.coder_workspace_owner.me.email
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "4"
              memory = "8Gi"
            }
          }

          volume_mount {
            name       = "workspace-data"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "docker-sock"
            mount_path = "/var/run"
          }
        }

        # ---- Docker-in-Docker サイドカー (devcontainer ビルド用) ----
        container {
          name  = "dind"
          image = "docker:27-dind"

          security_context {
            privileged = true
          }

          env {
            name  = "DOCKER_TLS_CERTDIR"
            value = ""
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "2"
              memory = "4Gi"
            }
          }

          volume_mount {
            name       = "workspace-data"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "docker-sock"
            mount_path = "/var/run"
          }
          volume_mount {
            name       = "docker-storage"
            mount_path = "/var/lib/docker"
          }
        }

        volume {
          name = "workspace-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.workspace.metadata[0].name
          }
        }
        volume {
          name = "docker-sock"
          empty_dir {}
        }
        volume {
          name = "docker-storage"
          empty_dir {}
        }
      }
    }
  }

  # 停止→起動の際にロールアウトを待たない
  wait_for_rollout = false
}

# Service (Ingress からルーティング)
resource "kubernetes_service" "workspace" {
  metadata {
    name      = "ws-${local.workspace_name}-${local.owner_name}"
    namespace = var.namespace
  }

  spec {
    selector = {
      "coder.workspace.name"  = local.workspace_name
      "coder.workspace.owner" = local.owner_name
    }
    port {
      name        = "code-server"
      port        = 8080
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# Ingress: ws-{name}-{user}.{domain} で code-server を公開
# oauth2-proxy (auth.{domain}) で GitHub 認証 + 本人確認を行う
resource "kubernetes_ingress_v1" "workspace" {
  metadata {
    name      = "ws-${local.workspace_name}-${local.owner_name}"
    namespace = var.namespace

    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer

      # oauth2-proxy による認証
      "nginx.ingress.kubernetes.io/auth-url" = (
        "https://auth.${var.domain}/oauth2/auth"
      )
      "nginx.ingress.kubernetes.io/auth-signin" = (
        "https://auth.${var.domain}/oauth2/start?rd=$escaped_request_uri"
      )
      "nginx.ingress.kubernetes.io/auth-response-headers" = "X-Auth-Request-User"

      # ワークスペースオーナーのみアクセス許可
      "nginx.ingress.kubernetes.io/configuration-snippet" = (
        "if ($http_x_auth_request_user != \"${local.owner_name}\") {\n  return 403;\n}\n"
      )
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = [local.hostname]
      secret_name = "ws-${local.workspace_name}-${local.owner_name}-tls"
    }

    rule {
      host = local.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.workspace.metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}
