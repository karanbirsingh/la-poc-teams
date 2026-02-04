// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Builder.App.UserAuth;
using Microsoft.Agents.Builder.State;
using Microsoft.Agents.Builder.UserAuth;
using Microsoft.Agents.Core.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OktaDemo;

/// <summary>
/// Bot agent that demonstrates Okta OAuth authentication.
/// 
/// This bot:
/// 1. Authenticates users via Okta OAuth (through Azure Bot Service Generic OAuth 2 Provider)
/// 2. Retrieves the user's profile from Okta's /userinfo endpoint
/// 3. Displays the user's Okta identity
/// 
/// The Okta access token obtained here is available for downstream integrations.
/// </summary>
public class OktaAgent : AgentApplication
{
    private readonly ILogger<OktaAgent> _logger;
    private readonly string _oktaDomain;
    private readonly string _oktaUserInfoUrl;

    public OktaAgent(
        AgentApplicationOptions options,
        ILogger<OktaAgent> logger,
        IConfiguration configuration) : base(options)
    {
        _logger = logger;
        
        // Get Okta domain from configuration
        _oktaDomain = configuration["Okta:Domain"] ?? "";
        if (string.IsNullOrEmpty(_oktaDomain))
        {
            _logger.LogWarning("[OktaAgent] Okta:Domain not configured. Set it in appsettings.local.json");
            _oktaDomain = "your-org.okta.com";
        }
        _oktaUserInfoUrl = $"https://{_oktaDomain}/oauth2/default/v1/userinfo";

        _logger.LogInformation("[OktaAgent] Initialized. AutoSignIn={AutoSignIn}, DefaultHandler={Handler}, OktaDomain={Domain}",
            options.UserAuthorization?.AutoSignIn?.ToString() ?? "(not set)",
            options.UserAuthorization?.DefaultHandlerName ?? "(none)",
            _oktaDomain);

        // Welcome message when user joins
        OnConversationUpdate(ConversationUpdateEvents.MembersAdded, WelcomeMessageAsync);

        // Sign out command
        OnMessage("-signout", async (turnContext, turnState, cancellationToken) =>
        {
            await UserAuthorization.SignOutUserAsync(turnContext, turnState, cancellationToken: cancellationToken);
            await turnContext.SendActivityAsync("✅ You have signed out from Okta.", cancellationToken: cancellationToken);
        }, rank: RouteRank.First);

        // Show full profile command
        OnMessage("-me", OnMeAsync, rank: RouteRank.First);
        
        // Show token info command
        OnMessage("-token", OnTokenAsync, rank: RouteRank.First);

        // Default message handler - echo with Okta identity
        OnActivity(ActivityTypes.Message, OnMessageAsync, rank: RouteRank.Last);

        // Handle sign-in failures
        UserAuthorization.OnUserSignInFailure(OnUserSignInFailure);
    }

