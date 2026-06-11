# デモ手順書（手動実行版）

スクリプト（`scripts/*.ps1`）を介さず、**`azd` と `az` のコマンドを 1 つずつ手動で実行**して、blue/green デプロイの仕組みを理解するための手順書です。

## このデモの狙い・スクリプト版との使い分け

| | スクリプト版（[`demo-guide.md`](./demo-guide.md)） | 手動実行版（本書） |
| --- | --- | --- |
| 目的 | デモを**確実に・短時間で**実施する | 内部で何が起きているかを**理解する** |
| 操作 | `./scripts/up.ps1` など 1 コマンド | `azd` / `az` を 1 つずつ手動で実行 |
| 向いている場面 | 登壇・本番デモ | 勉強会・ハンズオン・深掘り Q&A |

> どちらも同じ azd 環境で混在して実行できます（コマンドはすべて冪等）。スクリプトは「これらのコマンドを順番に呼び出しているだけ」であることを、本書で確認できます。末尾の[対応表](#付録-スクリプトと手動実行コマンドの対応表)も参照してください。

> 前提・想定コスト・所要時間・後片付けの重要性は [`demo-guide.md` の「0. 事前準備」](./demo-guide.md#0-事前準備チェックリスト)と共通です。

---

## 0. 認証

```powershell
az login
azd auth login
```

---

## 1. azd 環境を作る

azd 環境 = デプロイのパラメータと出力をためる名前空間です。中身は `azd env get-values` でいつでも確認できます。

```powershell
azd env new prod-manual
azd env set AZURE_LOCATION japaneast
```

---

## 2. 外部リソース（platform）を `az` コマンドで作成する

`platform/main.bicep`（VNet / Azure SQL / Key Vault / Front Door）をリソースグループスコープで適用します。
**スクリプト版の `deploy-platform.ps1 -Apply` が裏でやっていること**そのものです。

```powershell
$platRg = "rg-prod-manual-platform"
az group create -n $platRg -l japaneast

# SQL の Entra 管理者をサインインユーザーにする（後で passwordless 付与も可能になる）
$me  = az ad signed-in-user show --query id -o tsv
$upn = az ad signed-in-user show --query userPrincipalName -o tsv

az deployment group create -g $platRg -n platform `
  --template-file platform/main.bicep `
  --parameters location=japaneast namePrefix=abg environmentName=promanual `
    sqlAdminLogin=$upn sqlAdminObjectId=$me sqlAdminPrincipalType=User
```

作成された出力を azd 環境へ流し込みます。**AppHost の publish 入力**は `infra.parameters.*` に、**フックが使う値**は通常の azd env 値に保存します。

```powershell
$o = az deployment group show -g $platRg -n platform --query properties.outputs -o json | ConvertFrom-Json

# AppHost publish 入力（repo では infra.parameters.* を source of truth にする）
azd env config set infra.parameters.infrastructureSubnetId $o.infrastructureSubnetId.value
azd env config set infra.parameters.sqlServerName          $o.sqlServerName.value
azd env config set infra.parameters.sqlResourceGroup       $o.sqlResourceGroup.value
azd env set sqlServerFqdn          $o.sqlServerFqdn.value

# Front Door 配線などで参照する値
azd env set PLATFORM_RESOURCE_GROUP     $platRg
azd env set FRONTDOOR_PROFILE_NAME      $o.frontDoorProfileName.value
azd env set FRONTDOOR_ENDPOINT_NAME     $o.frontDoorEndpointName.value
azd env set FRONTDOOR_ENDPOINT_HOSTNAME $o.frontDoorEndpointHostName.value
azd env set FRONTDOOR_ORIGIN_GROUP_NAME $o.frontDoorOriginGroupName.value

# 本番ラベルの初期値
azd env set ACTIVE_LABEL blue
```

> **ここがポイント**: `infrastructureSubnetId` / `sqlServerName` / `sqlResourceGroup` は AppHost の `AddParameter(...)` と対応する publish 入力で、この repo では `infra.parameters.<name>` に保存します。`azd` はこの設定を使って Aspire の publish 必須入力を解決します。一方 `sqlServerFqdn` や `FRONTDOOR_*` はフック/スクリプト用なので `azd env set` に残します。

---

## 3. `azd` を分割実行（provision → deploy）

スクリプト版は `azd up` で provision・deploy・postdeploy フックを**一括**実行します。手動実行版では**フェーズごとに実行し**、それぞれが何をするか確認します。

```powershell
# ① Aspire manifest を読み、ACA 環境 + api/web を作成（コンテナイメージはまだ）
azd provision
```

```powershell
# ② コンテナイメージを build/push し、各 app に新リビジョンをデプロイ
azd deploy
```

> **注意（postdeploy フック）**: `azd deploy`（および `azd up` の deploy フェーズ）の最後に、`azure.yaml` の **postdeploy フック**が `configure-frontdoor-origin.ps1` と `reconcile-traffic.ps1` を自動実行します。つまり **Front Door の配線と「blue=100% / green=0%」は自動で完了**します（`azd provision --preview` では走りません）。
>
> 本書では「中で何が起きているか」を理解するため、**フックを有効にしたまま**、同等の処理を `az` コマンドで手動実行して確認します（冪等なので安全）。
>
> 完全に手動で体験したい場合は、`azure.yaml` の `postdeploy:` ブロックを一時的にコメントアウトしてから `azd deploy` してください（azd にフックを 1 回だけスキップするフラグはありません）。その場合は下の `az afd ... update` を `create` に読み替えます。

デプロイされた Container App を確認します。

```powershell
$appRg = azd env get-value AZURE_RESOURCE_GROUP
az containerapp list -g $appRg --query "[].{name:name, aspire:tags.\"aspire-resource-name\"}" -o table
```

---

## 4. （理解のため）postdeploy フック相当の処理を手動で確認する

### 4-1. Front Door の origin / route（`configure-frontdoor-origin.ps1` 相当）

Front Door は platform Bicep で profile / endpoint / origin-group（空）/ WAF まで作られています。web の FQDN は azd デプロイ後にしか分からないため、**origin の中身だけ**を後から差し込みます。

```powershell
$appRg    = azd env get-value AZURE_RESOURCE_GROUP
$platRg   = azd env get-value PLATFORM_RESOURCE_GROUP
$profile  = azd env get-value FRONTDOOR_PROFILE_NAME
$endpoint = azd env get-value FRONTDOOR_ENDPOINT_NAME
$og       = azd env get-value FRONTDOOR_ORIGIN_GROUP_NAME

$webApp  = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='web'].name | [0]" -o tsv
$webFqdn = az containerapp show -g $appRg -n $webApp --query "properties.configuration.ingress.fqdn" -o tsv

# フックが既に作成済みなら create は失敗するので update を使う（冪等確認）。
# フックを外して初回から手動なら update を create に読み替える。
az afd origin update -g $platRg --profile-name $profile --origin-group-name $og --origin-name web-origin `
  --host-name $webFqdn --origin-host-header $webFqdn --http-port 80 --https-port 443 `
  --priority 1 --weight 1000 --enabled-state Enabled --enforce-certificate-name-check true

az afd route update -g $platRg --profile-name $profile --endpoint-name $endpoint --route-name web-route `
  --origin-group $og --supported-protocols Https --forwarding-protocol HttpsOnly `
  --https-redirect Enabled --link-to-default-domain Enabled --patterns-to-match '/*'
```

### 4-2. 初回トラフィック割り当て（`reconcile-traffic.ps1` 相当）

初回は、最新リビジョンに **blue ラベル**を付け、**100%** を流します。web と api の両方に対して行います。

```powershell
foreach ($name in 'web','api') {
  $app    = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  $latest = az containerapp revision list -g $appRg -n $app --query "sort_by(@,&properties.createdTime)[-1].name" -o tsv
  az containerapp revision label add -g $appRg -n $app --label blue --revision $latest --no-prompt
  az containerapp ingress traffic set -g $appRg -n $app --label-weight blue=100
}
```

**確認**: ブラウザで `https://<FRONTDOOR_ENDPOINT_HOSTNAME>`（`azd env get-value FRONTDOOR_ENDPOINT_HOSTNAME`）を開く → **青いバナー / version 1.0.0 / BLUE**。

---

## 5. 新バージョン（green）を手動でデプロイする

コードを編集します（= 新しいイメージ）。

```csharp
// src/Api/Program.cs
const string Color = "#16a34a"; // green
const string Label = "green";
```

バージョン番号は azd パラメータ `appVersion` で渡します（api の `APP_VERSION` env と web のビルド引数の両方に反映され、web/api が同じ version を表示します）。

```powershell
azd env set appVersion 1.1.0
azd deploy
```

### 5-1. 新リビジョンを green に割り当て（手動 reconcile）

`azd deploy` のフックが自動実行しますが、処理内容は次の通りです。**新リビジョンを green ラベルに付け、トラフィックは blue=100% / green=0% のまま**にします。

```powershell
foreach ($name in 'web','api') {
  $app    = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  $latest = az containerapp revision list -g $appRg -n $app --query "sort_by(@,&properties.createdTime)[-1].name" -o tsv
  az containerapp revision label add -g $appRg -n $app --label green --revision $latest --no-prompt
  az containerapp ingress traffic set -g $appRg -n $app --label-weight blue=100 green=0
}
```

> **ポイント**: 新リビジョンを作っても、本番（blue）は 100% のまま。**デプロイはトラフィックを奪いません**。

---

## 6. green を検証（本番に影響なし）— ラベル FQDN の組み立て方を確認する

ACA はリビジョンラベルを `<app>---<label>.<環境のデフォルトドメイン>` の FQDN で個別公開します。最初のドットの前に `---green` を差し込むだけです。

```powershell
foreach ($name in 'web','api') {
  $app  = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  $fqdn = az containerapp show -g $appRg -n $app --query "properties.configuration.ingress.fqdn" -o tsv
  $green = $fqdn -replace '^([^.]+)\.', '${1}---green.'
  "[$name] https://$green"
}
```

- web の green URL を開く → **緑のバナー / version 1.1.0**。
- `https://api---green.../api/version` → `{"version":"1.1.0","color":"#16a34a","label":"green"}`。
- 本番（Front Door 経由）は**まだ青**。テスト用 URL で安全に新版を確認できます。

---

## 7. 本番へ切り替え（promote）を `az` コマンドで実行する（`bluegreen-promote.ps1` 相当）

web / api を**まとめて** green=100% にします。

```powershell
foreach ($name in 'web','api') {
  $app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  az containerapp ingress traffic set -g $appRg -n $app --label-weight green=100 blue=0
}

# 次の版に向けてラベルの世代を記録
azd env set PREVIOUS_ACTIVE_LABEL blue
azd env set ACTIVE_LABEL green
```

- 段階的に流す（カナリア）なら weight を変えるだけ: `--label-weight green=20 blue=80` → 確認後に `green=100 blue=0`。
- Front Door の URL を再読み込み → **緑 / version 1.1.0**。ダウンタイムなしで切り替わります。

---

## 8. ロールバックを `az` コマンドで実行する（`bluegreen-rollback.ps1` 相当）

直前の本番ラベル（blue）へ即時に戻します。**再ビルド不要**、トラフィックを戻すだけです。

```powershell
foreach ($name in 'web','api') {
  $app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  az containerapp ingress traffic set -g $appRg -n $app --label-weight blue=100 green=0
}

azd env set ACTIVE_LABEL blue
azd env set PREVIOUS_ACTIVE_LABEL green
```

---

## 9. 状態確認用の `az` コマンド

```powershell
$app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='web'].name | [0]" -o tsv

# トラフィックの内訳（リビジョン / ラベル / 重み）
az containerapp ingress traffic show -g $appRg -n $app `
  --query "[].{revision:revisionName, label:label, weight:weight}" -o table

# リビジョン一覧
az containerapp revision list -g $appRg -n $app `
  --query "[].{name:name, active:properties.active, created:properties.createdTime}" -o table
```

---

## 10. 後片付け

```powershell
azd down --purge --force
az group delete -n rg-prod-manual-platform --yes
```

課金を止めるため、デモ後は必ず実行してください。

---

## 付録: スクリプトと手動実行コマンドの対応表

| スクリプト | 相当する手動実行コマンド |
| --- | --- |
| `deploy-platform.ps1 -Apply` | `az group create` → `az deployment group create` → 出力を `azd env set` |
| `up.ps1` | 上記 + `azd up`（= `azd provision` + `azd deploy` + postdeploy フック） |
| `preview.ps1` | `az deployment group what-if` + `azd provision --preview` |
| `configure-frontdoor-origin.ps1` | `az afd origin create/update` + `az afd route create/update` |
| `reconcile-traffic.ps1` | `az containerapp revision label add` + `az containerapp ingress traffic set` |
| `bluegreen-status.ps1` | `az containerapp ingress traffic show` + ラベル FQDN の組み立て |
| `bluegreen-promote.ps1` | `az containerapp ingress traffic set`（新バージョン側ラベル=100）+ `azd env set ACTIVE_LABEL` |
| `bluegreen-rollback.ps1` | `az containerapp ingress traffic set`（直前の本番ラベル=100）+ `azd env set ACTIVE_LABEL` |

> `azd env get-value <KEY>` は単一値を取得します（古い azd では `azd env get-values` で一覧表示）。
