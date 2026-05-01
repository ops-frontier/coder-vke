#!/usr/bin/env bash
# deploy.sh - Coder on VKE フルデプロイスクリプト
# 環境変数が設定された Codespaces 環境で実行することを前提とする

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
KUBECONFIG_PATH="${SCRIPT_DIR}/kubeconfig"

# ---- coder-auth.sh を読み込む (secrets.env の再利用・トークン自動取得) ----
# shellcheck source=coder-auth.sh
source "${SCRIPT_DIR}/coder-auth.sh"

# ---- 必須環境変数チェック ----
required_vars=(
  VULTR_API_KEY
  DO_PAT
  DOMAIN
  GH_CLIENT_ID
  GH_CLIENT_SECRET
  GH_EXT_CLIENT_ID
  GH_EXT_CLIENT_SECRET
  OAUTH2_PROXY_GH_CLIENT_ID
  OAUTH2_PROXY_GH_CLIENT_SECRET
)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: 環境変数 ${var} が設定されていません。" >&2
    exit 1
  fi
done

# ---- デフォルト値 (Helm テンプレートで使用) ----
GH_ORGANIZATION="${GH_ORGANIZATION:-ops-frontier}"
LE_ENVIRONMENT="${LE_ENVIRONMENT:-production}"

# ---- Step 1: Terraform ----
echo "==> [1/5] Terraform: VKE & PostgreSQL & Container Registry をプロビジョニング..."
cd "${TERRAFORM_DIR}"
terraform init -input=false

terraform apply -input=false -auto-approve

export KUBECONFIG="${KUBECONFIG_PATH}"

# PostgreSQL 接続情報を取得
DB_HOST=$(terraform output -raw database_host)
DB_PORT=$(terraform output -raw database_port)
DB_USER=$(terraform output -raw database_user)
DB_PASS=$(terraform output -raw database_password)
DB_NAME=$(terraform output -raw database_name)
DB_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"

# VCR 情報を取得
VCR_ID=$(terraform output -raw vcr_id)
VCR_IMAGE_BASE=$(terraform output -raw vcr_image)
VCR_IMAGE="${VCR_IMAGE_BASE}:latest"
VCR_REGION="${VULTR_REGION:-nrt}"

cd "${SCRIPT_DIR}"

# ---- Step 2: ArgoCD ----
echo "==> [2/5] Helm: ArgoCD をインストール..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --wait

# ---- Step 3: K8s ネームスペースとシークレットを作成 ----
echo "==> [3/5] K8s ネームスペースとシークレットを作成..."

# ネームスペースの作成
for ns in cert-manager external-dns oauth2-proxy coder coder-workspaces; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

# cert-manager: DigitalOcean API トークン
kubectl create secret generic digitalocean-token \
  --namespace cert-manager \
  --from-literal=access-token="${DO_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -

# external-dns: DigitalOcean API トークン
kubectl create secret generic digitalocean-token \
  --namespace external-dns \
  --from-literal=access-token="${DO_PAT}" \
  --dry-run=client -o yaml | kubectl apply -f -

# oauth2-proxy: Cookie シークレット (secrets.env → K8s Secret → 新規生成 の順で取得)
if [[ -z "${OAUTH2_PROXY_COOKIE_SECRET:-}" ]]; then
  if kubectl get secret oauth2-proxy-credentials -n oauth2-proxy >/dev/null 2>&1; then
    OAUTH2_PROXY_COOKIE_SECRET=$(kubectl get secret oauth2-proxy-credentials \
      -n oauth2-proxy -o jsonpath='{.data.cookie-secret}' | base64 -d)
  else
    OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -hex 16)
  fi
  _save_secret "OAUTH2_PROXY_COOKIE_SECRET" "${OAUTH2_PROXY_COOKIE_SECRET}"
