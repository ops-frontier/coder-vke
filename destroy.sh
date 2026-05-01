#!/usr/bin/env bash
# destroy.sh - Coder on VKE 完全削除スクリプト
# すべてのリソースを安全な順序で削除する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
KUBECONFIG_PATH="${SCRIPT_DIR}/kubeconfig"
export KUBECONFIG="${KUBECONFIG_PATH}"

# ---- coder-auth.sh を読み込む (secrets.env の再利用・トークン自動取得) ----
# shellcheck source=coder-auth.sh
source "${SCRIPT_DIR}/coder-auth.sh"

# ---- 色付き出力 ----
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# ---- 確認プロンプト ----
echo -e "${RED}================================================================${NC}"
echo -e "${RED}  警告: このスクリプトはすべてのリソースを完全に削除します。${NC}"
echo -e "${RED}  VKE クラスター / PostgreSQL / VCR / DNS レコードが削除されます。${NC}"
echo -e "${RED}  ワークスペースのデータもすべて失われます。復元はできません。${NC}"
echo -e "${RED}================================================================${NC}"
echo ""
read -r -p "本当に削除しますか？ 'yes' と入力して Enter を押してください: " confirm
if [[ "${confirm}" != "yes" ]]; then
  echo "キャンセルしました。"
  exit 0
fi
echo ""

# ---- Step 1: Coder ワークスペースの停止 ----
# secrets.env からトークンを再利用する
echo "==> [1/7] Coder ワークスペースを停止..."
if [[ -n "${DOMAIN:-}" ]]; then
  _load_secrets
  export CODER_URL="https://coder.${DOMAIN}"
  if _token_valid 2>/dev/null; then
    echo "    secrets.env のトークンを使用します"
  elif [[ -n "${CODER_SESSION_TOKEN:-}" ]]; then
    echo "    環境変数の CODER_SESSION_TOKEN を使用します"
  else
    echo "    (有効なトークンがないためワークスペース停止をスキップ)"
  fi
fi
if [[ -n "${CODER_SESSION_TOKEN:-}" && -n "${DOMAIN:-}" ]]; then
  if command -v coder >/dev/null 2>&1; then
    coder login "https://coder.${DOMAIN}" --token "${CODER_SESSION_TOKEN}" 2>/dev/null || true
    # 全ユーザーのワークスペースを停止
    coder ls --all --output json 2>/dev/null \
      | jq -r '.[].name' 2>/dev/null \
      | while read -r ws; do
          echo "    停止: ${ws}"
          coder stop --yes "${ws}" 2>/dev/null || true
        done
    echo "    ワークスペース停止完了"
  else
    echo "    (coder CLI が見つからないためスキップ)"
  fi
else
  echo "    (CODER_SESSION_TOKEN / DOMAIN が未設定のためスキップ)"
fi

# ---- Step 2: PVC を削除 (Block Storage が孤立しないように) ----
# VKE を削除する前に CSI ドライバーが生きているうちに PVC を削除する
echo "==> [2/7] PVC を削除 (Block Storage の孤立防止)..."
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  # Coder ワークスペースの PVC
  if kubectl get namespace coder-workspaces >/dev/null 2>&1; then
    PVC_LIST=$(kubectl get pvc -n coder-workspaces -o name 2>/dev/null || true)
    if [[ -n "${PVC_LIST}" ]]; then
      echo "    削除する PVC:"
      echo "${PVC_LIST}" | sed 's/^/      /'
      kubectl delete pvc -n coder-workspaces --all --timeout=120s 2>/dev/null || true
      echo "    PVC 削除完了"
    else
      echo "    削除対象の PVC なし"
    fi
  fi

  # Coder 自身の PVC (あれば)
  if kubectl get namespace coder >/dev/null 2>&1; then
    kubectl delete pvc -n coder --all --timeout=60s 2>/dev/null || true
  fi
else
  echo -e "    ${YELLOW}kubeconfig が見つかりません。PVC 削除をスキップします。${NC}"
  echo -e "    ${YELLOW}Vultr コントロールパネルで Block Storage を確認・手動削除してください。${NC}"
fi

# ---- Step 3: ArgoCD でチャートをアンインストール ----
echo "==> [3/7] ArgoCD: coder-vke チャートをアンインストール..."
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  if kubectl get application coder-vke -n argocd >/dev/null 2>&1; then
    echo "    ArgoCD Application 'coder-vke' を削除します..."
    # cascade delete: ArgoCD が管理するすべてのリソースを削除する
    kubectl delete application coder-vke -n argocd --timeout=300s 2>/dev/null || true
    echo "    coder-vke Application 削除完了"

    # external-dns が DNS レコードを削除するのを待つ
    echo "    external-dns が DNS レコードを削除するのを待っています (30秒)..."
    sleep 30
  else
    echo "    ArgoCD Application 'coder-vke' が見つかりません。スキップします。"
  fi

  # ArgoCD 自体をアンインストール
  if helm status argocd -n argocd >/dev/null 2>&1; then
    echo "    ArgoCD をアンインストール..."
    helm uninstall argocd -n argocd --timeout 120s 2>/dev/null || true
    echo "    ArgoCD アンインストール完了"
  fi
