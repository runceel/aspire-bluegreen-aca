# デモ手順書 — Aspire blue/green on ACA

登壇・実演でそのまま使える、ステップ単位の手順書です。各ステップに「実行コマンド / 期待結果 / 見せるポイント / 想定 Q&A」を併記しています。

> スクリプトを使わず `azd` / `az` を 1 つずつ手動で実行して仕組みを理解したい場合は、[`demo-guide-manual.md`（手動実行版）](./demo-guide-manual.md)を参照してください。本書（スクリプト版）は確実さ・短さ重視、手動実行版は理解重視です。

---

## 0. 事前準備チェックリスト

| 項目 | 内容 |
| --- | --- |
| ツール | .NET 10 SDK / Node.js 24+ / Docker / `az` / `azd` / PowerShell 7 |
| 認証 | `az login` と `azd auth login` 済み |
| サブスクリプション | ACA / Front Door / Azure SQL を作成できる権限（Contributor 相当 + SQL の Entra 管理者になれること） |
| 想定コスト | ACA（従量）+ Front Door Standard + Azure SQL。**デモ後は必ず後片付け**（最終ステップ参照） |
| 所要時間 | 初回デプロイ 15〜25 分、blue/green 切替は数分 |
| リージョン | 例: `japaneast` |

> リハーサル推奨。初回デプロイはイメージ build/push を含むため時間がかかります。本番デモでは「初回デプロイ済みの状態」から **ステップ 2 以降**を実演すると安全です。

---

## シナリオ概要

オンラインオーダーの Web アプリです。

- **blue** = 現行の安定版（青いバナー、`version 1.0.0`）
- **green** = 新バージョン（緑のバナー、`version 1.1.0`）
- ユーザーは **Front Door 経由**でアクセスします。blue/green の切り替えは **トラフィックラベル**で行い、ダウンタイムなしで新版へ移行します。
- web（nginx）と api（ASP.NET Core）は **一括で**切り替え、UI と API のバージョンを常に一致させます。

---

## ステップ 1: 初回デプロイ

**コマンド**

```powershell
# Azure にログイン
az login
azd auth login

# azd 環境を作成
azd env new prod

# リージョンとサブスクリプション ID を設定
azd env set AZURE_LOCATION japaneast
azd env set AZURE_SUBSCRIPTION_ID $(az account show --query id -o tsv)

# デプロイ実行（platform: `infra/main.bicep` → aspire publish → az deployment → postdeploy → status を一括実行）
./scripts/up.ps1
```

> **`up.ps1` が自動で補完する値**: 初回のみ、未設定の値を補完してから「platform 適用（`infra/main.bicep`）→ `aspire publish` → `az deployment` → postdeploy フック」を実行します。`infra.parameters.appVersion`（初期値 `1.0.0`）/ `AZURE_RESOURCE_GROUP`（azd 既定の `rg-<env 名>`）/ `ACTIVE_LABEL`（`blue`）に加え、宣言的 blue/green 状態（`infra.parameters.productionLabel=blue` / `blueRevisionSuffix=v1-0-0` / `greenRevisionSuffix=`（空））を補完します。`appVersion` はバージョンの唯一の出所で、api の `APP_VERSION` env・web の Docker **ビルド引数**・各アプリの**リビジョンサフィックス**（`v` + バージョン、`.`→`-`）の導出に使われます。`infra.parameters.appVersion` からしか解決されない（AppHost の既定値や `azd env set` の env 変数では解決されない）ため、補完されないと `parameter infra.parameters.appVersion not found` で失敗します。バージョンを上げるときはステップ 3 の `bluegreen-deploy.ps1 -Version <x>` を使います。

**期待結果**

- `up.ps1` が「Step 1/4 platform（infra）→ Step 2/4 aspire publish → Step 3/4 az deployment → Step 4/4 postdeploy hooks」を順に実行し、最後に status を表示。
- 末尾に `Front Door endpoint: https://<...>.azurefd.net` が表示され、`bluegreen-status.ps1` が web/api ともに `blue = 100%` を表示。

