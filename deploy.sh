#!/usr/bin/env bash
# deploy.sh - Coder on VKE フルデプロイスクリプト
# 環境変数が設定された Codespaces 環境で実行することを前提とする

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
HELM_DIR="${SCRIPT_DIR}/helm"
KUBECONFIG_PATH="${SCRIPT_DIR}/kubeconfig"

# ---- 必須環境変数チェック ----
required_vars=(
  VULTR_API_KEY
  DO_PAT
  DOMAIN
  GH_CLIENT_ID
  GH_CLIENT_SECRET
)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: 環境変数 ${var} が設定されていません。" >&2
    exit 1
  fi
done

# ---- デフォルト値 (Helm テンプレートで使用) ----
GH_ORGANIZATION="${GH_ORGANIZATION:-chip-in-v2}"
LE_ENVIRONMENT="${LE_ENVIRONMENT:-production}"

# ---- Step 1: Terraform ----
echo "==> [1/7] Terraform: VKE & PostgreSQL & Container Registry をプロビジョニング..."
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

# ---- Step 2: ingress-nginx ----
echo "==> [2/7] Helm: ingress-nginx をデプロイ..."
kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values "${HELM_DIR}/ingress-nginx/values.yaml" \
  --wait

# ---- Step 3: cert-manager ----
echo "==> [3/7] Helm: cert-manager をデプロイ..."
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --values "${HELM_DIR}/cert-manager/values.yaml" \
  --wait

# DigitalOcean Secret と ClusterIssuer を適用
DO_SECRET_FILE=$(mktemp)
sed "s|\${DO_PAT}|${DO_PAT}|g" \
  "${HELM_DIR}/cert-manager/templates/do-secret.yaml" > "${DO_SECRET_FILE}"
kubectl apply -f "${DO_SECRET_FILE}"
rm -f "${DO_SECRET_FILE}"

ISSUER_FILE=$(mktemp)
sed "s|\${DOMAIN}|${DOMAIN}|g; s|\${LE_ENVIRONMENT}|${LE_ENVIRONMENT}|g" \
  "${HELM_DIR}/cert-manager/templates/cluster-issuer.yaml" > "${ISSUER_FILE}"
kubectl apply -f "${ISSUER_FILE}"
rm -f "${ISSUER_FILE}"

# ---- Step 4: external-dns ----
echo "==> [4/7] Helm: external-dns をデプロイ..."
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -

DNS_SECRET_FILE=$(mktemp)
sed "s|\${DO_PAT}|${DO_PAT}|g" \
  "${HELM_DIR}/external-dns/templates/do-secret.yaml" > "${DNS_SECRET_FILE}"
kubectl apply -f "${DNS_SECRET_FILE}"
rm -f "${DNS_SECRET_FILE}"

helm repo add external-dns-official https://kubernetes-sigs.github.io/external-dns/
helm repo update external-dns-official
VALUES_FILE=$(mktemp)
sed "s|\${DOMAIN}|${DOMAIN}|g" \
  "${HELM_DIR}/external-dns/values.yaml" > "${VALUES_FILE}"
helm upgrade --install external-dns external-dns-official/external-dns \
  --namespace external-dns \
  --version 1.14.5 \
  --values "${VALUES_FILE}" \
  --wait
rm -f "${VALUES_FILE}"

# ---- Step 5: oauth2-proxy ----
echo "==> [5/7] Helm: oauth2-proxy をデプロイ..."
kubectl create namespace oauth2-proxy --dry-run=client -o yaml | kubectl apply -f -

# Cookie シークレット: 既存があれば再利用（デプロイのたびにセッションを無効にしない）
if kubectl get secret oauth2-proxy-credentials -n oauth2-proxy >/dev/null 2>&1; then
  OAUTH2_PROXY_COOKIE_SECRET=$(kubectl get secret oauth2-proxy-credentials \
    -n oauth2-proxy -o jsonpath='{.data.cookie-secret}' | base64 -d)
else
  OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -hex 16)
fi

OP_SECRET_FILE=$(mktemp)
sed "s|\${GH_CLIENT_ID}|${GH_CLIENT_ID}|g; \
     s|\${GH_CLIENT_SECRET}|${GH_CLIENT_SECRET}|g; \
     s|\${OAUTH2_PROXY_COOKIE_SECRET}|${OAUTH2_PROXY_COOKIE_SECRET}|g" \
  "${HELM_DIR}/oauth2-proxy/templates/secret.yaml" > "${OP_SECRET_FILE}"
kubectl apply -f "${OP_SECRET_FILE}"
rm -f "${OP_SECRET_FILE}"

helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests 2>/dev/null || true
helm repo update oauth2-proxy
OP_VALUES_FILE=$(mktemp)
sed "s|\${GH_ORGANIZATION}|${GH_ORGANIZATION}|g; \
     s|\${DOMAIN}|${DOMAIN}|g; \
     s|\${LE_ENVIRONMENT}|${LE_ENVIRONMENT}|g" \
  "${HELM_DIR}/oauth2-proxy/values.yaml" > "${OP_VALUES_FILE}"
