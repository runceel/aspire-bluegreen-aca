using Aspire.Hosting.Azure;
using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Expressions;

var builder = DistributedApplication.CreateBuilder(args);

// Release version surfaced by /api/version (API) and the web banner ("Web
// version"). Bump it per deploy with script bluegreen-deploy.ps1. It defaults
// to 1.0.0 for local `aspire run`. Wired into the api container env (APP_VERSION)
// and the web build arg (both as APP_VERSION) so both tiers report the same
// version. It also DERIVES each app's revision suffix ('v' + appVersion,
// dots -> dashes) so a version bump mints a fresh blue/green revision.
var appVersion = builder.AddParameter("appVersion", "1.0.0", publishValueAsDefault: false);

// ---------------------------------------------------------------------------
// Blue/green deployment parameters (publish-only; never used by local `aspire
// run`). They drive the DECLARATIVE ingress traffic + deterministic revision
// suffix emitted into the api/web Container Apps (see ConfigureBlueGreen
// at the bottom of this file).
//   - productionLabel        : "blue" | "green" — the color currently at 100%.
//   - blueRevisionSuffix     : revision suffix carrying the blue version (e.g. v1-0-0); "" if absent.
//   - greenRevisionSuffix    : revision suffix carrying the green version; "" if absent.
// The suffix of the revision created by THIS deploy is DERIVED from appVersion
// ('v' + replace(appVersion, '.', '-')) so bumping appVersion is enough.
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
// Azure Container Apps environment (VNet-integrated).
//   - Local: not used (resources run as processes/containers).
//   - Azure: created with full VNet integration, joined to the platform VNet
//     subnet provisioned separately (via infra/main.bicep).
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
// SQL Database (external resource created by infra/main.bicep).
//   - Local: a SQL Server container (no Azure required for `aspire run`).
//   - Azure: an existing Azure SQL server created by infra/ Bicep.
// The "orders" database is created by Aspire (AddDatabase) on top of the
// existing server. /api/version never touches SQL, so the API must start
// cleanly even before passwordless access is granted.
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
// FQDN be validated directly during a blue/green rollout. Passwordless SQL
// access is configured via the generated api-roles-sql module.
// ---------------------------------------------------------------------------
var api = builder.AddProject<Projects.AspireBlueGreen_Api>("api")
    .WithReference(ordersDb)
    .WithEnvironment("APP_VERSION", appVersion)
    .WithExternalHttpEndpoints()
    .PublishAsAzureContainerApp((infra, app) =>
    {
        ConfigureBlueGreen(infra, app, "api",
            appVersion, productionLabel, blueRevisionSuffix, greenRevisionSuffix);
    });

// ---------------------------------------------------------------------------
// Frontend (React + Vite). Two GA paths depending on execution context:
//   - Run  (aspire run): the Vite dev server (npm run dev) with a /api proxy
//     to the API (configured in vite.config.ts via service discovery env vars).
//   - Publish (aspire publish): a multi-stage nginx image (src/web/Dockerfile)
//     that serves the built SPA and reverse-proxies /api to the API. nginx reads
//     the API URL from the service-discovery env var injected by WithReference(api),
//     so the browser stays on a single origin and a revision label FQDN works too.
//     Published as an ACA app in multiple-revisions mode to mirror the API.
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
                appVersion, productionLabel, blueRevisionSuffix, greenRevisionSuffix);
        });
}

builder.Build().Run();

// ---------------------------------------------------------------------------
// Emits DECLARATIVE blue/green ingress traffic + a deterministic revision suffix
// into the generated Container App bicep, driven entirely by azd parameters.
//
// Why declarative (not a post-deploy hook): `aspire publish` → `az deployment`
// rewrites the container app's ingress.traffic. If traffic is only patched
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
    IResourceBuilder<ParameterResource>? productionLabel,
    IResourceBuilder<ParameterResource>? blueRevisionSuffix,
    IResourceBuilder<ParameterResource>? greenRevisionSuffix)
{
    // Null check: only configure blue/green when in publish mode (parameters are non-null)
    if (productionLabel == null || blueRevisionSuffix == null || greenRevisionSuffix == null)
        return;

    app.Configuration.ActiveRevisionsMode = ContainerAppActiveRevisionsMode.Multiple;

    var appVer = appVersion.AsProvisioningParameter(infra, "appVersion");
    var prodLabel = productionLabel.AsProvisioningParameter(infra, "productionLabel");
    var blueSuffix = blueRevisionSuffix.AsProvisioningParameter(infra, "blueRevisionSuffix");
    var greenSuffix = greenRevisionSuffix.AsProvisioningParameter(infra, "greenRevisionSuffix");

    // The revision created by THIS deploy gets a deterministic, version-derived suffix
    // ('v' + appVersion with '.' -> '-', e.g. 1.0.0 => v1-0-0) so the declarative
    // traffic block can reference revisions by predictable name.
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
