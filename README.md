# coder-vke
Coder service on Vultr K8s Engine

## インストール

Codespaces で開く前提となっています。ツール類のインストールは devcontainer.json により自動的に行われるので、 Codespaces で開けばインストールは不要です。

## アーキテクチャ

- Vultr の Kubernetes Engine 上に構築する
- 2台のワーカーノードでクラスタを構成する
- IngressController には k8s 公式の ingress-nginx を使用する
- external-dns で k8s のコントロールプレーンと連携し、 ingress-nginx が動作しているワーカーノードのグローバルIPを DigitalOcean DNS　に登録することで HA を実現する
- cert-manager は DigitalOcean DNS と連携して DNS-01 でサーバ証明書を Let's Encrypt から取得する
- OSS 版 Coder を動作させる。認証は Github OAuth と連携して SSO で実装する。

## 構築ツール

IaC のツールとしては、Terraform と Helm を使用する。Terraform で VKEをデプロイし、 Helm で Pod をデプロイする。

### 事前準備


#### DNS委任
サービスを公開するDNSのサブドメインを DigitalOcean DNS に委任する。具体的には NS レコードで ns1.digitalocean.com, ns2.digitalocean.com を指定する。

#### GIthub OAuthアプリ
GitHub OAuth アプリを2個登録しなければならない。

##### coder へのログイン用

アプリの ClinetID と Secret を環境変数 GH_CLIENT_ID と GH_CLIENT_SECRET に設定しなければならない。
**Callback URL** に以下を設定しなければならない。

```
https://coder.v2v.chip-in.net/api/v2/users/oauth2/github/callback
```

##### ワークスペースへのログイン用

アプリの ClinetID と Secret を環境変数 OAUTH2_PROXY_GH_CLIENT_ID と OAUTH2_PROXY_GH_CLIENT_SECRET に設定しなければならない。
**Callback URL** に以下を設定しなければならない。

```
https://auth.v2v.chip-in-v2.net/external-auth/github/callback
```

### パラメータ

パラメータはすべて Codespace の環境変数から取得する。以下にパラメータの一覧を示す。

|環境変数名|意味|例|デフォルト/必須|
|--|--|--|--|
|VULTR_API_KEY|Vultr API のキー|23DF..X14|必須|
|DO_PAT|DigitalOcean API の Personal Access Token|Dop..|必須|
|VULTR_LABEL_PREFIX|リソースのラベルのプリフィックス。この後ろに -vke-cluster をつけてクラスタのラベルとし、-vke-vpc をつけてVPCのラベルとする。|coder|coder|
|VULTR_REGION|Vultr の配置先リージョン。|nrt|nrt|
|VKE_NODE_PLAN|VKE のノードのプラン|vcpu-4-mem-8gb|vcpu-4-mem-8gb|
|VKE_HA_CONTROL_PLANE|VKEのHAを有効にするか否か。|enabled|enabled|
|VKE_ENABLE_FIREWALL|VKEの FireWall を有効にするか否か。|enabled|enabled|
|DOMAIN|DigitalOcean DNS に委譲されるドメイン|v2v.chip-in.net|必須|
|GH_ORGANIZATION|Github の組織のID |procube-open|chip-in-v2|
|GH_CLIENT_ID|Coderへのログイン用 Github ClientID||必須|
|GH_CLIENT_SECRET|Coderへのログイン用 Github Secret||必須|
|OAUTH2_PROXY_GH_CLIENT_ID|ワークスペースへのログイン用 Github ClientID||必須|
|OAUTH2_PROXY_GH_CLIENT_SECRET|ワークスペースへのログイン用 Github Secret||必須|
|LE_ENVIRONMENT|Let's Encrypt の環境 (production または staging)|staging|production|
|CODER_POSTGRESQL_SIZE|Coderが使用する PostgreSQL DB のサイズ(GB)|3|10|
|CODER_WORKSPACE_DEFAULT_SIZE|Coderがワークスペースを作成する際のデフォルトのサイズ(GB)|10|20|

なお、環境変数は CodeSpaces から設定できるようにするため、大文字でなければならない。terraform で利用する変数については TF_VAR_ で始まる環境変数に devcontainer.json の postCreateCommand で転記する。

### DNS

`${DOMAIN}` を DigitalOcean DNS に追加する

### ストレージ

各コンテナが必要とする永続領域については Vultr Block Storage をアロケートし、nomad の CSI プラグインでフォーマット（初回のみ）およびマウントを行う。

### データベース

terraform で Coder のデータベースとして Vultr の PostgreSQL マネージドサービスを `${CODER_POSTGRESQL_SIZE}`GB 確保します。

### アプリケーション

