using Azure.Provisioning.AppContainers;

var builder = DistributedApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// External resource references (supplied by scripts/up.ps1 via `azd env set`
// from the platform/ Bicep deployment outputs). These are only consumed during
// `azd` publish; local `aspire run` does not need them.
// ---------------------------------------------------------------------------
var infrastructureSubnetId = builder.AddParameter("infrastructureSubnetId");
var sqlServerName = builder.AddParameter("sqlServerName");
var sqlResourceGroup = builder.AddParameter("sqlResourceGroup");

// Release version surfaced by /api/version (API) and the web banner ("Web
// version"). Bump it per deploy with `azd env set appVersion <x>`; it defaults
// to 1.0.0 for local `aspire run` and for the first deploy. Wired into the api
// container env AND the web image build arg below (both as APP_VERSION) so both
// tiers report the same version (and both get a fresh revision) on a change.
var appVersion = builder.AddParameter("appVersion", "1.0.0", publishValueAsDefault: true);

// ---------------------------------------------------------------------------
// Azure Container Apps environment.
//   - Local: not used (resources run as processes/containers).
//   - Azure: created by Aspire. We join it to the pre-existing platform VNet
//     subnet so it lives behind the same network as Front Door / SQL.
// ---------------------------------------------------------------------------
builder.AddAzureContainerAppEnvironment("acaenv")
    .ConfigureInfrastructure(infra =>
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

// ---------------------------------------------------------------------------
// SQL Database (external resource).
//   - Local: a SQL Server container (no Azure required for `aspire run`).
//   - Azure: an existing Azure SQL server created by platform/ Bicep.
// The "orders" database powers the /api/orders demo only; /api/version never
// touches SQL so the app stays up even before passwordless access is granted.
// ---------------------------------------------------------------------------
var sql = builder.AddAzureSqlServer("sql")
    .RunAsContainer()
    .PublishAsExisting(sqlServerName, sqlResourceGroup);

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
        app.Configuration.ActiveRevisionsMode = ContainerAppActiveRevisionsMode.Multiple;
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
            app.Configuration.ActiveRevisionsMode = ContainerAppActiveRevisionsMode.Multiple;
        });
}

builder.Build().Run();
