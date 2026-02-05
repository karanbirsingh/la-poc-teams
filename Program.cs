// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

// Okta OAuth Demo Bot
// 
// This bot demonstrates Okta OAuth authentication in isolation.
// When you send a message, you'll be prompted to sign in with Okta,
// and the bot will display your Okta profile information.
//
// To use:
// 1. Run deploy-phase1.ps1 from config/okta-only/
// 2. dotnet run
// 3. Use devtunnel to expose locally, or run deploy-phase2.ps1 to deploy to Azure

using OktaDemo;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System.Threading;

var builder = WebApplication.CreateBuilder(args);

// Load local settings
builder.Configuration
    .AddJsonFile("appsettings.local.json", optional: true, reloadOnChange: true);

// Logging
builder.Logging.SetMinimumLevel(LogLevel.Information);
builder.Logging.AddFilter("Microsoft.Agents", LogLevel.Debug);
builder.Logging.AddFilter("OktaDemo", LogLevel.Debug);

builder.Services.AddHttpClient();

// Storage (in-memory for demo)
builder.Services.AddSingleton<IStorage, MemoryStorage>();

// Agent configuration from appsettings
builder.AddAgentApplicationOptions();

// Register the Okta agent
builder.AddAgent<OktaAgent>();

builder.Services.AddControllers();
builder.Services.AddAgentAspNetAuthentication(builder.Configuration);

WebApplication app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/", () => "🔐 Okta OAuth Demo Bot - Ready! Send a message in Teams or Web Chat to test.");

// Bot messaging endpoint
var incomingRoute = app.MapPost("/api/messages", async (HttpRequest request, HttpResponse response, IAgentHttpAdapter adapter, IAgent agent, CancellationToken cancellationToken) =>
{
    await adapter.ProcessAsync(request, response, agent, cancellationToken);
});

if (!app.Environment.IsDevelopment())
{
    incomingRoute.RequireAuthorization();
}
else
{
    // Only set URL for local development - IIS manages URLs in production
    app.Urls.Clear();
    app.Urls.Add("http://localhost:3978");
}

app.Run();
