using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace AutoSignIn.Infrastructure
{
    /// <summary>
    /// Lean JSON-RPC 2.0 client. Posts to {baseAgentsUrl}/{flowName}/
    /// Uses only: jsonrpc, id, method, params.
    /// </summary>
    public sealed class AgentContextRpcClient
    {
        private readonly HttpClient _http;
        private readonly Uri _baseAgentsUri;
        private readonly JsonSerializerOptions _jsonOptions;

        // Adaptive flag: if server rejects "params", we fallback to sending no args.
        private volatile bool _rejectsParams;

        public AgentContextRpcClient(HttpClient httpClient, string baseAgentsUrl)
        {
            _http = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
            if (string.IsNullOrWhiteSpace(baseAgentsUrl)) throw new ArgumentNullException(nameof(baseAgentsUrl));
            _baseAgentsUri = new Uri(baseAgentsUrl.TrimEnd('/') + "/");
            _jsonOptions = new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
            };
        }

        #region JSON-RPC DTOs

        private sealed class JsonRpcRequest
        {
            [JsonPropertyName("jsonrpc")] public string JsonRpc { get; set; } = "2.0";
            [JsonPropertyName("id")] public string Id { get; set; } = default!;
            [JsonPropertyName("method")] public string Method { get; set; } = default!;
            [JsonPropertyName("params")] public object? Params { get; set; }
        }

        private sealed record JsonRpcError(
            [property: JsonPropertyName("code")] JsonElement CodeRaw,
            [property: JsonPropertyName("message")] string Message,
            [property: JsonPropertyName("data")] JsonElement? Data)
        {
            [JsonIgnore]
            public string Code =>
                CodeRaw.ValueKind switch
                {
                    JsonValueKind.Number => CodeRaw.TryGetInt32(out var i) ? i.ToString() : CodeRaw.GetRawText(),
                    JsonValueKind.String => CodeRaw.GetString() ?? "Unknown",
                    _ => CodeRaw.GetRawText()
                };
        }

        private sealed record JsonRpcEnvelope(
            [property: JsonPropertyName("jsonrpc")] string JsonRpc,
            [property: JsonPropertyName("id")] string Id,
            [property: JsonPropertyName("result")] JsonElement? Result,
            [property: JsonPropertyName("error")] JsonRpcError? Error);

        public sealed record AgentTaskResult(
            [property: JsonPropertyName("id")] string Id,
            [property: JsonPropertyName("contextId")] string ContextId);

        public sealed record CreateContextResult([property: JsonPropertyName("id")] string ContextId);

        public sealed record ListTasksResult([property: JsonPropertyName("tasks")] JsonElement Tasks);

        public sealed record ListContextsResult([property: JsonPropertyName("contexts")] JsonElement Contexts);

        public sealed record UpdateContextResult(
            [property: JsonPropertyName("id")] string Id,
            [property: JsonPropertyName("name")] string? Name,
            [property: JsonPropertyName("isArchived")] bool IsArchived,
            [property: JsonPropertyName("status")] string? Status,
            [property: JsonPropertyName("createdAt")] string? CreatedAt,
            [property: JsonPropertyName("updatedAt")] string? UpdatedAt);

        #endregion

        #region High-level API

        public Task<CreateContextResult> CreateContextAsync(string flowName, object? args = null, CancellationToken ct = default) =>
            CallExpectObjectAsync<CreateContextResult>(flowName, "contexts/create", args, ct);

        public Task<ListTasksResult> ListTasksAsync(string flowName, object? args = null, CancellationToken ct = default) =>
            CallExpectObjectAsync<ListTasksResult>(flowName, "tasks/list", args, ct);

        public Task<AgentTaskResult> GetTaskAsync(string flowName, string taskId, CancellationToken ct = default) =>
            CallExpectObjectAsync<AgentTaskResult>(flowName, "tasks/get", new { id = taskId }, ct);

        public Task<AgentTaskResult> SendMessageAsync(string flowName, object messageArgs, CancellationToken ct = default) =>
            CallExpectObjectAsync<AgentTaskResult>(flowName, "message/send", messageArgs, ct);

        /// <summary>
        /// Updates a context (name / archive flag). Server expects an AgentContext-like payload (id, name, isArchived).
        /// </summary>
        public Task<UpdateContextResult> UpdateContextAsync(
            string flowName,
            string contextId,
            string name,
            bool? isArchived = null,
            CancellationToken ct = default)
        {
            if (string.IsNullOrWhiteSpace(contextId)) throw new ArgumentNullException(nameof(contextId));
            if (string.IsNullOrWhiteSpace(name)) throw new ArgumentNullException(nameof(name));

            var payload = new
            {
                id = contextId,
                name,
                isArchived = isArchived
            };

            return CallExpectObjectAsync<UpdateContextResult>(flowName, "context/update", payload, ct);
        }

        /// <summary>
        /// Create a context then immediately set its name (e.g. to Conversation.Id).
        /// </summary>
        public async Task<UpdateContextResult> CreateAndNameContextAsync(
            string flowName,
            string name,
            object? createArgs = null,
            bool? isArchived = null,
            CancellationToken ct = default)
        {
            var created = await CreateContextAsync(flowName, createArgs, ct).ConfigureAwait(false);
            return await UpdateContextAsync(flowName, created.ContextId, name, isArchived, ct).ConfigureAwait(false);
        }

        /// <summary>
        /// Lists contexts. Server currently returns a bare JSON array (not an object). This method tolerates either shape.
        /// </summary>
        public async Task<ListContextsResult> ListContextsAsync(
            string flowName,
            object? args = null,
            CancellationToken ct = default)
        {
            // Provide a sensible default if caller did not specify paging.
            args ??= new { limit = 50, includeLastTask = false };

            var elem = await CallRawAsync(flowName, "contexts/list", args, ct).ConfigureAwait(false);
            if (!elem.HasValue)
                return new ListContextsResult(default);

            var v = elem.Value;

            if (v.ValueKind == JsonValueKind.Array)
                return new ListContextsResult(v);

            if (v.ValueKind == JsonValueKind.Object &&
                v.TryGetProperty("contexts", out var ctxProp) &&
                ctxProp.ValueKind == JsonValueKind.Array)
                return new ListContextsResult(ctxProp);

            throw new InvalidOperationException($"Unexpected JSON shape from contexts/list: {v.ValueKind}. Raw: {Truncate(v.GetRawText(), 400)}");
        }

        #endregion

        #region Core JSON-RPC

        private async Task<JsonElement?> CallRawAsync(string flowName, string method, object? args, CancellationToken ct)
        {
            if (string.IsNullOrWhiteSpace(flowName)) throw new ArgumentNullException(nameof(flowName));
            var url = new Uri(_baseAgentsUri, flowName.TrimEnd('/') + "/");
            var id = Guid.NewGuid().ToString("N");

            var req = new JsonRpcRequest
            {
                Id = id,
                Method = method,
                Params = _rejectsParams ? null : args
            };

            var json = JsonSerializer.Serialize(req, _jsonOptions);
            using var content = new StringContent(json, Encoding.UTF8, "application/json");
            using var resp = await _http.PostAsync(url, content, ct).ConfigureAwait(false);
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

            if (!resp.IsSuccessStatusCode)
            {
                Adapt(body);
                throw new HttpRequestException($"HTTP {(int)resp.StatusCode} {resp.ReasonPhrase} calling '{method}'. Body: {Truncate(body, 800)}",
                    null, resp.StatusCode);
            }

            JsonRpcEnvelope? envelope;
            try
            {
                envelope = JsonSerializer.Deserialize<JsonRpcEnvelope>(body, _jsonOptions);
            }
            catch (Exception ex)
            {
                Adapt(body);
                throw new InvalidOperationException($"Failed to parse RPC response for '{method}': {ex.Message}. Raw: {Truncate(body, 800)}", ex);
            }

            if (envelope == null)
                throw new InvalidOperationException($"Null RPC envelope for '{method}'. Raw: {Truncate(body, 800)}");

            if (envelope.Error != null)
            {
                Adapt(envelope.Error.Message);
                throw new InvalidOperationException($"JSON-RPC error {envelope.Error.Code}: {envelope.Error.Message}");
            }

            return envelope.Result;
        }

        private async Task<T> CallExpectObjectAsync<T>(string flowName, string method, object? args, CancellationToken ct)
        {
            var elem = await CallRawAsync(flowName, method, args, ct).ConfigureAwait(false);
            if (elem == null)
                throw new InvalidOperationException($"No result for '{method}'.");

            if (elem.Value.ValueKind is not (JsonValueKind.Object or JsonValueKind.Array))
                throw new InvalidOperationException($"Unexpected JSON shape for '{method}' result: {elem.Value.ValueKind}");

            try
            {
                var obj = JsonSerializer.Deserialize<T>(elem.Value.GetRawText(), _jsonOptions);
                if (obj == null)
                    throw new InvalidOperationException($"Result null after deserialization for '{method}'.");
                return obj;
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException(
                    $"Deserialization failure for '{method}' into {typeof(T).Name}: {ex.Message}. JSON: {Truncate(elem.Value.GetRawText(), 600)}",
                    ex);
            }
        }

        #endregion

        #region Adaptation & Helpers

        private void Adapt(string s)
        {
            if (s.Contains("Could not find member 'params'", StringComparison.OrdinalIgnoreCase) ||
                s.Contains("Unrecognized field \"params\"", StringComparison.OrdinalIgnoreCase))
            {
                _rejectsParams = true;
            }
        }

        private static string Truncate(string s, int max) =>
            s.Length <= max ? s : s[..max] + "...";

        #endregion
    }
}
