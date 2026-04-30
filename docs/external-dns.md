# external-dns

external-dns は k8s と連携して、サービスが稼働しているワーカーノードのグローバルIPをDNSに登録します。

1. **ノードの特定**: external-dns が「Ingress ルーター Pod が Node A で動いている」ことを検知します。
2. **IPの取得**: Node A のパブリック IP を取得します。
3. **DNS更新**: Digital Ocian DNS の A レコードを Node A の IP に書き換えます。