**見せるポイント**

- ブラウザで `https://<Front Door エンドポイント>` を開き、**青いバナー**と `version 1.0.0 / blue` を確認。
- `/api/version` が `{ "version": "1.0.0", "color": "#2563eb", "label": "blue" }` を返すこと。

**想定 Q&A**

- Q: Front Door の origin はいつ設定された？ → A: `up.ps1` の Step 4（postdeploy フック）で `configure-frontdoor-origin.ps1` が web の FQDN を自動で配線します。
- Q: SQL が無くても動く？ → A: `/api/version` は SQL 非依存。`/api/orders` だけが SQL を使い、未接続でもインメモリにフォールバックします。

---

## ステップ 2: コードを書き換えて新バージョンにする

**コマンド**

`src/Api/Program.cs` の定数を編集します。

```csharp
const string Color = "#16a34a"; // green
const string Label = "green";
```

> バージョン番号（`1.1.0`）はステップ 3 の `bluegreen-deploy.ps1 -Version 1.1.0` で設定します（`infra.parameters.appVersion` に反映され、api の `APP_VERSION` env・web のビルド引数・リビジョンサフィックスの導出に使われます）。

**期待結果 / 見せるポイント**

- 差分は数行のみ。「**コードを変えるだけ**で新バージョンになる」ことを強調。
- （任意）`./scripts/preview.ps1` を実行し、`infra/main.bicep` の what-if と `aspire publish` + `az deployment --what-if` の差分を確認することで、安全な変更であることを確認できます。

---

## ステップ 3: 新リビジョン（green）をデプロイ

**コマンド**

```powershell
./scripts/bluegreen-deploy.ps1 -Version 1.1.0
```

> このスクリプトは「`appVersion` の更新 → candidate（green）の `greenRevisionSuffix` 設定 → `aspire publish` + `az deployment` → status 表示」を一括で行います。`productionLabel` は変更しません（昇格はステップ 5）。
>
> **バージョンは毎回新しくします**。リビジョンサフィックスは `appVersion` から決定的に導出されるため、同じバージョンを再デプロイすると `revision with suffix ... already exists` で失敗します（スクリプトはビルド前に検知して止めます）。

**期待結果**

- 新しいコンテナイメージが build/push され、web/api に**新リビジョン**（`<app>--v1-1-0`）が作成される。
- トラフィックは **宣言的**。コンテナアプリの bicep が `productionLabel=blue` から重みを導出（`blue=100% / green=0%`）するため、`az deployment` 自体が新（green）リビジョンを **0% に固定**したまま blue を 100% に保ちます。デプロイ後にトラフィックを後付けで調整する隙間はありません。
- 必要なら `./scripts/reconcile-traffic.ps1` を実行して、宣言通り（production=100% / candidate=0%）かを検証できます（トラフィックは変更しません）。

**見せるポイント**

- ブラウザで Front Door の URL を再読み込みしても **まだ青いまま**（本番は blue=100%）。
- 「新版をデプロイしても本番トラフィックは一切奪われない」点を強調。

**想定 Q&A**

- Q: なぜ green が 0% なの？ → A: コンテナアプリの ingress traffic を **bicep で宣言**しており、`weight = (productionLabel == '<color>') ? 100 : 0` です。candidate は常に 0% で作成されるため、`az deployment` の瞬間も本番露出はゼロです。
- Q: `reconcile-traffic.ps1` は何をする？ → A: **状態の検証のみ**です。宣言どおり（production=100% / candidate=0%）かを確認し、不一致を警告します。

---

## ステップ 4: green を検証（本番に影響なし）

**コマンド**

```powershell
./scripts/bluegreen-status.ps1
```

**期待結果 / 見せるポイント**

