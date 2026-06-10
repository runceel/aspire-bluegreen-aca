using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// SQL is an *optional* demo dependency. /api/version never touches SQL, so the API
// must start cleanly even when SQL is not wired up yet. We register the Aspire SQL
// client only when a connection string is present and keep readiness independent
// from SQL availability (graceful degradation for the /api/orders demo).
var ordersConnection = builder.Configuration.GetConnectionString("orders");
var sqlConfigured = !string.IsNullOrWhiteSpace(ordersConnection);
if (sqlConfigured)
{
    builder.AddSqlServerClient(
        connectionName: "orders",
        configureSettings: settings => settings.DisableHealthChecks = true);
}

var app = builder.Build();

app.MapDefaultEndpoints();

// ---- Release identity ---------------------------------------------------------
// Edit COLOR and LABEL here (a code change = the new image) to roll a new
// blue/green version. The VERSION number comes from the APP_VERSION env var,
// wired in AppHost from the `appVersion` parameter; bump it per deploy with
// `azd env set appVersion <x>`. The front end paints its banner with COLOR and
// shows VERSION + LABEL.
const string Color = "#2563eb"; // blue
const string Label = "blue";
var version = builder.Configuration["APP_VERSION"] ?? "1.0.0";

app.MapGet("/", () => Results.Redirect("/api/version"));

// Dependency-free: always returns 200 so blue/green probes and the UI banner work
// regardless of SQL state.
app.MapGet("/api/version", () => Results.Ok(new
{
    version,
    color = Color,
    label = Label,
}));

// SQL demo with graceful degradation. Returns a `source` describing whether the
// data came from SQL or the in-memory fallback, so the demo works end-to-end even
// before passwordless SQL access is granted.
app.MapGet("/api/orders", async (IServiceProvider sp, CancellationToken ct) =>
{
    var sample = new[]
    {
        new Order(1001, "Contoso", 12800),
        new Order(1002, "Fabrikam", 4300),
        new Order(1003, "Adventure Works", 25600),
    };

    if (!sqlConfigured)
    {
        return Results.Ok(new OrdersResponse(false, "in-memory (SQL not configured)", sample));
    }

    // Bound the SQL attempt so the demo degrades *fast* when the database is
    // unreachable (e.g. SQL still starting, or access not yet granted) instead of
    // blocking on SqlClient's default connect timeout.
    using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
    timeoutCts.CancelAfter(TimeSpan.FromSeconds(5));
    try
    {
        await using var scope = sp.CreateAsyncScope();
        var conn = scope.ServiceProvider.GetRequiredService<SqlConnection>();
        await conn.OpenAsync(timeoutCts.Token);
        await EnsureSeedAsync(conn, sample, timeoutCts.Token);
        var rows = await QueryOrdersAsync(conn, timeoutCts.Token);
        return Results.Ok(new OrdersResponse(true, "sql", rows));
    }
    catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
    {
        var reason = ex is OperationCanceledException ? "timeout" : ex.GetType().Name;
        return Results.Ok(new OrdersResponse(true, $"in-memory (SQL unreachable: {reason})", sample));
    }
});

app.Run();

static async Task EnsureSeedAsync(SqlConnection conn, IReadOnlyList<Order> seed, CancellationToken ct)
{
    const string ddl = """
        IF OBJECT_ID('dbo.Orders', 'U') IS NULL
        CREATE TABLE dbo.Orders (
            Id INT PRIMARY KEY,
            Customer NVARCHAR(100) NOT NULL,
            Total INT NOT NULL
        );
        """;
    await using (var cmd = new SqlCommand(ddl, conn))
    {
        await cmd.ExecuteNonQueryAsync(ct);
    }

    await using (var check = new SqlCommand("SELECT COUNT(*) FROM dbo.Orders;", conn))
    {
        var count = Convert.ToInt32(await check.ExecuteScalarAsync(ct) ?? 0);
        if (count > 0)
        {
            return;
        }
    }

    foreach (var o in seed)
    {
        await using var ins = new SqlCommand(
            "INSERT INTO dbo.Orders (Id, Customer, Total) VALUES (@id, @customer, @total);", conn);
        ins.Parameters.AddWithValue("@id", o.Id);
        ins.Parameters.AddWithValue("@customer", o.Customer);
        ins.Parameters.AddWithValue("@total", o.Total);
        await ins.ExecuteNonQueryAsync(ct);
    }
}

static async Task<List<Order>> QueryOrdersAsync(SqlConnection conn, CancellationToken ct)
{
    var result = new List<Order>();
    await using var cmd = new SqlCommand("SELECT Id, Customer, Total FROM dbo.Orders ORDER BY Id;", conn);
    await using var reader = await cmd.ExecuteReaderAsync(ct);
    while (await reader.ReadAsync(ct))
    {
        result.Add(new Order(reader.GetInt32(0), reader.GetString(1), reader.GetInt32(2)));
    }
    return result;
}

record Order(int Id, string Customer, int Total);
record OrdersResponse(bool Configured, string Source, IReadOnlyList<Order> Orders);
