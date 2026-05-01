# Coder ワークスペース 利用者マニュアル

## 概要

このワークスペースは Kubernetes 上の Coder で動作しています。  
GitHub リポジトリを自動でクローンし、`.devcontainer/devcontainer.json` が存在する場合は  
devcontainer 環境をバックグラウンドでビルドして code-server のターミナルを devcontainer 内に切り替えます。

### レイヤー構造

```
Kubernetes Pod
├── workspace コンテナ (ubuntu)
│   ├── code-server (起動直後から利用可能)
│   └── devcontainer CLI
│
└── dind サイドカー (Docker デーモン)
    └── devcontainer コンテナ (ビルド完了後に利用可能)
        └── .devcontainer/devcontainer.json で定義したツール群
```

---

## ワークスペース作成時のパラメータ

| パラメータ | 説明 | 変更可否 |
|---|---|---|
| **GitHub リポジトリ名** | クローンするリポジトリ名 (`gh_organization` 配下) | 作成後変更不可 |
| **ディスクサイズ (GB)** | 永続ボリュームのサイズ (10〜100 GB) | 作成後変更不可 |

> リポジトリ名のみ指定すれば OK です。`https://github.com/<org>/<リポジトリ名>` がクローンされます。

---

## 起動フロー

1. **code-server が即時起動** → ブラウザでアクセスできる状態になる
2. **バックグラウンドで devcontainer ビルド開始** (`.devcontainer/devcontainer.json` がある場合)
3. **ビルド完了後、code-server が devcontainer 内に切り替わる**  
   → ターミナルが devcontainer 環境になり、定義されたツールが使用可能になる

ビルドには **3〜5 分**かかる場合があります。

---

## ビルドログの確認

ビルドログはリポジトリ内の `.devcontainer/build.log` に書き込まれます。  
code-server のエクスプローラーから直接開いて確認できます。

```
<リポジトリ名>/
└── .devcontainer/
    ├── devcontainer.json
    ├── build.log        ← ここにビルドログが出力される
    └── post-create.sh
```

起動スクリプト自体のログ (devcontainer の検出結果・切り替え完了など) は  
code-server のターミナルから確認できます:

```bash
cat /tmp/coder-startup-script.log
```

---

## devcontainer ビルドが失敗した場合

### 1. ビルドログを確認する

code-server のエクスプローラーで `.devcontainer/build.log` を開きます。  
エラー箇所は `ERROR:` や `exit code:` で検索してください。

### 2. devcontainer.json を修正する

code-server はビルド失敗時もホスト環境で動作し続けます。  
エクスプローラーから `.devcontainer/devcontainer.json` を直接編集できます。

### 3. 手動で再ビルドする

code-server のターミナルで以下を実行します:

```bash
# 既存の失敗したコンテナをクリーンアップ (任意)
docker rm -f $(docker ps -aq --filter label=devcontainer.local_folder=/workspace/$REPO_NAME) 2>/dev/null || true
docker buildx prune -f 2>/dev/null || true

# 再ビルド
devcontainer up --workspace-folder /workspace/$REPO_NAME --log-format json \
  | tee /workspace/$REPO_NAME/.devcontainer/build.log
```

> `~/bin/docker` ラッパー (MTU 修正済み) が `~/.bashrc` 経由で PATH に入っているため、  
> 手動実行でも K8s ネットワーク環境の MTU 問題は回避されます。

### 4. ビルド完了後に code-server を切り替える

再ビルドが成功したら、以下で code-server を devcontainer 内に切り替えます:

```bash
CONTAINER_ID=$(docker ps -q --filter label=devcontainer.local_folder=/workspace/$REPO_NAME | head -1)
echo $CONTAINER_ID > /tmp/devcontainer-id

# code-server を devcontainer 内にコピーして起動
docker cp /usr/lib/code-server "$CONTAINER_ID":/usr/lib/code-server

REMOTE_WORKSPACE=$(docker inspect "$CONTAINER_ID" \
  --format '{{index .Config.Labels "devcontainer.remote_workspace"}}' 2>/dev/null \
  || echo "/workspaces")

docker exec -d "$CONTAINER_ID" \
  /usr/lib/code-server/bin/code-server --bind-addr "0.0.0.0:8081" --auth none "$REMOTE_WORKSPACE"

CONTAINER_IP=$(docker inspect "$CONTAINER_ID" \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

pkill -f "code-server.*0\.0\.0\.0:8080" 2>/dev/null || true
sleep 1
socat TCP-LISTEN:8080,fork,reuseaddr TCP:$CONTAINER_IP:8081 >/tmp/socat.log 2>&1 &
echo "切り替え完了"
```

その後ブラウザをリロードするとターミナルが devcontainer 内になります。

---

## devcontainer を使わない場合

リポジトリに `.devcontainer/devcontainer.json` がない場合、  
code-server はホスト環境 (ubuntu) で動作し続けます。

ホスト環境でもよく使うツールは使用可能です:

| ツール | バージョン確認 |
|---|---|
| `git` | `git --version` |
| `gh` (GitHub CLI) | `gh --version` |
| `docker` (dind 経由) | `docker info` |
| `devcontainer` CLI | `devcontainer --version` |

---

## ワークスペースの停止・再開

- **停止**: Coder ダッシュボードから「Stop」→ Pod が削除され課金停止
- **再開**: Coder ダッシュボードから「Start」→ 永続ボリュームのデータは保持される
- **ディスクデータの保持対象**: `/workspace/<リポジトリ名>/` 以下のすべてのファイル

> `.devcontainer/build.log` も `/workspace/` 以下にあるため再開後も残ります。

---

## トラブルシューティング

| 症状 | 確認コマンド | 対処 |
|---|---|---|
| ブラウザが 502 | `cat /tmp/coder-startup-script.log` | code-server が起動中。1〜2 分待つ |
| devcontainer が切り替わらない | `.devcontainer/build.log` を確認 | 上記「ビルドが失敗した場合」を参照 |
| Docker コマンドが使えない | `docker info` | Docker デーモン (dind) の起動を待つ。`/tmp/coder-startup-script.log` を確認 |
| git push できない | `gh auth status` | GitHub External Auth を Coder ダッシュボードで再接続 |