else
  echo -e "    ${YELLOW}kubeconfig が見つかりません。ArgoCD 削除をスキップします。${NC}"
fi

# ---- Step 4: DigitalOcean DNS の A/TXT レコードを削除 ----
# external-dns が消し損ねたレコードを手動クリーンアップ (NS レコードは保持)
echo "==> [4/7] DigitalOcean DNS の A/TXT レコードを削除..."
if [[ -n "${DO_PAT:-}" && -n "${DOMAIN:-}" ]]; then
  # レコード一覧を取得 (最大200件)
  DNS_RECORDS=$(curl -s \
    "https://api.digitalocean.com/v2/domains/${DOMAIN}/records?per_page=200" \
    -H "Authorization: Bearer ${DO_PAT}" \
    -H "Content-Type: application/json" \
    | jq -c '.domain_records[] | select(.type == "A" or .type == "TXT") | {id: .id, type: .type, name: .name}' \
    2>/dev/null || true)

  if [[ -n "${DNS_RECORDS}" ]]; then
    echo "    削除対象レコード:"
    while IFS= read -r record; do
      REC_ID=$(echo "${record}" | jq -r '.id')
      REC_TYPE=$(echo "${record}" | jq -r '.type')
      REC_NAME=$(echo "${record}" | jq -r '.name')
      echo "      [${REC_TYPE}] ${REC_NAME} (id=${REC_ID})"
      curl -s -X DELETE \
        "https://api.digitalocean.com/v2/domains/${DOMAIN}/records/${REC_ID}" \
        -H "Authorization: Bearer ${DO_PAT}" >/dev/null || true
    done <<< "${DNS_RECORDS}"
    echo "    DNS レコード削除完了"
  else
    echo "    削除対象の A/TXT レコードなし"
  fi
else
  if [[ -z "${DO_PAT:-}" ]]; then
    echo -e "    ${YELLOW}DO_PAT が未設定のためスキップ。DigitalOcean DNS を手動確認してください。${NC}"
  else
    echo -e "    ${YELLOW}DOMAIN が未設定のためスキップ。${NC}"
  fi
fi

# ---- Step 5: VCR のイメージを削除 ----
# Vultr は VCR にイメージが残っていると削除エラーになる場合がある
echo "==> [5/7] VCR (Container Registry) のイメージを削除..."
if [[ -n "${VULTR_API_KEY:-}" ]]; then
  cd "${TERRAFORM_DIR}"
  if terraform output -raw vcr_id >/dev/null 2>&1; then
    VCR_ID=$(terraform output -raw vcr_id 2>/dev/null || true)
    if [[ -n "${VCR_ID}" ]]; then
      echo "    VCR ID: ${VCR_ID}"
      # リポジトリ一覧を取得して各リポジトリのタグをすべて削除
      REPOS=$(curl -s \
        "https://api.vultr.com/v2/registries/${VCR_ID}/repositories" \
        -H "Authorization: Bearer ${VULTR_API_KEY}" \
        | jq -r '.repositories[]?.name // empty' 2>/dev/null || true)
      if [[ -n "${REPOS}" ]]; then
        while IFS= read -r repo; do
          echo "    リポジトリ削除: ${repo}"
          curl -s -X DELETE \
            "https://api.vultr.com/v2/registries/${VCR_ID}/repositories/${repo}" \
            -H "Authorization: Bearer ${VULTR_API_KEY}" >/dev/null || true
        done <<< "${REPOS}"
      fi
      echo "    VCR イメージ削除完了"
    fi
  fi
  cd "${SCRIPT_DIR}"
else
  echo -e "    ${YELLOW}VULTR_API_KEY が未設定のためスキップ。${NC}"
  echo -e "    ${YELLOW}Vultr コントロールパネルで VCR のイメージを手動削除してください。${NC}"
fi

# ---- Step 6: Terraform destroy ----
echo "==> [6/7] Terraform destroy (VKE / PostgreSQL / VCR / VPC を削除)..."
cd "${TERRAFORM_DIR}"
if [[ -f "terraform.tfstate" ]]; then
  terraform destroy -auto-approve
  echo "    Terraform destroy 完了"
else
  echo -e "    ${YELLOW}terraform.tfstate が見つかりません。スキップします。${NC}"
fi
cd "${SCRIPT_DIR}"

# ---- Step 7: ローカルファイルのクリーンアップ ----
echo "==> [7/7] ローカルファイルのクリーンアップ..."
if [[ -f "${KUBECONFIG_PATH}" ]]; then
  rm -f "${KUBECONFIG_PATH}"
  echo "    kubeconfig を削除しました"
fi
# secrets.env は再デプロイ時に再利用できるため残す
if [[ -f "${_SECRETS_FILE}" ]]; then
  echo "    secrets.env は再デプロイのために残します (${_SECRETS_FILE})"
fi

echo ""
echo -e "${GREEN}==> 削除完了！${NC}"
echo ""
echo "NOTE: 以下は手動で確認・削除してください:"
echo "  - Vultr コントロールパネルで孤立した Block Storage がないか確認"
echo "  - DigitalOcean DNS で NS 以外のレコードが残っていないか念のため確認"
echo "  - GitHub OAuth アプリの Callback URL 設定は削除不要 (再デプロイ時に使い回し可)"