    private async Task WelcomeMessageAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        foreach (ChannelAccount member in turnContext.Activity.MembersAdded)
        {
            if (member.Id != turnContext.Activity.Recipient.Id)
            {
                StringBuilder sb = new();
                sb.AppendLine("👋 **Welcome to the Okta OAuth Demo Bot!**");
                sb.AppendLine();
                sb.AppendLine("This bot demonstrates Okta OAuth authentication.");
                sb.AppendLine();
                sb.AppendLine("**Commands:**");
                sb.AppendLine("- **-me**: Show your full Okta profile");
                sb.AppendLine("- **-token**: Show token information");
                sb.AppendLine("- **-signout**: Sign out from Okta");
                sb.AppendLine("- *Any message*: Echo back with your Okta identity");
                sb.AppendLine();
                sb.AppendLine("Send any message to get started! You'll be prompted to sign in with Okta.");
                await turnContext.SendActivityAsync(MessageFactory.Text(sb.ToString()), cancellationToken);
            }
        }
    }

    /// <summary>
    /// Handles the -me command - shows full Okta profile.
    /// </summary>
    private async Task OnMeAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        var token = await GetOktaTokenAsync(turnContext);
        if (string.IsNullOrEmpty(token))
        {
            await turnContext.SendActivityAsync("❌ No token available. Please sign in first.", cancellationToken: cancellationToken);
            return;
        }

        var userInfo = await GetOktaUserInfoAsync(token, cancellationToken);
        if (userInfo == null)
        {
            await turnContext.SendActivityAsync("❌ Failed to get user info from Okta. Token may be invalid.", cancellationToken: cancellationToken);
            return;
        }

        var info = userInfo.Value;
        StringBuilder sb = new();
        sb.AppendLine("📋 **Your Okta Profile:**");
        sb.AppendLine();

        if (info.TryGetProperty("name", out var name))
            sb.AppendLine($"**Name:** {name.GetString()}");
        if (info.TryGetProperty("email", out var email))
            sb.AppendLine($"**Email:** {email.GetString()}");
        if (info.TryGetProperty("preferred_username", out var username))
            sb.AppendLine($"**Username:** {username.GetString()}");
        if (info.TryGetProperty("sub", out var sub))
            sb.AppendLine($"**Subject (sub):** {sub.GetString()}");
        if (info.TryGetProperty("email_verified", out var emailVerified))
            sb.AppendLine($"**Email Verified:** {emailVerified.GetBoolean()}");

        await turnContext.SendActivityAsync(MessageFactory.Text(sb.ToString()), cancellationToken);
    }

    /// <summary>
    /// Handles the -token command - shows token information.
    /// </summary>
    private async Task OnTokenAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        var token = await GetOktaTokenAsync(turnContext);
        if (string.IsNullOrEmpty(token))
        {
            await turnContext.SendActivityAsync("❌ No token available. Please sign in first.", cancellationToken: cancellationToken);
            return;
        }

        StringBuilder sb = new();
        sb.AppendLine("🔑 **Okta Access Token Info:**");
        sb.AppendLine();
        sb.AppendLine($"**Token Length:** {token.Length} characters");
        sb.AppendLine($"**Token Preview:** {token.Substring(0, Math.Min(50, token.Length))}...");
        sb.AppendLine();
        sb.AppendLine("This token can be used for:");
        sb.AppendLine("- Calling Okta APIs (e.g., /userinfo)");
        sb.AppendLine("- Passing to downstream services via headers");
        sb.AppendLine("- Validating user identity");

        await turnContext.SendActivityAsync(MessageFactory.Text(sb.ToString()), cancellationToken);
    }

    /// <summary>
    /// Default message handler - echoes message with Okta user identity.
    /// </summary>
    private async Task OnMessageAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        _logger.LogInformation("[OktaAgent] Message received: {Text}", turnContext.Activity.Text);

        var token = await GetOktaTokenAsync(turnContext);
        if (string.IsNullOrEmpty(token))
        {
            await turnContext.SendActivityAsync("❌ Could not get Okta token. Please try again.", cancellationToken: cancellationToken);
            return;
        }

        var userInfo = await GetOktaUserInfoAsync(token, cancellationToken);
        var displayName = "Unknown User";
        var email = "";
        
        if (userInfo.HasValue)
        {
            if (userInfo.Value.TryGetProperty("name", out var nameProp))
                displayName = nameProp.GetString() ?? displayName;
            if (userInfo.Value.TryGetProperty("email", out var emailProp))
                email = emailProp.GetString() ?? "";
        }

        StringBuilder sb = new();
        sb.AppendLine($"✅ **Authenticated as:** {displayName}");
        if (!string.IsNullOrEmpty(email))
            sb.AppendLine($"📧 **Email:** {email}");
        sb.AppendLine();
        sb.AppendLine($"**You said:** {turnContext.Activity.Text}");
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine("*Okta OAuth is working! Use `-me` for full profile, `-token` for token info, or `-signout` to sign out.*");

        await turnContext.SendActivityAsync(MessageFactory.Text(sb.ToString()), cancellationToken);
    }

    /// <summary>
    /// Gets the Okta access token from the current turn.
    /// </summary>
    private async Task<string?> GetOktaTokenAsync(ITurnContext turnContext)
    {
        try
        {
            var token = await UserAuthorization.GetTurnTokenAsync(turnContext, UserAuthorization.DefaultHandlerName);
            _logger.LogInformation("[OktaAgent] Token retrieved (length={Length})", token?.Length ?? 0);
            return token;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[OktaAgent] GetTurnTokenAsync failed");
            return null;
        }
    }

    /// <summary>
    /// Calls Okta /userinfo endpoint to get user profile.
    /// </summary>
    private async Task<JsonElement?> GetOktaUserInfoAsync(string accessToken, CancellationToken cancellationToken)
    {
        try
        {
            using var httpClient = new HttpClient();
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            var response = await httpClient.GetAsync(_oktaUserInfoUrl, cancellationToken);
            
            if (response.IsSuccessStatusCode)
            {
                var json = await response.Content.ReadAsStringAsync(cancellationToken);
                return JsonDocument.Parse(json).RootElement;
            }

            _logger.LogWarning("[OktaAgent] Okta userinfo failed: {Status} - {Error}", 
                response.StatusCode, 
                await response.Content.ReadAsStringAsync(cancellationToken));
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[OktaAgent] Failed to get Okta userinfo");
            return null;
        }
    }

    /// <summary>
    /// Handles sign-in failures.
    /// </summary>
    private async Task OnUserSignInFailure(ITurnContext turnContext, ITurnState turnState, string handlerName, SignInResponse response, IActivity initiatingActivity, CancellationToken cancellationToken)
    {
        _logger.LogWarning("[OktaAgent] Sign-in failed for handler {Handler}: {Cause} - {Error}",
            handlerName, response.Cause, response.Error?.Message);

        await turnContext.SendActivityAsync(
            $"❌ Sign-in failed: {response.Error?.Message ?? response.Cause.ToString()}. Please try again.",
            cancellationToken: cancellationToken);
    }
}
