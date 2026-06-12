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
azd env set AZURE_SUBSCRIPTION_ID (az account show --query id -o tsv)   # azd は自動設定しないので明示
azd env set AZURE_RESOURCE_GROUP rg-prod-manual         # azd は自動設定しないので明示（既定の命名 rg-<env 名> に合わせる）

# アプリの初期バージョン（手順 5 で 1.1.0 に更新する）
azd env config set infra.parameters.appVersion 1.0.0

# 宣言的 blue/green 状態（コンテナアプリ bicep の ingress traffic を駆動する）
azd env config set infra.parameters.productionLabel blue        # 本番の色
azd env config set infra.parameters.blueRevisionSuffix v1-0-0   # blue が担うリビジョン（= 'v' + appVersion, '.'→'-'）
azd env config set infra.parameters.greenRevisionSuffix ""      # green はまだ無い（空 → green の traffic エントリは省略される）
azd env set ACTIVE_LABEL blue                                   # status/promote/rollback 用のミラー（正は productionLabel）
```

> `appVersion` はこのアプリの **version の唯一の出所**です。api の `APP_VERSION` env、web の Docker **ビルド引数**、そして各アプリの**リビジョンサフィックス**（bicep で `'v' + replace(appVersion, '.', '-')`、例: `1.0.0`→`v1-0-0`）の導出に使われます。AppHost では既定値なしで公開しているため `{{ parameter "appVersion" }}` として出力され、`infra.parameters.appVersion`（config）から解決されます（`azd env set` の env 変数では解決されない）。既定値が無いので、**初回 `azd provision`/`azd deploy` の前に必ず設定**してください（無いと `parameter infra.parameters.appVersion not found` で失敗）。
>
> `productionLabel` / `blueRevisionSuffix` / `greenRevisionSuffix` はコンテナアプリ bicep が宣言的トラフィックを組み立てるための入力です（同じく `{{ parameter ... }}` → `infra.parameters.*`）。重みは `weight = (productionLabel == '<color>') ? 100 : 0` で導出され、サフィックスが空の色は traffic エントリ自体が省略されます（初回は green が無い）。
>
> `AZURE_RESOURCE_GROUP` は azd が ACA アプリを作成するリソースグループです。azd（1.25 系）はこの値を env に書き出さないため、手順 3 以降で空にならないよう、azd 既定の命名（`rg-<env 名>`）に合わせて先に設定しておきます。

---

## 2. 外部リソース（infra）を `az` コマンドで作成する

`infra/main.bicep`（VNet / Azure SQL / Key Vault / Front Door）をリソースグループスコープで適用します。
**スクリプト版の `deploy-platform.ps1 -Apply` が裏でやっていること**そのものです。

```powershell
$platRg = "rg-prod-manual-platform"
az group create -n $platRg -l japaneast

# SQL の Entra 管理者をサインインユーザーにする（後で passwordless 付与も可能になる）
$me  = az ad signed-in-user show --query id -o tsv
$upn = az ad signed-in-user show --query userPrincipalName -o tsv

az deployment group create -g $platRg -n platform `
  --template-file infra/main.bicep `
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

> **注意（postdeploy フック）**: `azd deploy`（および `azd up` の deploy フェーズ）の最後に、`azure.yaml` の **postdeploy フック**が `configure-frontdoor-origin.ps1` と `reconcile-traffic.ps1` を自動実行します。Front Door の配線はこのフックで完了します。**トラフィック配分（blue=100% / green=0%）はコンテナアプリの bicep が宣言的に行う**ため、`reconcile-traffic.ps1` は今は**検証専用**（宣言通りかを確認して警告するだけ）です（`azd provision --preview` では走りません）。
>
> 本書では「中で何が起きているか」を理解するため、**フックを有効にしたまま**、Front Door 配線を `az` コマンドで手動確認し、トラフィックは宣言された状態を `az ... traffic show` で検証します（いずれも安全）。
>
> 完全に手動で体験したい場合は、`azure.yaml` の `postdeploy:` ブロックを一時的にコメントアウトしてから `azd deploy` してください（azd にフックを 1 回だけスキップするフラグはありません）。その場合は下の `az afd ... update` を `create` に読み替えます（トラフィックは bicep が宣言済みなので手動設定は不要です）。

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

### 4-2. 初回トラフィックの確認（宣言的トラフィック）

リビジョンサフィックスは決定的（`appVersion` から導出）なので、初回デプロイで作られるリビジョンは `web--v1-0-0` / `api--v1-0-0` です。コンテナアプリの bicep が `productionLabel=blue` から **blue ラベル=100%**（green はサフィックス未設定なので省略）を**宣言**しているため、`azd deploy` 完了時点で既にトラフィックは正しく設定されています。手動でラベル付けや `traffic set` を行う必要はありません。確認だけします。

```powershell
foreach ($name in 'web','api') {
  $app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  "[$name]"
  az containerapp ingress traffic show -g $appRg -n $app `
    --query "[].{revision:revisionName, label:label, weight:weight}" -o table
}
```

> `web--v1-0-0` が `label=blue, weight=100` で表示されれば成功です。これは `reconcile-traffic.ps1`（検証専用）が postdeploy フックで確認しているのと同じ内容です。

**確認**: ブラウザで `https://<FRONTDOOR_ENDPOINT_HOSTNAME>`（`azd env get-value FRONTDOOR_ENDPOINT_HOSTNAME`）を開く → **青いバナー / version 1.0.0 / BLUE**。

---

## 5. 新バージョン（green）を手動でデプロイする

