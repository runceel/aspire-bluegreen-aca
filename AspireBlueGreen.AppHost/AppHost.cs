using Aspire.Hosting.Azure;
using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Expressions;

var builder = DistributedApplication.CreateBuilder(args);

// Release version surfaced by /api/version (API) and the web banner ("Web
// version"). Bump it per deploy with `azd env config set infra.parameters.appVersion <x>`
// (scripts use Set-AzdInfraParameter / bluegreen-deploy.ps1). It defaults to 1.0.0 for
// local `aspire run` only. Wired into the api container env (appversion_value) AND the
// web image build arg (both as APP_VERSION) so both tiers report the same version, and
// it also DERIVES each app's revision suffix ('v' + appVersion, dots -> dashes) so a
// version bump mints a fresh blue/green revision.
// IMPORTANT: published WITHOUT a default (publishValueAsDefault: false) so it is emitted
// as `{{ parameter "appVersion" }}` and resolved from infra.parameters.appVersion (config
// store) — the SAME store the api env, web build arg, and the blue/green params all read,
// so one `Set-AzdInfraParameter appVersion <x>` updates every tier consistently. Because
// there is no published default, infra.parameters.appVersion MUST be seeded before any
// `azd up`/`azd deploy` (scripts/up.ps1 does this; the manual guide sets it explicitly),
// otherwise packaging fails with "parameter infra.parameters.appVersion not found".
var appVersion = builder.AddParameter("appVersion", "1.0.0", publishValueAsDefault: false);

// ---------------------------------------------------------------------------
// Blue/green deployment parameters (publish-only; never used by local `aspire
// run`). They drive the DECLARATIVE ingress traffic + deterministic revision
// suffix emitted into the api/web Container App bicep (see ConfigureBlueGreen
// at the bottom of this file). Declared WITHOUT publishValueAsDefault so Aspire
// emits them as `{{ parameter "<name>" }}` in the generated *.tmpl.bicepparam,
// which azd resolves from `infra.parameters.<name>` (config store) — the store
// that scripts/_common.ps1 Set-AzdInfraParameter writes. scripts/up.ps1 seeds
// them before `azd up`; promote/rollback flip productionLabel.
//   - productionLabel        : "blue" | "green" — the color currently at 100%.
//   - blueRevisionSuffix     : revision suffix carrying the blue version (e.g. v1-0-0); "" if absent.
//   - greenRevisionSuffix    : revision suffix carrying the green version; "" if absent.
// The suffix of the revision created by THIS deploy is DERIVED from appVersion in
// bicep ('v' + replace(appVersion, '.', '-')) so bumping appVersion is enough — the
// candidate's *RevisionSuffix param is set to the same value by the deploy script.
// ---------------------------------------------------------------------------
IResourceBuilder<ParameterResource>? productionLabel = null;
IResourceBuilder<ParameterResource>? blueRevisionSuffix = null;
IResourceBuilder<ParameterResource>? greenRevisionSuffix = null;
if (builder.ExecutionContext.IsPublishMode)
{
    productionLabel = builder.AddParameter("productionLabel");
    blueRevisionSuffix = builder.AddParameter("blueRevisionSuffix");
    greenRevisionSuffix = builder.AddParameter("greenRevisionSuffix");
}

// ---------------------------------------------------------------------------
// Azure Container Apps environment.
//   - Local: not used (resources run as processes/containers).
//   - Azure: created by Aspire. We join it to the pre-existing platform VNet
//     subnet so it lives behind the same network as Front Door / SQL.
// The subnet id is only needed for `azd` publish, so its parameter (supplied by
// scripts/up.ps1 via `azd env config set infra.parameters.infrastructureSubnetId`
// from platform/ Bicep outputs) is declared inside the publish-only branch. That
// keeps local `aspire run` from prompting for a value it never uses.
// ---------------------------------------------------------------------------
var acaEnv = builder.AddAzureContainerAppEnvironment("acaenv");

if (builder.ExecutionContext.IsPublishMode)
{
    var infrastructureSubnetId = builder.AddParameter("infrastructureSubnetId");

    acaEnv.ConfigureInfrastructure(infra =>
    {
        var environment = infra.GetProvisionableResources()
            .OfType<ContainerAppManagedEnvironment>()
            .Single();

        environment.VnetConfiguration = new ContainerAppVnetConfiguration
        {
            InfrastructureSubnetId = infrastructureSubnetId.AsProvisioningParameter(
                infra, "infrastructureSubnetId"),
            IsInternal = false,
        };
    });
}

