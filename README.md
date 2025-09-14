# MCP_Bicep – Azure Developer CLI テンプレート

Azure Developer CLI (azd) を使って、メッセージ・センター・プラットフォーム (MCP) のインフラと Python 製 Azure Functions アプリを一括デプロイするためのテンプレートです。

> ポイント要約
>
> - `azure.yaml` でプロジェクト名・インフラ構成・サービスを宣言し、インフラのエントリーポイントは `infra/main.bicep`。
> - サービスは `./mcp-code` ディレクトリの Python Functions アプリ（SSE とメッセージ POST の /mcp エンドポイント実装を前提）。
> - 初回は APIM が使うシステムキー `mcpFunctionsKey` を空文字でデプロイ。デプロイ後に Functions 拡張の System key を取得し、再デプロイで設定。

---

## リポジトリ構成


```
azure.yaml
infra/
  apim.bicep       # VNet 統合の StandardV2 APIM。Named Value `mcp-functions-key` を作成
  function.bicep   # ストレージ、Flex Consumption の Function App (Python)、App Insights、(任意) Private Endpoint
  main.bicep       # エントリーポイント。network/function/apim モジュールを呼び出す
  network.bicep    # VNet、APIM/Function 用サブネット、NSG、Private DNS ゾーン
mcp-code/
  function_app.py  # Python Functions 実装（/mcp: GET(SSE), POST(message) を提供する想定）
  host.json
  requirements.txt
```

### Bicep モジュール概要
- `network.bicep`:
  - VNet、APIM 用/Functions 用サブネット、NSG、Private DNS ゾーンを作成
  - 各リソース ID を出力
- `function.bicep`:
  - ストレージアカウント、Flex Consumption プランの Function App (Python)、App Insights、(必要に応じて) Private Endpoint
- `apim.bicep`:
  - VNet 統合された StandardV2 SKU の APIM
  - Named Value `mcp-functions-key` に Functions の MCP 拡張 System key を保持
  - `/mcp` に GET(SSE) と POST(message) の操作を公開
- `main.bicep`:
  - `network` -> `function` -> `apim` の順でモジュールを呼び出し
  - APIM -> Functions 認証用パラメータ `mcpFunctionsKey` を受け取り（初回は空で可）

> 注意: 実運用時は `mcp-code` に SSE とメッセージ投稿を実装した Python Functions を配置してください。

---

## 前提条件

- Azure Developer CLI (azd) がインストール済みでサインイン済みであること
- Azure CLI がインストール済みであること
- Git 環境があること（このリポジトリを取得するため）
- `./mcp-code` に Function のコードが配置されていること

> OS: Windows、既定シェル: PowerShell を想定したコマンド例を記載しています。

> ログインに関して:
> - azd のみで運用する場合は、`azd auth login` のみで十分です。
> - Azure CLI を併用して `az group create` などのコマンドを使う場合は、`az login`（必要に応じて `az account set`）も実施してください。

---

## Azure Developer CLIのインストール（必須）

以下は公式ドキュメントで案内されている代表的なインストール方法です。環境に応じて 1 つを実行してください。

### Windows

PowerShell（既定のシェル）で実行:

```powershell
# winget
winget install microsoft.azd

# もしくは Chocolatey
choco install azd

# もしくは PowerShell スクリプト（署名済みスクリプト実行ポリシーで）
powershell -ex AllSigned -c "Invoke-RestMethod 'https://aka.ms/install-azd.ps1' | Invoke-Expression"
```

### macOS

```bash
brew tap azure/azd && brew install azd
```

### Linux

```bash
curl -fsSL https://aka.ms/install-azd.sh | bash
```

これらの方法は azd 本体に加えて、必要な依存ツール（Git CLI や Bicep CLI など）も導入します（learn.microsoft.com 参照）。

---

## サインイン（初回のみ）

インストール後、Azure アカウントにサインインして azd に認証情報を与えます。公式の「Get started using Azure Developer CLI」に従い、次を実行してください。

```powershell
azd auth login
```

既定のブラウザーが開き Azure のサインイン画面が表示されます。サインインが完了すると azd に認証が保存され、`azd up` などのコマンドでサブスクリプションやリージョンの指定プロンプトが利用できるようになります。

補足: Azure CLI 側で `az login` 済みでも認証が共有される場合はありますが、azd のドキュメントでは `azd auth login` の利用が推奨されています。

---

## セットアップと環境作成

- 変数例
  - サブスクリプション ID: `<your-subscription-id>`
  - 環境名: `dev`
  - リージョン: `japaneast`

```powershell
# リポジトリをクローン
git clone https://github.com/YamadaKZ/MCP_Bicep.git
cd MCP_Bicep

## サインイン（初回のみ）

インストール後、Azure アカウントにサインインして azd に認証情報を与えます。公式の「Get started using Azure Developer CLI」に従い、次を実行してください。

```powershell
azd auth login
```


# 環境を作成（dev 環境／リージョン: japaneast）
```powershell

# 環境を作成（dev 環境／リージョン: japaneast）
azd env new dev --subscription <your-subscription-id> --location japaneast
```

- `azd env new` 実行後に `.azure/dev.env` が生成され、`AZURE_SUBSCRIPTION_ID` や `AZURE_RESOURCE_GROUP` 等が保存されます。基本的に `.env` の手動作成は不要です。

---

## 初回デプロイ（mcpFunctionsKey を空で）

初回は `main.bicep` のパラメータ `mcpFunctionsKey` を空文字列のままインフラを構築します。

```powershell