- Coder の認証は Github と OAuth で連携して行う
- Coder コンテナでは Github Codespaces と同様に使えるように以下のような Template を配置する
  - Coder が起動しているサーバとは関係なくすいているサーバでワークスペースコンテナを起動する
  - ワークスペースのディレクトリ用に Vultr File System (VFS)を要求されたサイズ（デフォルト 16GB）でアロケートする
  - k8s で動的に VFS をタスクにマウントする
  - ワークスペースコンテナでは OAuth 認証で取得した Github トークンで git clone を行う
  - リポジトリ内の .devcontainer/devcontainer.json がある場合はその内容に従って、ない場合はデフォルトの devcontainer を buildenv を使用してビルドする
  - devcontainer のビルドのログをユーザが参照できるようにする。
  - コンテナ内で VS Code Web を起動する
  -  OAuth 認証で取得した Github トークンは Git コマンドの Credential Helper としても保存する

#### coder テンプレート

デフォルトで以下のように　Codepsaces に準じたテンプレートが組み込まれる。

- パラメータとして、Github のリポジトリと環境変数のセットを指定する。
- Github のリポジトリは、 `${GH_ORGANIZATION}` の中の一つを選択できる
- ワークスペース用のディレクトリが Vultr File System にアロケートされる
- ワークスペースに指定されたリポジトリが git clone される
- リポジトリに .devcontainer/devcontainer がある場合は、それにしたがってコンテナがビルドされる
- リポジトリに .devcontainer/devcontainer がない場合は、デフォルトのコンテナがビルドされる
- "ws-"、ワークスペースの名前、 GitHub のユーザ名を結合してホスト名を作成し、その名前を external-dns 経由でDNS登録し、 cert-manager でサーバ証明書を取得し、 ingress-nginx 経由でワークスペースの Weu UI にアクセスできるようにする
- ワークスペースの Web UI には Github でログイン済みでかつユーザIDが一致しているものだけがアクセスできる



### ログ

サーバに保存されるログファイルには以下のものがある。
（未執筆）

#### フォレンジック

日時バッチにてテキストのログファイルを圧縮してオブジェクトストレージに保存する。
（未執筆）


## ファイル構成

### Terraform (terraform)
| ファイル | 内容 |
|---|---|
| providers.tf | Vultr プロバイダ設定 |
| variables.tf | README の全パラメータを変数定義 |
| vke.tf | VPC + VKE クラスタ (2ノード DaemonSet対応) + kubeconfig 出力 |
| database.tf | Vultr PostgreSQL マネージドDB |
| outputs.tf | DB接続情報等の出力 |

### Helm (helm)
| ファイル | 内容 |
|---|---|
| values.yaml | DaemonSet モード、SNI不一致拒否 (`ssl-reject-handshake: "true"`) |
| values.yaml | CRD自動インストール |
| cluster-issuer.yaml | ステージング/本番 ClusterIssuer (DNS-01/DigitalOcean) |
| values.yaml | DigitalOcean プロバイダ、Ingress の A レコード登録 |
| values.yaml | GitHub OAuth、PostgreSQL接続、TLS Ingress |

### デプロイ・Codespaces
| ファイル | 内容 |
|---|---|
| deploy.sh | 5ステップ一括デプロイスクリプト |
| devcontainer.json | terraform / kubectl / helm インストール |
| postCreate.sh | 大文字環境変数を `TF_VAR_` に転記 |

デプロイは Codespaces で環境変数を設定後、deploy.sh を実行するだけです。


## テンプレート対応

### 追加ファイル

| ファイル | 内容 |
|---|---|
| vcr.tf | Vultr Container Registry (ワークスペースイメージ格納) |
| Dockerfile | Ubuntu 24.04 + code-server + devcontainer CLI + docker CLI + socat |
| main.tf | Coder ワークスペーステンプレート |
| values.yaml | 中央 oauth2-proxy (GitHub 認証) |
| secret.yaml | oauth2-proxy 認証情報 Secret |

### 更新ファイル

| ファイル | 変更点 |
|---|---|
| outputs.tf | VCR ID・イメージ URL を出力追加 |
| values.yaml | GitHub 外部認証 (`repo` スコープ) を追加 |
| devcontainer.json | `docker-outside-of-docker` feature を追加 |
| deploy.sh | ステップ 5〜7 を追加 |


### アーキテクチャ

```
ユーザー → ws-{name}-{user}.{domain}
  └─ ingress-nginx (auth-url 検証)
       └─ oauth2-proxy (auth.{domain}) → GitHub OAuth
            └─ 本人確認 (nginx configuration-snippet)
                 └─ code-server :8080 (workspace Pod)
                      ├─ DinD サイドカー → devcontainer ビルド
                      └─ socat → devcontainer 内 code-server
```

##　構築手順

```
./deploy.sh
```

構築後 [Coder ワークスペース 利用者マニュアル](./WORKSPACE.md) に従ってワークスペースを起動できる。

## 破棄手順