helm upgrade --install oauth2-proxy oauth2-proxy/oauth2-proxy \
  --namespace oauth2-proxy \
  --values "${OP_VALUES_FILE}" \
  --wait
rm -f "${OP_VALUES_FILE}"

# ---- Step 6: Coder ----
echo "==> [6/7] Helm: Coder をデプロイ..."
kubectl create namespace coder --dry-run=client -o yaml | kubectl apply -f -

# DB URL Secret
kubectl create secret generic coder-db-url \
  --namespace coder \
  --from-literal=url="${DB_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -

# GitHub OAuth Secret
GH_SECRET_FILE=$(mktemp)
sed "s|\${GH_CLIENT_ID}|${GH_CLIENT_ID}|g; s|\${GH_CLIENT_SECRET}|${GH_CLIENT_SECRET}|g" \
  "${HELM_DIR}/coder/templates/github-oauth-secret.yaml" > "${GH_SECRET_FILE}"
kubectl apply -f "${GH_SECRET_FILE}"
rm -f "${GH_SECRET_FILE}"

helm repo add coder https://helm.coder.com/v2
helm repo update
CODER_VALUES_FILE=$(mktemp)
sed "s|\${DOMAIN}|${DOMAIN}|g; \
     s|\${GH_ORGANIZATION}|${GH_ORGANIZATION}|g; \
     s|\${LE_ENVIRONMENT}|${LE_ENVIRONMENT}|g" \
  "${HELM_DIR}/coder/values.yaml" > "${CODER_VALUES_FILE}"
helm upgrade --install coder coder/coder \
  --namespace coder \
  --values "${CODER_VALUES_FILE}" \
  --wait
rm -f "${CODER_VALUES_FILE}"

# coder-workspaces namespace と RBAC の作成
kubectl create namespace coder-workspaces --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<'RBAC_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: coder-workspace-manager
  namespace: coder-workspaces
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources:
      - pods
      - deployments
      - replicasets
      - services
      - ingresses
      - persistentvolumeclaims
      - secrets
      - configmaps
    verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
RBAC_EOF
kubectl apply -f - <<'RBAC_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: coder-workspace-manager
  namespace: coder-workspaces
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: coder-workspace-manager
subjects:
  - kind: ServiceAccount
    name: coder
    namespace: coder
RBAC_EOF

# ---- Step 7: ワークスペースイメージのビルド & Coder テンプレートのプッシュ ----
echo "==> [7/7] ワークスペースイメージをビルドして Coder テンプレートをプッシュ..."
# Vultr Container Registry docker-credentials を取得してログイン
VCR_CREDS=$(curl -sf \
  "https://api.vultr.com/v2/registries/${VCR_ID}/docker-credentials?expiry_seconds=0&read_write=true" \
  -H "Authorization: Bearer ${VULTR_API_KEY}")
VCR_AUTH=$(echo "${VCR_CREDS}" | grep -o '"auth":"[^"]*"' | cut -d'"' -f4)
if [[ -z "${VCR_AUTH}" ]]; then
  echo "ERROR: VCR 認証情報の取得に失敗しました" >&2
  exit 1
fi
VCR_USERNAME=$(echo "${VCR_AUTH}" | base64 -d | cut -d':' -f1)
VCR_PASSWORD=$(echo "${VCR_AUTH}" | base64 -d | cut -d':' -f2-)
echo "${VCR_PASSWORD}" | docker login "${VCR_REGION}.vultrcr.com" \
  --username "${VCR_USERNAME}" --password-stdin

# ワークスペースイメージをビルド & プッシュ
docker build -t "${VCR_IMAGE}" "${SCRIPT_DIR}/docker/workspace"
docker push "${VCR_IMAGE}"

# Coder CLI のインストール
if ! command -v coder >/dev/null 2>&1; then
  echo "Coder CLI をインストール中..."
  curl -fsSL "https://coder.${DOMAIN}/bin/coder-linux-amd64" -o /usr/local/bin/coder
  chmod +x /usr/local/bin/coder
fi

# Coder テンプレートのプッシュ (CODER_SESSION_TOKEN が設定されている場合)
if [[ -n "${CODER_SESSION_TOKEN:-}" ]]; then
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
else
  echo ""
  echo "NOTE: Coder テンプレートを登録するには CODER_SESSION_TOKEN を設定して再実行してください:"
  echo "  1. https://coder.${DOMAIN} にログインし、設定 > トークンでセッショントークンを作成"
  echo "  2. CODER_SESSION_TOKEN=<token> ./deploy.sh を実行"
fi

echo ""
echo "==> デプロイ完了!"
echo "    Coder URL   : https://coder.${DOMAIN}"
echo "    OAuth2 Proxy: https://auth.${DOMAIN}/oauth2"
echo ""
echo "NOTE: GitHub OAuth アプリの Callback URL に以下を追加してください:"
echo "      https://auth.${DOMAIN}/oauth2/callback"
