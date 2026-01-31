// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

using A2A;
using AutoSignIn.Infrastructure;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Builder.App;
using Microsoft.Agents.Builder.App.UserAuth;
using Microsoft.Agents.Builder.State;
using Microsoft.Agents.Builder.UserAuth;
using Microsoft.Agents.Core;
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
public class AuthAgent : AgentApplication
{
    private readonly string _workflowName;
    private readonly string _agentUrl;        // full workflow URL
    private readonly string _serviceBaseUrl;  // base without workflow segment
    private readonly ILogger<AuthAgent> _logger;

    public AuthAgent(AgentApplicationOptions options, IOptions<WorkflowOptions> workflowOptions, ILogger<AuthAgent> logger) : base(options)
    {
        _logger = logger;
        var wf = workflowOptions.Value;
        _agentUrl = wf.AgentUrl.TrimEnd('/');
        _workflowName = wf.WorkflowName;
        _serviceBaseUrl = wf.ServiceBaseUrl;

        _logger.LogInformation("[DIAG] AuthAgent initialized. AutoSignIn={AutoSignIn}, DefaultHandler={Handler}",
            options.UserAuthorization?.AutoSignIn?.ToString() ?? "(not set)",
            options.UserAuthorization?.DefaultHandlerName ?? "(none)");

        OnConversationUpdate(ConversationUpdateEvents.MembersAdded, WelcomeMessageAsync);

        // Handles the user sending a SignOut command using the specific keywords '-signout'
        OnMessage("-signout", async (turnContext, turnState, cancellationToken) =>
        {
            await UserAuthorization.SignOutUserAsync(turnContext, turnState, cancellationToken: cancellationToken);
            await turnContext.SendActivityAsync("You have signed out", cancellationToken: cancellationToken);
        }, rank: RouteRank.Last);

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
                sb.AppendLine("Hello!");
                await turnContext.SendActivityAsync(MessageFactory.Text(sb.ToString()), cancellationToken);
                sb.Clear();
            }
        }
    }

    private async Task OnMessageAsync(ITurnContext turnContext, ITurnState turnState, CancellationToken cancellationToken)
    {
        // ===== DIAGNOSTIC LOGGING FOR OAUTH DEBUGGING =====
        var activity = turnContext.Activity;
        _logger.LogWarning("[DIAG] ========== INCOMING MESSAGE ==========");
        _logger.LogWarning("[DIAG] ChannelId (raw): {ChannelId}", activity.ChannelId);
        _logger.LogWarning("[DIAG] ChannelId.Channel: {Channel}", activity.ChannelId?.Channel);
        _logger.LogWarning("[DIAG] ChannelId.SubChannel: {SubChannel}", activity.ChannelId?.SubChannel);
        _logger.LogWarning("[DIAG] ChannelId.IsSubChannel: {IsSubChannel}", activity.ChannelId?.IsSubChannel());
        _logger.LogWarning("[DIAG] ChannelId.IsParentChannel(msteams): {IsParent}", activity.ChannelId?.IsParentChannel("msteams"));
        _logger.LogWarning("[DIAG] Activity.Type: {Type}", activity.Type);
        _logger.LogWarning("[DIAG] Activity.Text: {Text}", activity.Text);
        _logger.LogWarning("[DIAG] Activity.DeliveryMode: {DeliveryMode}", activity.DeliveryMode);
        _logger.LogWarning("[DIAG] Conversation.Id: {ConvId}", activity.Conversation?.Id);
        _logger.LogWarning("[DIAG] Conversation.TenantId: {TenantId}", activity.Conversation?.TenantId);
        _logger.LogWarning("[DIAG] Conversation.ConversationType: {ConvType}", activity.Conversation?.ConversationType);
        _logger.LogWarning("[DIAG] ServiceUrl: {ServiceUrl}", activity.ServiceUrl);
        _logger.LogWarning("[DIAG] From.Id: {FromId}", activity.From?.Id);
        _logger.LogWarning("[DIAG] From.AadObjectId: {AadId}", activity.From?.AadObjectId);
        // Note: AgenticUserId/AgenticAppId only available in v1.3.x+
        _logger.LogWarning("[DIAG] Recipient.Id: {RecipientId}", activity.Recipient?.Id);
        
        // Note: IsAgenticRequest() is only available in v1.3.x+
        // For v1.2.x, we check for ProductInfo entity manually
        
        // Check for ProductInfo entity (used by M365 Copilot)
        try
        {
            var productInfo = activity.GetProductInfoEntity();
            _logger.LogWarning("[DIAG] ProductInfoEntity: {ProductInfo}", productInfo != null ? $"Id={productInfo.Id}, Type={productInfo.Type}" : "(none)");
            // If ProductInfo with Id="COPILOT" exists, this is likely an M365 Copilot request
            var isLikelyCopilot = productInfo?.Id?.Equals("COPILOT", StringComparison.OrdinalIgnoreCase) == true;
            _logger.LogWarning("[DIAG] IsLikelyCopilotRequest (inferred): {IsLikelyCopilot}", isLikelyCopilot);
        }
        catch (Exception ex)
        {
            _logger.LogWarning("[DIAG] ProductInfoEntity check failed: {Error}", ex.Message);
        }
        
        // Check for Teams-specific channel data
        if (activity.ChannelData != null)
        {
            try
            {
                var channelDataJson = System.Text.Json.JsonSerializer.Serialize(activity.ChannelData);
                _logger.LogWarning("[DIAG] ChannelData (JSON): {ChannelData}", channelDataJson);
            }
            catch (Exception ex)
            {
                _logger.LogWarning("[DIAG] ChannelData serialization failed: {Error}", ex.Message);
            }
        }
        
        // Check activity.Entities for mentions, clientInfo, etc.
        if (activity.Entities != null && activity.Entities.Count > 0)
        {
            foreach (var entity in activity.Entities)
            {
                _logger.LogWarning("[DIAG] Entity Type: {EntityType}", entity.Type);
                if (entity.Type == "clientInfo" || entity.Type == "ProductInfo")
                {
                    try
                    {
                        var entityJson = System.Text.Json.JsonSerializer.Serialize(entity);
                        _logger.LogWarning("[DIAG] ClientInfo Entity: {Entity}", entityJson);
                    }
                    catch { }
                }
            }
        }
        _logger.LogWarning("[DIAG] ===========================================");
        // ===== END DIAGNOSTIC LOGGING =====

        string token;
        try
        {
            _logger.LogWarning("[DIAG] Calling UserAuthorization.GetTurnTokenAsync with handler: {Handler}", UserAuthorization.DefaultHandlerName);
            token = await UserAuthorization.GetTurnTokenAsync(turnContext, UserAuthorization.DefaultHandlerName);
            _logger.LogWarning("[DIAG] Token retrieved successfully (length={Length})", token?.Length ?? 0);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[DIAG] GetTurnTokenAsync FAILED: {Message}", ex.Message);
            await turnContext.SendActivityAsync($"Could not get bearer token: {ex.Message}", cancellationToken: cancellationToken);
            return;
        }

        var httpClient = new HttpClient(new A2ATimestampRewriteHandler
        {
            InnerHandler = new HttpClientHandler()
        });
        httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        httpClient.DefaultRequestHeaders.Add("x-ms-obo-usertoken", "Bearer " + token);

        /*
        // Agent card (workflow scoped) - retained (body not currently used)
        using HttpRequestMessage agentCardReq = new(HttpMethod.Get, $"{_agentUrl}/.well-known/agent-card.json");
        HttpResponseMessage agentCardResp = await httpClient.SendAsync(agentCardReq, cancellationToken);
        _ = await agentCardResp.Content.ReadAsStringAsync(cancellationToken);
        */

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

    private async Task OnUserSignInFailure(ITurnContext turnContext, ITurnState turnState, string handlerName, SignInResponse response, IActivity initiatingActivity, CancellationToken cancellationToken)
    {
        _logger.LogError("[DIAG] ========== SIGN-IN FAILURE ==========");
        _logger.LogError("[DIAG] Handler: {Handler}", handlerName);
        _logger.LogError("[DIAG] Cause: {Cause}", response.Cause);
        _logger.LogError("[DIAG] Error: {Error}", response.Error?.Message);
        _logger.LogError("[DIAG] ChannelId: {ChannelId}", turnContext.Activity.ChannelId);
        _logger.LogError("[DIAG] InitiatingActivity.Type: {Type}", initiatingActivity?.Type);
        _logger.LogError("[DIAG] ===========================================");
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