// ---------------------------------------------------------------------------
// SQL Database (external resource).
//   - Local: a SQL Server container (no Azure required for `aspire run`).
//   - Azure: an existing Azure SQL server created by platform/ Bicep.
// The "orders" database powers the /api/orders demo only; /api/version never
// touches SQL so the app stays up even before passwordless access is granted.
// The existing-server name/resource group are only needed for `azd` publish, so
// their parameters are declared inside the publish-only branch. scripts/up.ps1
// persists them in `azd env config` under `infra.parameters.*`; local run uses
// RunAsContainer() and never prompts for them.
// ---------------------------------------------------------------------------
var sql = builder.AddAzureSqlServer("sql")
    .RunAsContainer();

if (builder.ExecutionContext.IsPublishMode)
{
    var sqlServerName = builder.AddParameter("sqlServerName");
    var sqlResourceGroup = builder.AddParameter("sqlResourceGroup");

    sql.PublishAsExisting(sqlServerName, sqlResourceGroup);
}

var ordersDb = sql.AddDatabase("orders");

// ---------------------------------------------------------------------------
// Backend API (ASP.NET Core). Published as an Azure Container App in
// multiple-revisions mode so blue and green revisions can coexist and traffic
// can be split by label. External ingress lets the candidate revision's label
// FQDN be validated directly during a blue/green rollout.
// ---------------------------------------------------------------------------
var api = builder.AddProject<Projects.AspireBlueGreen_Api>("api")
    .WithReference(ordersDb)
    .WithEnvironment("APP_VERSION", appVersion)
    .WithExternalHttpEndpoints()
    .PublishAsAzureContainerApp((infra, app) =>
    {
        ConfigureBlueGreen(infra, app, "api",
            appVersion, productionLabel!, blueRevisionSuffix!, greenRevisionSuffix!);
    });

// ---------------------------------------------------------------------------
// Frontend (React + Vite). Two GA paths depending on execution context:
//   - Run  (aspire run): the Vite dev server (npm run dev) with a /api proxy
//     to the API (configured in vite.config.ts via service discovery env vars).
//   - Publish (azd):     a multi-stage nginx image (src/web/Dockerfile) that
//     serves the built SPA and reverse-proxies /api to the API. nginx reads the
//     API URL from the service-discovery env var injected by WithReference(api),
//     so the browser stays on a single origin and a revision label FQDN works
//     too. Published as an ACA app in multiple-revisions mode to mirror the API.
// ---------------------------------------------------------------------------
if (builder.ExecutionContext.IsRunMode)
{
    builder.AddViteApp("web", "../src/web")
        .WithReference(api)
        .WithEnvironment("APP_VERSION", appVersion)
        .WithExternalHttpEndpoints();
}
else
{
    builder.AddDockerfile("web", "../src/web")
        .WithReference(api)
        .WithBuildArg("APP_VERSION", appVersion)
        .WithHttpEndpoint(targetPort: 8080)
        .WithExternalHttpEndpoints()
        .PublishAsAzureContainerApp((infra, app) =>
        {
            ConfigureBlueGreen(infra, app, "web",
                appVersion, productionLabel!, blueRevisionSuffix!, greenRevisionSuffix!);
        });
}

builder.Build().Run();

