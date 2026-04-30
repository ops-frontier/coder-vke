# cert-manager

cert-manager は以下のように ingress-nginx とサーバ証明書を共有します。

## 1. 共有の仕組み（4つのステップ）
具体的には以下の流れで証明書が受け渡されます。

**リクエストの発行**:
利用者が Ingress リソースに「このドメインの証明書を my-tls-secret という名前の Secret に保存してほしい」と記述します。

**証明書の取得 (cert-manager)**:
cert-manager がその記述を検知し、Let's Encrypt 等から証明書を発行してもらいます。

**Secret への書き込み**:
発行された証明書（公開鍵と秘密鍵）を、cert-manager が指定された名前（my-tls-secret）の Kubernetes Secret として作成（または更新）します。

**証明書の読み込み (ingress-nginx)**:
ingress-nginx は常にその Secret を監視しています。Secret が作成・更新されると、即座に中身を読み込んでメモリ上の Nginx 設定に反映します。

## 2. マニフェストでの具体的な記述例
この連携を動かすための設定は、Ingress リソースの tls: セクションに集約されます。

```YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    # どのIssuer(認証局設定)を使うかcert-managerに伝える
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - app.example.com
    # ★ここが重要！cert-managerの書き込み先 兼 ingress-nginxの読み取り先
    secretName: my-tls-secret 
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app-service
            port:
              number: 80
```

## 3. なぜこの仕組みが良いのか？
疎結合（依存しない）: cert-manager が止まっていても、すでに Secret に保存されている証明書を使って ingress-nginx は動き続けられます。

自動更新: 証明書の期限が近づくと、cert-manager が新しい証明書を取得して Secret を上書きします。ingress-nginx はそれを検知して自動でリロードするため、「証明書の更新作業」という概念がなくなります。

標準的: この Secret の形式は Kubernetes の標準仕様（kubernetes.io/tls）に従っているため、ingress-nginx 以外のコントローラー（例：Traefik や Kong）でも全く同じように共有できます。
