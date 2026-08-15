using Microsoft.Extensions.Configuration;
using MangosSuperUI.Services;

// One-shot CLI that forces the MSUI wiki indexer to re-scan its corpus
// and populate the docs_* tables in vmangos_admin. Run after adding
// or removing files under vendor/MangosSuperUI/docs_full/.
//
// Usage (from repo root):
//   dotnet run --project scripts/wiki-reindex
//
// Connection defaults match the docker-compose stack: mariadb on localhost,
// vmangos_admin schema, user 'mangos' / pw 'mangos'. Override via env:
//   WIKI_ROOT=/abs/path/to/docs_full
//   WIKI_ADMIN_CONN='Server=...;Port=...;Database=...;User=...;Password=...;'

var wikiRoot = Environment.GetEnvironmentVariable("WIKI_ROOT")
    ?? Path.GetFullPath(Path.Combine(Directory.GetCurrentDirectory(), "vendor", "MangosSuperUI", "docs_full"));

var adminConn = Environment.GetEnvironmentVariable("WIKI_ADMIN_CONN")
    ?? "Server=127.0.0.1;Port=3306;Database=vmangos_admin;User=mangos;Password=mangos;";

if (!Directory.Exists(wikiRoot))
{
    Console.Error.WriteLine($"WIKI_ROOT does not exist: {wikiRoot}");
    return 1;
}

var inMem = new Dictionary<string, string?>
{
    ["Wiki:Root"] = wikiRoot,
    ["ConnectionStrings:admin"] = adminConn,
};

var config = new ConfigurationBuilder()
    .AddInMemoryCollection(inMem)
    .Build();

// Reflectively call WikiIndexer.ForceReindex so we can also reach the
// internal RunAsync method via reflection — that way exceptions bubble
// straight to our console instead of being swallowed into _status.
var indexer = new WikiIndexer(config);
var runMethod = typeof(WikiIndexer).GetMethod("RunAsync",
    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);

if (runMethod is null)
{
    Console.Error.WriteLine("Could not reflect WikiIndexer.RunAsync — SDK shape changed?");
    return 4;
}

var startedAt = DateTimeOffset.UtcNow;
Console.WriteLine($"Reindexing wiki corpus at: {wikiRoot}");
Console.WriteLine($"Admin connection: {ScrubPassword(adminConn)}");
Console.WriteLine($"Started at: {startedAt:o}");

// Drive the reindex directly — ForceReindex fires-and-forgets into
// Task.Run, whose catch swallows exceptions into _status.LastError.
// Awaiting RunAsync would return success even on failure, so we have
// to inspect the task's fault state directly.
var task = (Task)runMethod.Invoke(indexer, new object[] { true })!;

Console.WriteLine("Indexing… (Ctrl+C to abort; the indexer will keep its partial state)");

// Poll status while the task runs, then inspect the task's terminal
// state — including its caught exception, if any — when it finishes.
var pollDeadline = DateTime.UtcNow.AddMinutes(20);
while (!task.IsCompleted)
{
    var s = indexer.Status;
    if (s.Building)
    {
        var pct = s.Total > 0 ? (s.Done * 100.0 / s.Total) : 0;
        Console.Write($"\rIndexing… {s.Done}/{s.Total} ({pct,5:F1}%)   ");
    }
    if (DateTime.UtcNow > pollDeadline)
    {
        Console.Error.WriteLine($"\nTimed out after 20 minutes waiting for the task.");
        return 6;
    }
    Thread.Sleep(500);
}
Console.WriteLine();

if (task.IsFaulted)
{
    Console.Error.WriteLine($"Indexing faulted after {DateTimeOffset.UtcNow - startedAt}:");
    Console.Error.WriteLine(task.Exception?.GetBaseException());
    return 5;
}

var elapsed = DateTimeOffset.UtcNow - startedAt;
var sFinal = indexer.Status;
if (sFinal.LastError is { } err)
{
    Console.Error.WriteLine($"Indexing reported an error after {elapsed.TotalSeconds:F1}s: {err}");
    return 5;
}
Console.WriteLine($"Done. pages={sFinal.Done} elapsed={elapsed.TotalSeconds:F1}s");
return 0;

static string ScrubPassword(string connStr)
{
    var parts = connStr.Split(';', StringSplitOptions.RemoveEmptyEntries);
    for (var i = 0; i < parts.Length; i++)
        if (parts[i].StartsWith("Password=", StringComparison.OrdinalIgnoreCase))
            parts[i] = "Password=***";
    return string.Join(';', parts);
}
