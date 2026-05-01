#!/usr/bin/env bash
# coder-auth.sh - Coder セッショントークンの取得・保存・再利用
#
# 使い方: deploy.sh / destroy.sh から source する
#   source "$(dirname "${BASH_SOURCE[0]}")/coder-auth.sh"
#   ensure_coder_token  # CODER_SESSION_TOKEN と CODER_URL がセットされる
#
# 必要な環境変数 (呼び出し前にセット済みであること):
#   DOMAIN   例: poc.ops-frontier.dev

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SECRETS_FILE="${_SCRIPT_DIR}/secrets.env"

# secrets.env を読み込む (存在する場合)
_load_secrets() {
  if [[ -f "${_SECRETS_FILE}" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${_SECRETS_FILE}"
    set +a
  fi
}

# secrets.env に KEY=VALUE を書き込む (既存のキーは上書き)
_save_secret() {
  local key="$1" value="$2"
  touch "${_SECRETS_FILE}"
  chmod 600 "${_SECRETS_FILE}"
  # 既存行を削除してから追記
  grep -v "^${key}=" "${_SECRETS_FILE}" > "${_SECRETS_FILE}.tmp" || true
  echo "${key}=${value}" >> "${_SECRETS_FILE}.tmp"
  mv "${_SECRETS_FILE}.tmp" "${_SECRETS_FILE}"
}

# Coder API を呼び出して JSON レスポンスを返す
_coder_api() {
  local method="$1" path="$2" body="${3:-}"
  local url="${CODER_URL}/api/v2${path}"
  if [[ -n "${body}" ]]; then
    curl -fsSL -X "${method}" "${url}" \
      -H "Content-Type: application/json" \
      ${CODER_SESSION_TOKEN:+-H "Coder-Session-Token: ${CODER_SESSION_TOKEN}"} \
      -d "${body}"
  else
    curl -fsSL -X "${method}" "${url}" \
      ${CODER_SESSION_TOKEN:+-H "Coder-Session-Token: ${CODER_SESSION_TOKEN}"}
  fi
}

# 保存済みトークンが有効か確認する
_token_valid() {
  [[ -n "${CODER_SESSION_TOKEN:-}" ]] || return 1
  local status
  status=$(curl -o /dev/null -s -w "%{http_code}" \
    -H "Coder-Session-Token: ${CODER_SESSION_TOKEN}" \
    "${CODER_URL}/api/v2/users/me")
  [[ "${status}" == "200" ]]
}

# Coder が起動するまで待機する
_wait_for_coder() {
  echo "    Coder の起動を待っています..."
  local i
  for i in $(seq 1 40); do
    local status
    status=$(curl -o /dev/null -s -w "%{http_code}" "${CODER_URL}/api/v2/buildinfo" || true)
    if [[ "${status}" == "200" ]]; then
      echo "    Coder が起動しました"
      return 0
    fi
    printf "."
    sleep 15
  done
  echo ""
  echo "ERROR: Coder の起動タイムアウト (${CODER_URL})" >&2
  return 1
}

# 初回管理者ユーザーを作成してトークンを取得する
_setup_first_user() {
  # 管理者メールとパスワードを生成 (未設定時)
  if [[ -z "${CODER_ADMIN_EMAIL:-}" ]]; then
    CODER_ADMIN_EMAIL="admin@${DOMAIN}"
  fi
  if [[ -z "${CODER_ADMIN_PASSWORD:-}" ]]; then
    CODER_ADMIN_PASSWORD="$(openssl rand -base64 24)"
    _save_secret "CODER_ADMIN_EMAIL" "${CODER_ADMIN_EMAIL}"
    _save_secret "CODER_ADMIN_PASSWORD" "${CODER_ADMIN_PASSWORD}"
    echo "    初期管理者パスワードを生成して secrets.env に保存しました"
  fi

  echo "    初回管理者ユーザーを作成: ${CODER_ADMIN_EMAIL}"
  local response
  response=$(_coder_api POST "/users/first" \
    "{\"email\":\"${CODER_ADMIN_EMAIL}\",\"username\":\"admin\",\"name\":\"Admin\",\"password\":\"${CODER_ADMIN_PASSWORD}\",\"trial\":false}" \
    2>&1) || true

  # 既にユーザーが存在している場合 (409) はログインにフォールバック
  if echo "${response}" | grep -q '"code":"conflict"'; then
    echo "    管理者ユーザーは既に存在します。ログインします..."
    _login_and_save_token
    return
  fi

  # 作成成功: ログインしてトークンを取得
  _login_and_save_token
}

# メール/パスワードでログインしてトークンを保存する
_login_and_save_token() {
  echo "    Coder にログイン中: ${CODER_ADMIN_EMAIL}"
  local response
  response=$(_coder_api POST "/users/login" \
    "{\"email\":\"${CODER_ADMIN_EMAIL}\",\"password\":\"${CODER_ADMIN_PASSWORD}\"}") || {
    echo "ERROR: Coder ログインに失敗しました。CODER_ADMIN_EMAIL / CODER_ADMIN_PASSWORD を確認してください。" >&2
    return 1
  }

  local token
  token=$(echo "${response}" | jq -r '.session_token // empty')
  if [[ -z "${token}" ]]; then
    echo "ERROR: セッショントークンの取得に失敗しました: ${response}" >&2
    return 1
  fi

  CODER_SESSION_TOKEN="${token}"
  _save_secret "CODER_SESSION_TOKEN" "${CODER_SESSION_TOKEN}"
  echo "    セッショントークンを secrets.env に保存しました"
}

# 公開関数: CODER_SESSION_TOKEN を確保する (有効なトークンがあれば再利用)
ensure_coder_token() {
  if [[ -z "${DOMAIN:-}" ]]; then
    echo "ERROR: DOMAIN が設定されていません" >&2
    return 1
  fi

  export CODER_URL="https://coder.${DOMAIN}"

  # secrets.env から既存の値を読む
  _load_secrets

  # 保存済みトークンが有効ならそのまま使う
  if _token_valid; then
    echo "    既存の Coder セッショントークンを使用します"
    export CODER_SESSION_TOKEN
    return 0
  fi

  # Coder が起動するまで待機
  _wait_for_coder

  # CODER_ADMIN_EMAIL / PASSWORD がある場合はログインを試みる
  if [[ -n "${CODER_ADMIN_EMAIL:-}" && -n "${CODER_ADMIN_PASSWORD:-}" ]]; then
    echo "    保存済み認証情報でログインを試みます..."
    _login_and_save_token && export CODER_SESSION_TOKEN && return 0 || true
  fi

  # ユーザーがいない (初回) → 管理者を作成
  local user_count
  user_count=$(curl -fsSL "${CODER_URL}/api/v2/users?limit=1" \
    2>/dev/null | jq '.count // 0' 2>/dev/null || echo "0")

  if [[ "${user_count}" == "0" ]]; then
    _setup_first_user
  else
    echo "ERROR: Coder にユーザーが存在しますが、有効なトークンがありません。" >&2
    echo "       secrets.env に CODER_ADMIN_EMAIL と CODER_ADMIN_PASSWORD を手動で設定してください。" >&2
    return 1
  fi

  export CODER_SESSION_TOKEN
}
