// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using A2A;
using AutoSignIn.Infrastructure;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Builder.App.UserAuth;
using Microsoft.Agents.Builder.State;
using Microsoft.Agents.Builder.UserAuth;
using Microsoft.Agents.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AutoSignIn;

/// <summary>
/// Bot agent that:
/// 1. Authenticates users via Okta OAuth (through Azure Bot Service Generic OAuth 2 Provider)
/// 2. Passes the Okta access token to Logic Apps via x-ms-obo-usertoken header
/// 3. Logic Apps validates the token via Easy Auth (configured for Okta as custom OIDC provider)
/// </summary>
public class AuthAgent : AgentApplication
{
    private readonly ILogger<AuthAgent> _logger;
    private readonly ILoggerFactory _loggerFactory;
    private readonly string _workflowName;
    private readonly string _agentUrl;        // full workflow URL
    private readonly string _serviceBaseUrl;  // base without workflow segment

    // Okta userinfo endpoint - must match the authorization server used in Azure Bot OAuth connection
    private const string OktaUserInfoUrl = "https://integrator-7620286.okta.com/oauth2/default/v1/userinfo";

    public AuthAgent(
        AgentApplicationOptions options,
        ILogger<AuthAgent> logger,
        ILoggerFactory loggerFactory,
        IOptions<WorkflowOptions> workflowOptions) : base(options)
    {
        _logger = logger;
        _loggerFactory = loggerFactory;
        var wf = workflowOptions.Value;
        _agentUrl = wf.AgentUrl?.TrimEnd('/') ?? string.Empty;
        _workflowName = wf.WorkflowName;
        _serviceBaseUrl = wf.ServiceBaseUrl;

        _logger.LogInformation("[AuthAgent] Initialized. AutoSignIn={AutoSignIn}, DefaultHandler={Handler}, WorkflowUrl={Url}",
            options.UserAuthorization?.AutoSignIn?.ToString() ?? "(not set)",
            options.UserAuthorization?.DefaultHandlerName ?? "(none)",
            _agentUrl);

        OnConversationUpdate(ConversationUpdateEvents.MembersAdded, WelcomeMessageAsync);

        // Handles the user sending a SignOut command using the specific keywords '-signout'
        OnMessage("-signout", async (turnContext, turnState, cancellationToken) =>
        {
            await UserAuthorization.SignOutUserAsync(turnContext, turnState, cancellationToken: cancellationToken);
            await turnContext.SendActivityAsync("You have signed out", cancellationToken: cancellationToken);
        }, rank: RouteRank.Last);

        // Handle -me command to show user info from Okta
        OnMessage("-me", OnMeAsync, rank: RouteRank.First);

        // General message handler
        OnActivity(ActivityTypes.Message, OnMessageAsync, rank: RouteRank.Last);

        UserAuthorization.OnUserSignInFailure(OnUserSignInFailure);
    }