fi
kubectl create secret generic oauth2-proxy-credentials \
  --namespace oauth2-proxy \
  --from-literal=client-id="${OAUTH2_PROXY_GH_CLIENT_ID}" \
  --from-literal=client-secret="${OAUTH2_PROXY_GH_CLIENT_SECRET}" \
  --from-literal=cookie-secret="${OAUTH2_PROXY_COOKIE_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# coder: DB URL
kubectl create secret generic coder-db-url \
  --namespace coder \
  --from-literal=url="${DB_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

# coder: GitHub OAuth (ログイン用)
kubectl create secret generic coder-github-oauth \
  --namespace coder \
  --from-literal=client-id="${GH_CLIENT_ID}" \
  --from-literal=client-secret="${GH_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# coder: GitHub External Auth (テンプレート git clone 用・別 OAuth App)
kubectl create secret generic coder-github-external-auth \
  --namespace coder \
  --from-literal=client-id="${GH_EXT_CLIENT_ID}" \
  --from-literal=client-secret="${GH_EXT_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---- Step 4: ArgoCD Application (coder-vke) をデプロイ ----
echo "==> [4/5] ArgoCD: coder-vke チャートをデプロイ..."

# Git リモート URL を取得 (SSH → HTTPS に変換)
REPO_URL=$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || echo "")
if [[ -z "${REPO_URL}" ]]; then
  echo "ERROR: Git リモート URL を取得できませんでした。" >&2
  exit 1
fi
REPO_URL=$(echo "${REPO_URL}" | sed 's|git@github\.com:|https://github.com/|')

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coder-vke
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: HEAD
    path: helm/coder-vke
    helm:
      parameters:
        - name: domain
          value: "${DOMAIN}"
        - name: ghOrganization
          value: "${GH_ORGANIZATION}"
        - name: leEnvironment
          value: "${LE_ENVIRONMENT}"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo "    ArgoCD Application 'coder-vke' を作成しました"
echo "    ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"

# ---- ArgoCD 同期完了 & DNS 解決待ち ----
echo "==> ArgoCD の同期完了を待機中..."

