// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using AutoSignIn;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.Linq;
using System.Text.Json;
using System.Threading;

var builder = WebApplication.CreateBuilder(args);

// Enable detailed logging for OAuth debugging
builder.Logging.SetMinimumLevel(LogLevel.Debug);
builder.Logging.AddFilter("Microsoft.Agents", LogLevel.Debug);
builder.Logging.AddFilter("AutoSignIn", LogLevel.Debug);

builder.Configuration
    .AddJsonFile("appsettings.local.json", optional: true, reloadOnChange: true);
    
builder.Services.AddHttpClient();

// Register IStorage.  For development, MemoryStorage is suitable.
// For production Agents, persisted storage should be used so
// that state survives Agent restarts, and operates correctly
// in a cluster of Agent instances.
builder.Services.AddSingleton<IStorage, MemoryStorage>();

// Add AgentApplicationOptions from appsettings section "AgentApplication".
builder.AddAgentApplicationOptions();

// Add the AgentApplication, which contains the logic for responding to
// user messages.
builder.AddAgent<AuthAgent>();

builder.Services.Configure<WorkflowOptions>(builder.Configuration.GetSection("Workflow"));

builder.Services.AddControllers();
builder.Services.AddAgentAspNetAuthentication(builder.Configuration);

WebApplication app = builder.Build();

// Enable AspNet authentication and authorization
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/", () => "Logic Apps Bot BE Sample");

// Diagnostic endpoint to check SDK version and configuration
app.MapGet("/diag", (ILogger<Program> logger) =>
{
    var builderAssembly = typeof(AutoSignIn.AuthAgent).Assembly.GetReferencedAssemblies()
        .FirstOrDefault(a => a.Name == "Microsoft.Agents.Builder");
    var hostingAssembly = typeof(AutoSignIn.AuthAgent).Assembly.GetReferencedAssemblies()
        .FirstOrDefault(a => a.Name == "Microsoft.Agents.Hosting.AspNetCore");
    
    var diag = new
    {
        SDKVersions = new
        {
            AgentsBuilder = builderAssembly?.Version?.ToString() ?? "unknown",
            AgentsHostingAspNetCore = hostingAssembly?.Version?.ToString() ?? "unknown"
        },
        Environment = app.Environment.EnvironmentName,
        Timestamp = System.DateTime.UtcNow
    };
    
    logger.LogInformation("[DIAG] Diagnostic endpoint called: {Diag}", JsonSerializer.Serialize(diag));
    return Results.Json(diag);
});

// This receives incoming messages from Azure Bot Service or other SDK Agents
var incomingRoute = app.MapPost("/api/messages", async (HttpRequest request, HttpResponse response, IAgentHttpAdapter adapter, IAgent agent, CancellationToken cancellationToken) =>
{
    var logger = request.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
    logger.LogWarning("[DIAG] /api/messages received - ContentType: {ContentType}, ContentLength: {Length}",
        request.ContentType, request.ContentLength);
    
    await adapter.ProcessAsync(request, response, agent, cancellationToken);
});

if (!app.Environment.IsDevelopment())
{
    incomingRoute.RequireAuthorization();
}
else
{
    // Hardcoded for brevity and ease of testing. 
    // In production, this should be set in configuration.
    app.Urls.Add($"http://localhost:3978");
}

app.Run();