コードを編集します（= 新しいイメージ）。

```csharp
// src/Api/Program.cs
const string Color = "#16a34a"; // green
const string Label = "green";
```

バージョン番号と、今回作る candidate（green）のリビジョンサフィックスを azd パラメータで設定します。`appVersion` は api の `APP_VERSION` env・web のビルド引数・リビジョンサフィックスの導出元になり、`greenRevisionSuffix` は green エントリをトラフィックに登場させるためのキー（`'v' + appVersion`）です。

```powershell
azd env config set infra.parameters.appVersion 1.1.0
azd env config set infra.parameters.greenRevisionSuffix v1-1-0   # = 'v' + appVersion（'.'→'-'）
azd deploy
```

> `productionLabel` は **blue のまま**変更しません（昇格は手順 7）。
>
> **バージョンは毎回新しくします**。リビジョンサフィックスは `appVersion` から決定的に導出される（`v1-1-0` など）ため、同じバージョンを再 `azd deploy` すると `revision with suffix v1-1-0 already exists` で失敗します。デプロイのたびに `appVersion` を上げてください。promote/rollback（手順 7・8）はトラフィックを動かすだけで再デプロイしないため、この制約の影響を受けません。

### 5-1. デプロイ結果の確認（宣言的トラフィック）

`azd deploy` は新リビジョン `web--v1-1-0` / `api--v1-1-0` を作成します。コンテナアプリの bicep は `productionLabel=blue` のままなので、**green を 0%、blue を 100%** と宣言します。つまりデプロイの瞬間も本番（blue）からトラフィックは奪われません。手動でラベル付けや `traffic set` を行う必要はありません。確認だけします。

```powershell
foreach ($name in 'web','api') {
  $app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  "[$name]"
  az containerapp ingress traffic show -g $appRg -n $app `
    --query "[].{revision:revisionName, label:label, weight:weight}" -o table
}
```

> **ポイント**: `web--v1-0-0`(blue)=100% / `web--v1-1-0`(green)=0% と表示されれば成功です。新リビジョンを作っても本番は blue のまま。**デプロイはトラフィックを奪いません**（bicep が宣言的に 0% で作成するため）。

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

web / api を**まとめて** green=100% にします。即時の `az ... traffic set` で切り替えたあと、宣言的状態 `infra.parameters.productionLabel` も green に同期します（これをやらないと、次の `azd deploy` が宣言（blue=100%）どおりに**昇格を巻き戻して**しまいます）。

```powershell
foreach ($name in 'web','api') {
  $app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  az containerapp ingress traffic set -g $appRg -n $app --label-weight green=100 blue=0
}

# 宣言的状態を同期（次回 azd deploy でも green を本番に保つ）
azd env config set infra.parameters.productionLabel green

# 状態のミラーと世代の記録
azd env set PREVIOUS_ACTIVE_LABEL blue
azd env set ACTIVE_LABEL green
```

- 段階的に流す（カナリア）なら weight を変えるだけ: `--label-weight green=20 blue=80` → 確認後に `green=100 blue=0`。**カナリア中（<100%）は `productionLabel` を変えない／`azd deploy` を実行しない**でください（宣言に従って blue=100% に戻ってしまいます）。
- Front Door の URL を再読み込み → **緑 / version 1.1.0**。ダウンタイムなしで切り替わります。

---

## 8. ロールバックを `az` コマンドで実行する（`bluegreen-rollback.ps1` 相当）

直前の本番ラベル（blue）へ即時に戻します。**再ビルド不要**、トラフィックを戻すだけです。promote と同様、`infra.parameters.productionLabel` も blue に同期して次回 `azd deploy` との整合を保ちます。

```powershell
foreach ($name in 'web','api') {
  $app = az containerapp list -g $appRg --query "[?tags.\"aspire-resource-name\"=='$name'].name | [0]" -o tsv
  az containerapp ingress traffic set -g $appRg -n $app --label-weight blue=100 green=0
}

# 宣言的状態を同期
azd env config set infra.parameters.productionLabel blue

# 状態のミラーと世代の記録
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
| `up.ps1` | 上記 + 初期 blue/green パラメータ（`appVersion` / `productionLabel` / `blueRevisionSuffix` / `greenRevisionSuffix`）の `azd env config set` + `azd up`（= `azd provision` + `azd deploy` + postdeploy フック） |
| `preview.ps1` | `az deployment group what-if` + `azd provision --preview` |
| `bluegreen-deploy.ps1 -Version <x>` | `azd env config set infra.parameters.appVersion <x>` + candidate の `azd env config set infra.parameters.<color>RevisionSuffix v<x>` + `azd deploy` |
| `configure-frontdoor-origin.ps1` | `az afd origin create/update` + `az afd route create/update` |
| `reconcile-traffic.ps1` | （検証専用）`az containerapp ingress traffic show` で宣言どおり（本番=100% / candidate=0%）かを確認 |
| `bluegreen-status.ps1` | `az containerapp ingress traffic show` + ラベル FQDN の組み立て |
| `bluegreen-promote.ps1` | `az containerapp ingress traffic set`（新バージョン側ラベル=100）+ `azd env config set infra.parameters.productionLabel` + `azd env set ACTIVE_LABEL` |
| `bluegreen-rollback.ps1` | `az containerapp ingress traffic set`（直前の本番ラベル=100）+ `azd env config set infra.parameters.productionLabel` + `azd env set ACTIVE_LABEL` |

> `azd env get-value <KEY>` は単一値を取得します（古い azd では `azd env get-values` で一覧表示）。