# ArgoCD CLI がなければ kubectl で Application の Health/Sync 状態をポーリングする
_wait_argocd_synced() {
  local app="$1" timeout_sec="${2:-600}" interval=15 elapsed=0
  while (( elapsed < timeout_sec )); do
    local sync health
    sync=$(kubectl get application "${app}" -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    health=$(kubectl get application "${app}" -n argocd \
      -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    echo "    [ArgoCD] ${app}: sync=${sync} health=${health}"
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
      echo "    ArgoCD Application '${app}' が Synced/Healthy になりました"
      return 0
    fi
    sleep "${interval}"
    (( elapsed += interval ))
  done
  echo "WARNING: ArgoCD Application '${app}' がタイムアウト前に Synced/Healthy になりませんでした。" >&2
  return 1
}

_wait_argocd_synced coder-vke 600 || true

# ingress-nginx LoadBalancer の外部 IP が付与されるまで待機
echo "==> ingress-nginx の LoadBalancer IP を待機中..."
LB_IP=""
for i in $(seq 1 40); do
  LB_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${LB_IP}" ]]; then
    echo "    LoadBalancer IP: ${LB_IP}"
    break
  fi
  printf "."
  sleep 15
done
echo ""
if [[ -z "${LB_IP}" ]]; then
  echo "WARNING: ingress-nginx の LoadBalancer IP が取得できませんでした。DNS 登録を確認してください。" >&2
fi

# coder.${DOMAIN} の DNS 解決が成功するまで待機 (最大 10 分)
echo "==> coder.${DOMAIN} の DNS 解決を待機中..."
for i in $(seq 1 40); do
  if host "coder.${DOMAIN}" >/dev/null 2>&1; then
    echo "    DNS 解決成功: coder.${DOMAIN}"
    break
  fi
  printf "."
  sleep 15
done
echo ""

# ---- Step 5: ワークスペースイメージのビルド & Coder テンプレートのプッシュ ----
echo "==> [5/5] ワークスペースイメージをビルドして Coder テンプレートをプッシュ..."

# Vultr Container Registry docker-credentials を取得してログイン
VCR_CREDS=$(curl -s \
  "https://api.vultr.com/v2/registry/${VCR_ID}/docker-credentials?expiry_seconds=0&read_write=true" \
  -H "Authorization: Bearer ${VULTR_API_KEY}" -X OPTIONS)

VCR_AUTH=$(echo "${VCR_CREDS}" | jq -r ".auths.\"${VCR_REGION}.vultrcr.com\".auth")
if [[ "${VCR_AUTH}" == "null" ]]; then
  echo "ERROR: VCR 認証情報の解析に失敗しました ${VCR_CREDS}" >&2
  # exit 1
fi
VCR_USERNAME=$(echo "${VCR_AUTH}" | base64 -d | cut -d':' -f1)
VCR_PASSWORD=$(echo "${VCR_AUTH}" | base64 -d | cut -d':' -f2-)
echo "${VCR_PASSWORD}" | docker login "${VCR_REGION}.vultrcr.com" \
  --username "${VCR_USERNAME}" --password-stdin

# ワークスペースイメージをビルド & プッシュ
docker build -t "${VCR_IMAGE}" "${SCRIPT_DIR}/docker/workspace"
docker push "${VCR_IMAGE}"

TARGET_DIR="/usr/local/share/ca-certificates/letsencrypt-staging"
if [[ "${LE_ENVIRONMENT}" == "staging" && ! -f "$TARGET_DIR/le-stg-root-x1.crt" ]]; then
  echo "Installing Let's Encrypt Staging certificates..."

  # 1. 保存先ディレクトリの作成
  sudo mkdir -p "$TARGET_DIR"

  # 2. 証明書のダウンロード (Staging Root X1 と Intermediate R3)
  # 注: URLは最新の状態を公式サイトで確認することをお勧めします
  sudo curl -s https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem -o "$TARGET_DIR/le-stg-root-x1.crt"
  sudo curl -s https://letsencrypt.org/certs/staging/letsencrypt-stg-int-r3.pem -o "$TARGET_DIR/le-stg-int-r3.crt"

  # 3. パーミッションの設定
  sudo chmod 644 "$TARGET_DIR"/*.crt

  # 4. システムのトラストストアを更新
  sudo update-ca-certificates

  echo "Done. Staging certificates are now trusted."
fi

# Coder CLI のインストール
if ! command -v coder >/dev/null 2>&1; then
  echo "Coder CLI をインストール中..."
  sudo curl -fsSL "https://coder.${DOMAIN}/bin/coder-linux-amd64" -o /usr/local/bin/coder
  sudo chmod +x /usr/local/bin/coder
fi

# Coder トークンを取得 (初回は管理者ユーザーを作成してトークンを保存)
echo "==> Coder セッショントークンを確認..."
ensure_coder_token

coder login "https://coder.${DOMAIN}" --token "${CODER_SESSION_TOKEN}"
coder templates push workspace \
    --directory "${SCRIPT_DIR}/coder-template" \
    --activate \
    --yes \
    --variable domain="${DOMAIN}" \
    --variable gh_organization="${GH_ORGANIZATION}" \
    --variable workspace_image="${VCR_IMAGE}" \
    --variable namespace="coder-workspaces" \
    --variable cluster_issuer="letsencrypt-${LE_ENVIRONMENT}"
echo "    テンプレート 'workspace' をプッシュしました"

echo ""
echo "==> デプロイ完了!"
echo "    Coder URL   : https://coder.${DOMAIN}"
echo "    OAuth2 Proxy: https://auth.${DOMAIN}/oauth2"
echo ""
echo "    ArgoCD UI にアクセスする場合:"
echo "      kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "      ブラウザで https://localhost:8080 にアクセス"
echo ""
echo "NOTE: GitHub OAuth アプリの Callback URL に以下を追加してください:"
echo "      https://auth.${DOMAIN}/oauth2/callback"