    private async Task WelcomeMessageAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        foreach (ChannelAccount member in turnContext.Activity.MembersAdded)
        {
            if (member.Id != turnContext.Activity.Recipient.Id)
            {
                StringBuilder sb = new();
                sb.AppendLine("👋 **Welcome to the Okta + Logic Apps Demo Bot!**");
                sb.AppendLine();
                sb.AppendLine("This bot demonstrates OAuth authentication with Okta and Logic Apps integration.");
                sb.AppendLine();
                sb.AppendLine("**Commands:**");
                sb.AppendLine("- **-me**: Show your Okta user info");
                sb.AppendLine("- **-signout**: Sign out and reset the OAuth flow");
                sb.AppendLine("- *Any other message*: Send to Logic Apps workflow");
                await turnContext.SendActivityAsync(MessageFactory.Text(sb.ToString()), cancellationToken);
            }
        }
    }

    /// <summary>
    /// Handles the -me command - fetches detailed user info from Okta userinfo endpoint.
    /// </summary>
    private async Task OnMeAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        string token;
        try
        {
            token = await UserAuthorization.GetTurnTokenAsync(turnContext, UserAuthorization.DefaultHandlerName);
            if (string.IsNullOrEmpty(token))
            {
                await turnContext.SendActivityAsync("No token available. Please sign in first.", cancellationToken: cancellationToken);
                return;
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[AuthAgent] GetTurnTokenAsync failed");
            await turnContext.SendActivityAsync($"Could not get token: {ex.Message}", cancellationToken: cancellationToken);
            return;
        }

        var userInfo = await GetOktaUserInfoAsync(token, cancellationToken);
        if (userInfo == null)
        {
            await turnContext.SendActivityAsync("Failed to get user info from Okta. Token may be invalid.", cancellationToken: cancellationToken);
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

    private async Task OnMessageAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        _logger.LogInformation("[AuthAgent] Message received from channel: {Channel}, Text: {Text}",
            turnContext.Activity.ChannelId,
            turnContext.Activity.Text);

        string token;
        try
        {
            _logger.LogInformation("[AuthAgent] Getting token for handler: {Handler}", UserAuthorization.DefaultHandlerName);
            token = await UserAuthorization.GetTurnTokenAsync(turnContext, UserAuthorization.DefaultHandlerName);
            _logger.LogInformation("[AuthAgent] Token retrieved (length={Length})", token?.Length ?? 0);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[AuthAgent] GetTurnTokenAsync FAILED");
            await turnContext.SendActivityAsync($"Could not get bearer token: {ex.Message}", cancellationToken: cancellationToken);
            return;
        }

        // If no Logic Apps URL configured, just echo with Okta user info
        if (string.IsNullOrEmpty(_agentUrl))
        {
            _logger.LogInformation("[AuthAgent] No Logic Apps URL configured, using Okta userinfo only");
            var userInfo = await GetOktaUserInfoAsync(token!, cancellationToken);
            var displayName = "Unknown User";
            if (userInfo.HasValue && userInfo.Value.TryGetProperty("name", out var nameProp))
            {
                displayName = nameProp.GetString() ?? displayName;
            }
            await turnContext.SendActivityAsync($"**{displayName} said:** {turnContext.Activity.Text}", cancellationToken: cancellationToken);
            return;
        }

        // Send to Logic Apps
        var timestampHandler = new A2ATimestampRewriteHandler(_loggerFactory.CreateLogger<A2ATimestampRewriteHandler>())
        {
            InnerHandler = new HttpClientHandler()
        };
        var httpClient = new HttpClient(timestampHandler);
        httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        httpClient.DefaultRequestHeaders.Add("x-ms-obo-usertoken", "Bearer " + token);

        // RPC client works at service base (without workflow name)
        var rpc = new AgentContextRpcClient(httpClient, _serviceBaseUrl);

        // IMPORTANT: keep lookup limited to UNARCHIVED contexts (includeArchived = false)
        var contexts = await rpc.ListContextsAsync(
            _workflowName,
            new { limit = 1000, includeArchived = false, includeLastTask = false },
            cancellationToken);

        var conversationId = turnContext.Activity.Conversation.Id;

        // Gather contexts for this conversation
        var allForConversation = contexts.Contexts
            .EnumerateArray()
            .Where(e => e.TryGetProperty("name", out var nameProp) &&
                        nameProp.GetString() == conversationId)
            .ToList();

        var terminalStatuses = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Cancelled", "Failed", "Terminated", "Aborted", "TimedOut"
        };

        // First available non-terminal context (treat missing status as non-terminal)
        var activeContext = allForConversation.FirstOrDefault(e =>
            !e.TryGetProperty("status", out var statusProp) ||
            !terminalStatuses.Contains(statusProp.GetString() ?? string.Empty));

        string? contextId;
        if (activeContext.ValueKind != JsonValueKind.Undefined)
        {
            // Use the non-terminal context
            contextId = activeContext.GetProperty("id").GetString();
        }
        else if (allForConversation.Count > 0)
        {
            // There are contexts for this conversation but all are terminal -> reset and create a new one
            await turnContext.SendActivityAsync(
                "Resetting context as prior conversation reached terminal state. New chat beginning...",
                cancellationToken: cancellationToken);

            var updated = await rpc.CreateAndNameContextAsync(
                _workflowName,
                conversationId,
                createArgs: null,
                isArchived: null,
                cancellationToken);
            contextId = updated.Id;

            await turnContext.SendActivityAsync("Please send a new message.", cancellationToken: cancellationToken);

            return;
        }
        else
        {
            // No contexts exist for this conversation -> create without extra message
            var updated = await rpc.CreateAndNameContextAsync(
                _workflowName,
                conversationId,
                createArgs: null,
                isArchived: null,
                cancellationToken);
            contextId = updated.Id;
        }

        try
        {
            var a2aClient = new A2AClient(new Uri($"{_agentUrl}/"), httpClient);
            AgentTask initialTask;
            try
            {
                var agentMessage = new AgentMessage
                {
                    Role = MessageRole.User,
                    Parts = [new TextPart { Text = turnContext.Activity.Text }],
                    MessageId = Guid.NewGuid().ToString(),
                    ContextId = contextId
                };

                initialTask = (AgentTask)await a2aClient.SendMessageAsync(new MessageSendParams
                {
                    Message = agentMessage
                });
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[AuthAgent] Error sending message to agent");
                await turnContext.SendActivityAsync($"Error sending message to agent: {ex.GetType().Name}: {ex.Message} {ex.InnerException}", cancellationToken: cancellationToken);
                return;
            }

            AgentTask finalTask;
            try
            {
                finalTask = await PollTaskAsync(
                    a2aClient,
                    initialTask.Id,
                    pollInterval: TimeSpan.FromSeconds(1),
                    timeout: TimeSpan.FromSeconds(180),
                    cancellationToken: cancellationToken);
            }
            catch (OperationCanceledException)
            {
                await turnContext.SendActivityAsync("Task polling canceled.", cancellationToken: cancellationToken);
                return;
            }
            catch (TimeoutException)
            {
                await turnContext.SendActivityAsync($"Task {initialTask.Id} did not complete within timeout.", cancellationToken: cancellationToken);
                return;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[AuthAgent] Error polling task {TaskId}", initialTask.Id);
                await turnContext.SendActivityAsync($"The agent encountered an error. Debugging information: task {initialTask.Id}: {ex.Message}", cancellationToken: cancellationToken);
                return;
            }

            if (finalTask.Status.State == TaskState.AuthRequired)
            {
                await turnContext.SendActivityAsync("Task needs authentication. Please follow the upcoming instructions. Sign-in requests will always be preceded by this message.", cancellationToken: cancellationToken);
                string authText = finalTask.Status.Message?.Parts.OfType<TextPart>().FirstOrDefault()?.Text!;

                if (TryBuildAuthLinksMarkdown(authText, out var markdown))
                {
                    await turnContext.SendActivityAsync(markdown, cancellationToken: cancellationToken);
                }
                else
                {
                    // Fallback to original text if we couldn't parse the links
                    await turnContext.SendActivityAsync(authText, cancellationToken: cancellationToken);
                }
                return;
            }

            string artifactText = finalTask.Status.Message?.Parts.OfType<TextPart>().FirstOrDefault()?.Text!;
            await turnContext.SendActivityAsync(artifactText, cancellationToken: cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[AuthAgent] Error in Logic Apps flow");
            await turnContext.SendActivityAsync($"Error sending message to agent: {ex.GetType().Name}: {ex.Message} {ex.InnerException} {ex.StackTrace}", cancellationToken: cancellationToken);
        }
    }

    private static async Task<AgentTask> PollTaskAsync(
        A2AClient client,
        string taskId,
        TimeSpan? pollInterval = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var interval = pollInterval ?? TimeSpan.FromSeconds(1);
        var max = timeout ?? TimeSpan.FromSeconds(30);
        var sw = Stopwatch.StartNew();

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var retryCount = 5;
            AgentTask? current = null;
            while (retryCount > 0 && !cancellationToken.IsCancellationRequested)
            {
                retryCount--;
                try
                {
                    current = await client.GetTaskAsync(taskId, cancellationToken);
                    break;
                }
                catch (Exception)
                {
                    if (retryCount <= 0)
                        throw;
                    await Task.Delay(200, cancellationToken);
                }
            }

            if (IsCompletedOrAuthRequired(current))
                return current;

            if (sw.Elapsed > max)
                throw new TimeoutException($"Task {taskId} polling exceeded {max}.");

            await Task.Delay(interval, cancellationToken);
        }

        static bool IsCompletedOrAuthRequired(AgentTask task) =>
            (task.Status.Message != null && (task.Status.State == TaskState.Completed || task.Status.State == TaskState.Failed))
            || task.Status.State == TaskState.Canceled
            || task.Status.State == TaskState.Rejected
            || task.Status.State == TaskState.AuthRequired;
    }

    /// <summary>
    /// Calls the Okta /oauth2/default/v1/userinfo endpoint to get user information.
    /// </summary>
    private async Task<JsonElement?> GetOktaUserInfoAsync(string accessToken, CancellationToken cancellationToken)
    {
        try
        {
            using var httpClient = new HttpClient();
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

            var response = await httpClient.GetAsync(OktaUserInfoUrl, cancellationToken);
            if (response.IsSuccessStatusCode)
            {
                var content = await response.Content.ReadAsStringAsync(cancellationToken);
                return JsonDocument.Parse(content).RootElement;
            }

            _logger.LogWarning("[AuthAgent] Okta userinfo call failed: {Status} - {Reason}",
                response.StatusCode,
                await response.Content.ReadAsStringAsync(cancellationToken));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[AuthAgent] Error calling Okta userinfo endpoint");
        }

        return null;
    }

    private async Task OnUserSignInFailure(ITurnContext turnContext, ITurnState turnState, string handlerName, SignInResponse response, IActivity initiatingActivity, CancellationToken cancellationToken)
    {
        _logger.LogError("[AuthAgent] Sign-in failure - Handler: {Handler}, Cause: {Cause}, Error: {Error}",
            handlerName,
            response.Cause,
            response.Error?.Message);
        await turnContext.SendActivityAsync($"Sign In: Failed to login to '{handlerName}': {response.Cause}/{response.Error!.Message}", cancellationToken: cancellationToken);
    }

    // Parses the auth prompt text for a JSON array of link descriptors and builds a markdown list of hyperlinks.
    private static bool TryBuildAuthLinksMarkdown(string authPrompt, out string markdown)
    {
        markdown = string.Empty;
        if (string.IsNullOrWhiteSpace(authPrompt))
            return false;

        // Find the JSON array portion, e.g. "...: [ { ... }, { ... } ]."
        int start = authPrompt.IndexOf('[');
        int end = authPrompt.LastIndexOf(']');
        if (start < 0 || end <= start)
            return false;

        var json = authPrompt.Substring(start, end - start + 1);
        List<AuthLinkItem>? items;
        try
        {
            items = JsonSerializer.Deserialize<List<AuthLinkItem>>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });
        }
        catch
        {
            return false;
        }

        if (items == null || items.Count == 0)
            return false;

        var sb = new StringBuilder();
        sb.AppendLine("Please authenticate using the following link(s) and message when you're done:");
        foreach (var item in items)
        {
            if (string.IsNullOrWhiteSpace(item.Link))
                continue;

            var name = item.ApiDetails?.ApiDisplayName
                       ?? item.DisplayName
                       ?? TryGetHost(item.Link)
                       ?? "Authentication Link";

            if (!Uri.TryCreate(item.Link, UriKind.Absolute, out var uri))
                continue;

            var status = string.IsNullOrWhiteSpace(item.Status) ? string.Empty : $" — {item.Status}";
            sb.AppendLine($"- [{EscapeInlineMarkdown(name)}]({uri}){status}");
        }

        markdown = sb.ToString();
        return true;

        static string? TryGetHost(string? link)
            => Uri.TryCreate(link ?? string.Empty, UriKind.Absolute, out var u) ? u.Host : null;

        static string EscapeInlineMarkdown(string text)
            => text.Replace("[", "\\[").Replace("]", "\\]").Replace("(", "\\(").Replace(")", "\\)");
    }

    // DTOs for parsing the auth links payload
    private sealed class AuthLinkItem
    {
        public ApiDetails? ApiDetails { get; set; }
        public string? Link { get; set; }
        public string? FirstPartyLoginUri { get; set; }
        public string? DisplayName { get; set; }
        public string? Status { get; set; }
    }

    private sealed class ApiDetails
    {
        public string? ApiDisplayName { get; set; }
        public string? ApiIconUri { get; set; }
        public string? ApiBrandColor { get; set; }
    }
}