# インフラと Functions コードを一括デプロイ
azd up
```

完了後、出力には以下が表示されます：
- Function App の URL（例: `https://<function-host>.azurewebsites.net`）
- APIM のゲートウェイ URL（例: `https://<apim-name>.azure-api.net`）

続いて Azure ポータルで Function App を開き、[機能拡張 (Extensions)] から `mcp_extension` の System key をコピーします。これが APIM -> Functions 呼び出し時の `x-functions-key` になります。

![Functions 拡張の System key 取得例](images/app-key.png)



## システムキーの登録と APIM 更新（再デプロイ）

取得した System key を Bicep パラメータ `mcpFunctionsKey` に設定し、APIM の Named Value `mcp-functions-key` を更新します。次のいずれかの方法を選択してください。

### 方法 A: 環境ファイル（推奨）に登録

`BICEP_PARAM_<パラメータ名>` 形式の環境変数は azd により Bicep パラメータへ自動で渡されます。

```powershell
# dev 環境ファイルにキーを保存（.azure/dev.env に追記されます）
azd env set BICEP_PARAM_MCPFUNCTIONSKEY <取得したキー>

# 再デプロイ（APIM の Named Value が更新されます）
azd up
```

以降は環境ファイルに値が保持されるため、毎回の入力は不要です。

### 方法 B: パラメータファイルで指定

`infra/infra.parameters.json`（なければ作成）に次のように追記します。

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "mcpFunctionsKey": {
      "value": "<取得したキー>"
    }
  }
}
```

その後、再度 `azd up` を実行してください。

---

## エンドポイントと動作の目安

- APIM 公開 API: `https://<apim-name>.azure-api.net/mcp`
  - GET: Server-Sent Events (SSE)
  - POST: メッセージ投稿（ボディ形式は `mcp-code` 側の実装に依存）
- 直接 Functions を呼ぶ場合: `https://<function-host>.azurewebsites.net/api/mcp`（認証が必要な場合あり）

> 具体的なリクエスト・レスポンス例は `mcp-code` の実装に合わせてご用意ください。

---

## 動作確認

VS CodeからAPIM経由でMCPサーバーに接続できることを確認します。

### VS Codeの設定

`.vscode/mcp.json` の設定は以下になります：

```json
{
  "servers": {
    "remote-mcp-via-apim": {
      "type": "sse",
      "url": "https://<apim-name>.azure-api.net/mcp/runtime/webhooks/mcp/sse"
    }
  }
}
```

設定値：

- <apim-name>：APIMの既定ドメイン
- APIMリソース概要のゲートウェイのURLで確認できます

![apimのurl確認](images/url.png)



## 完全クローズドにする

最後に Azure Functions 側の公開アクセスを無効化すれば、Private Endpoint 経由以外の受信を拒否できます。

![v-net](images/url.png)

- Azure Portal → 対象の Azure Function → ネットワーク
- 公衆ネットワーク アクセス: 無効 に設定






## クリーンアップ

リソースを削除する場合は次を実行します（作成した Azure リソースが削除されます）。

```powershell
azd down
```

> 実行前に削除対象や課金影響を必ずご確認ください。

---

## トラブルシューティングのヒント

- `mcp-functions-key` が未設定/不正
  - APIM から Functions を呼び出す際に 401/403 となる場合は、`mcpFunctionsKey` の設定と再デプロイをご確認ください。
- VNet 統合関連の疎通不良
  - サブネットの委任/NSG/Private DNS ゾーンのリンク設定を確認してください。
- Functions の起動遅延/依存パッケージ不足
  - `mcp-code/requirements.txt` を見直し、必要なライブラリがインストールされているか確認してください。
- 権限不足
  - デプロイ先サブスクリプションへの権限（Owner/Contributor 等）や Key Vault/Storage などのアクセス許可をご確認ください。

---


## .env と環境ファイルについて

- `azd env new` が `.azure/<env>.env` を自動生成します（標準の環境変数を保持）。
- 追加の Bicep パラメータは、`azd env set BICEP_PARAM_<ParamName> <value>` で追記するのが簡単です。
- 一時的にシェルへ設定して利用することも可能ですが、環境ファイルを使うと再デプロイ時の再入力が不要で便利です。

---

## Azure CLIのインストールとサインイン（必要な場合）

Azure CLI（`az`）はデプロイの確認や補助に便利です。未導入の場合は以下のいずれかの方法でインストールしてください。

### Windows

```powershell
# インストール（いずれか）
winget install Microsoft.AzureCLI
# または
choco install azure-cli

# バージョン確認
az --version
```

### macOS

```bash
brew update && brew install azure-cli
az --version
```

### Linux（Debian/Ubuntu の例）

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az --version
```

> 他ディストリビューションや詳細は Microsoft Learn を参照してください。

### サインインとサブスクリプション選択

```powershell
# Azure へサインイン（ブラウザーが開きます）
az login

# 複数サブスクリプションがある場合は確認
az account list --output table

# 対象サブスクリプションを選択（ID でも名前でも可）
az account set --subscription "<your-subscription-id-or-name>"

# 選択内容を確認
az account show --output table
```

ブラウザが使えない環境では次を利用できます:

```powershell
az login --use-device-code
```


---

## 参考

- Azure Developer CLI (azd): https://aka.ms/azure-dev
- Azure Functions: https://learn.microsoft.com/azure/azure-functions/
- Azure API Management: https://learn.microsoft.com/azure/api-management/
- Bicep: https://learn.microsoft.com/azure/azure-resource-manager/bicep/

---

## ライセンス
使用・コード変更可能。
