# Argon CD と単一チャート化

deploy.sh と helm の配下を以下のように修正する

1. ディレクトリ coder-vke を作成し、現在の helm ディレクトリで定義されているものを1個のチャートとして配置する。
2. terraform で VKEを作成した後、Helm で Argon CD をインストールするように変更する
3. Argon CD で 1. で作成したチャートをデプロイするように変更する
4. coder の構築するクリプトは従来通り
ただし、Argon CD のコンソールについては、 kubectl でポート転送して codespaces でブラウザに転送して参照するので ingress や cert-manager は不要

destroy.sh も以下のように変更する。
1. coder のワークスペースを破棄するスクリプトは従来通り
2. Argon CD でチャートをアンインストールする
3. terraform destory 