- web/api それぞれの **green ラベル URL** が表示される（例: `https://web---green.<env>.<region>.azurecontainerapps.io`）。
- green の web URL を開くと **緑のバナー / version 1.1.0**。`api---green.../api/version` も `green` を返す。
- 本番（Front Door 経由）は **まだ青**。「テスト用 URL で安全に新版を確認できる」ことを見せる。

**想定 Q&A**

- Q: web の green は api のどちらを見る？ → A: 既定では nginx は本番側にプロキシします。各ティアの green は **個別のラベル URL** で確認し、promote で web/api をまとめて green に切り替えて整合させます。

---

## ステップ 5: 本番へ切り替え（promote）

**コマンド**

```powershell
# 一気に 100%
./scripts/bluegreen-promote.ps1

# もしくは段階的（カナリア）
./scripts/bluegreen-promote.ps1 -CandidateWeight 20
./scripts/bluegreen-promote.ps1 -CandidateWeight 100
```

**期待結果**

- web/api ともに **green=100% / blue=0%**（即時の `az ... traffic set`）。昇格後、宣言的状態 `infra.parameters.productionLabel` が `green` に同期され、`ACTIVE_LABEL` も `green` に更新されます。これにより以降の `az deployment` でも green が本番のまま維持されます。

**見せるポイント**

- Front Door の URL を再読み込みすると **緑のバナー / version 1.1.0**。ダウンタイムなしで切り替わったことを強調。
- `./scripts/bluegreen-status.ps1` で `green = 100%` を確認。

**想定 Q&A**

- Q: カナリアは可能？ → A: `-CandidateWeight 20` で 20% だけ green に流し、問題なければ 100% にできます。

---

## ステップ 6: ロールバック（問題発生を想定）

**コマンド**

```powershell
./scripts/bluegreen-rollback.ps1
```

**期待結果 / 見せるポイント**

- web/api ともに **blue=100%** に即時復帰。宣言的状態 `infra.parameters.productionLabel` と `ACTIVE_LABEL` が `blue` に戻る（以降の `az deployment` でも blue が維持される）。
- Front Door の URL を再読み込みすると **元の青いバナー**。「問題があっても 1 コマンドで即時復旧」を強調。

**想定 Q&A**

- Q: ロールバックは再ビルド不要？ → A: 不要です。既存の blue リビジョンへ**トラフィックを戻すだけ**なので一瞬です。

---

## 後片付け

```powershell
azd down --purge --force
az group delete -n rg-prod-platform --yes
```

- `azd down` で ACA / アプリ関連を削除、`az group delete` で platform（VNet / SQL / Front Door）を削除します。
- 課金を止めるため、**デモ後は必ず実行**してください。

---

## トラブルシュート早見表

| 症状 | 対処 |
| --- | --- |
| Front Door URL が 404 / 502 | `./scripts/configure-frontdoor-origin.ps1` を再実行（origin 配線をやり直す） |
| 切替後も古い版が見える | ブラウザ/Front Door のキャッシュ。時間を置くか別タブで確認。`bluegreen-status.ps1` で実トラフィックを確認 |
| `/api/orders` が `in-memory` のまま | SQL ユーザー未付与。`./scripts/grant-sql-access.ps1` を実行（Entra 管理者で `az login` 済みであること） |
| promote が「candidate なし」で失敗 | 先に `./scripts/bluegreen-deploy.ps1 -Version <x>` で candidate リビジョンを作成してから promote |
| `revision with suffix vX-Y-Z already exists` でデプロイ失敗 | リビジョンサフィックスは `appVersion` から決定的に導出されるため、**同じバージョンは 1 回しかデプロイできません**。`-Version` を未使用の新しい番号に上げてください（`bluegreen-deploy.ps1` はビルド前にこれを検知して早期に止めます）。promote/rollback はトラフィックを動かすだけ（再デプロイしない）なので影響を受けません。 |