// ---------------------------------------------------------------------------
// Emits DECLARATIVE blue/green ingress traffic + a deterministic revision suffix
// into the generated Container App bicep, driven entirely by azd parameters.
//
// Why declarative (not a post-deploy hook): `azd deploy`/ARM rewrites the
// container app's ingress.traffic on every deploy. If traffic is only patched
// afterwards by a script, there is a window where the freshly built revision
// takes 100% of production. By DECLARING traffic in bicep, the candidate color
// is pinned at 0% by the same deployment that creates it -> zero prod exposure.
//
// Generated bicep (per app):
//   var trafficWeights = concat(
//     empty(blueRevisionSuffix)  ? [] : [ { revisionName:'<app>--${blueRevisionSuffix}',  label:'blue',  weight: productionLabel=='blue'?100:0,  latestRevision:false } ],
//     empty(greenRevisionSuffix) ? [] : [ { revisionName:'<app>--${greenRevisionSuffix}', label:'green', weight: productionLabel=='green'?100:0, latestRevision:false } ])
//   ...
//   template.revisionSuffix = deployRevisionSuffix
//   ingress.traffic         = trafficWeights
// ---------------------------------------------------------------------------
static void ConfigureBlueGreen(
    AzureResourceInfrastructure infra,
    ContainerApp app,
    string appName,
    IResourceBuilder<ParameterResource> appVersion,
    IResourceBuilder<ParameterResource> productionLabel,
    IResourceBuilder<ParameterResource> blueRevisionSuffix,
    IResourceBuilder<ParameterResource> greenRevisionSuffix)
{
    app.Configuration.ActiveRevisionsMode = ContainerAppActiveRevisionsMode.Multiple;

    var appVer = appVersion.AsProvisioningParameter(infra, "appVersion");
    var prodLabel = productionLabel.AsProvisioningParameter(infra, "productionLabel");
    var blueSuffix = blueRevisionSuffix.AsProvisioningParameter(infra, "blueRevisionSuffix");
    var greenSuffix = greenRevisionSuffix.AsProvisioningParameter(infra, "greenRevisionSuffix");

    // The revision created by THIS deploy gets a deterministic, version-derived suffix
    // ('v' + appVersion with '.' -> '-', e.g. 1.0.0 => v1-0-0) so the declarative
    // traffic block can reference revisions by predictable name. Bumping appVersion is
    // therefore enough to mint a new revision; the candidate color's *RevisionSuffix
    // param is set to the same value by the deploy script.
    app.Template.RevisionSuffix = new InterpolatedStringExpression(
    [
        new StringLiteralExpression("v"),
        new FunctionCallExpression(
            new IdentifierExpression("replace"),
            new IdentifierExpression(appVer.BicepIdentifier),
            new StringLiteralExpression("."),
            new StringLiteralExpression("-")),
    ]);

    var prodLabelId = new IdentifierExpression(prodLabel.BicepIdentifier);
    var blueId = new IdentifierExpression(blueSuffix.BicepIdentifier);
    var greenId = new IdentifierExpression(greenSuffix.BicepIdentifier);

    // One traffic entry for a color, included only when its suffix param is non-empty.
    // weight = (productionLabel == '<color>') ? 100 : 0  => candidate is always parked at 0%.
    static BicepExpression ColorEntry(string appName, string color, IdentifierExpression suffixId, IdentifierExpression prodLabelId) =>
        new ArrayExpression(
            new ObjectExpression(
                new PropertyExpression("revisionName", new InterpolatedStringExpression(
                    [new StringLiteralExpression($"{appName}--"), suffixId])),
                new PropertyExpression("label", new StringLiteralExpression(color)),
                new PropertyExpression("weight", new ConditionalExpression(
                    new BinaryExpression(prodLabelId, BinaryBicepOperator.Equal, new StringLiteralExpression(color)),
                    new IntLiteralExpression(100),
                    new IntLiteralExpression(0))),
                new PropertyExpression("latestRevision", new BoolLiteralExpression(false))));

    // concat( empty(blueSuffix) ? [] : [blueEntry], empty(greenSuffix) ? [] : [greenEntry] )
    var trafficExpr = new FunctionCallExpression(
        new IdentifierExpression("concat"),
        new ConditionalExpression(
            new FunctionCallExpression(new IdentifierExpression("empty"), blueId),
            new ArrayExpression(),
            ColorEntry(appName, "blue", blueId, prodLabelId)),
        new ConditionalExpression(
            new FunctionCallExpression(new IdentifierExpression("empty"), greenId),
            new ArrayExpression(),
            ColorEntry(appName, "green", greenId, prodLabelId)));

    // BicepList<T>(BicepExpression) is private; route the raw expression through a
    // ProvisioningVariable, which has an implicit conversion to BicepList<T>.
    var trafficVar = new ProvisioningVariable("trafficWeights", typeof(object[]))
    {
        Value = trafficExpr,
    };
    infra.Add(trafficVar);
    app.Configuration.Ingress.Traffic = trafficVar;
}
