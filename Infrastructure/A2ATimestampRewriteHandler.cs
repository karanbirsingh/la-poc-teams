using System;
using System.Globalization;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;

namespace AutoSignIn.Infrastructure;

/// <summary>
/// Normalizes non-ISO timestamps in JSON responses into ISO 8601 
/// so System.Text.Json can deserialize DateTimeOffset.
/// </summary>
public sealed class A2ATimestampRewriteHandler : DelegatingHandler
{
    private readonly ILogger<A2ATimestampRewriteHandler>? _logger;

    public A2ATimestampRewriteHandler(ILogger<A2ATimestampRewriteHandler>? logger = null)
    {
        _logger = logger;
    }

    // Matches: "timestamp": "..." where value is NOT already ISO 8601
    // Captures any timestamp value for inspection
    private static readonly Regex TimestampRegex = new(
        "\"timestamp\"\\s*:\\s*\"(?<dt>[^\"]+)\"",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // Common date formats to try
    private static readonly string[] DateFormats = new[]
    {
        "M/d/yyyy h:mm:ss tt zzz",       // 1/31/2026 3:20:38 AM +00:00
        "M/d/yyyy H:mm:ss zzz",          // 1/31/2026 3:20:38 +00:00
        "M/d/yyyy h:mm:ss tt",           // 8/25/2025 8:07:32 AM
        "M/d/yyyy H:mm:ss",              // 8/25/2025 8:07:32
        "yyyy-MM-dd HH:mm:ss",           // 2025-08-25 08:07:32
        "yyyy-MM-ddTHH:mm:ss",           // 2025-08-25T08:07:32 (no timezone)
        "yyyy-MM-ddTHH:mm:ssZ",          // 2025-08-25T08:07:32Z
        "yyyy-MM-dd HH:mm:ss.fff",       // 2025-08-25 08:07:32.123
        "yyyy-MM-ddTHH:mm:ss.fff",       // 2025-08-25T08:07:32.123
        "yyyy-MM-ddTHH:mm:ss.fffZ",      // 2025-08-25T08:07:32.123Z
        "yyyy-MM-ddTHH:mm:ss.fffffffZ",  // 2025-08-25T08:07:32.1234567Z
        "dd/MM/yyyy HH:mm:ss",           // 25/08/2025 08:07:32
        "MM/dd/yyyy HH:mm:ss",           // 08/25/2025 08:07:32
    };

    // Regex to check if already valid ISO 8601 (starts with yyyy-MM-dd)
    private static readonly Regex Iso8601Regex = new(
        @"^\d{4}-\d{2}-\d{2}T",
        RegexOptions.Compiled);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        _logger?.LogDebug("[A2ATimestampRewriteHandler] Request: {Method} {Uri}", request.Method, request.RequestUri);
        
        HttpResponseMessage response = await base.SendAsync(request, cancellationToken);

        if (response.Content?.Headers.ContentType?.MediaType is not "application/json")
        {
            _logger?.LogDebug("[A2ATimestampRewriteHandler] Skipping non-JSON response: {ContentType}", 
                response.Content?.Headers.ContentType?.MediaType);
            return response;
        }

        string original = await response.Content.ReadAsStringAsync(cancellationToken);
        
        _logger?.LogDebug("[A2ATimestampRewriteHandler] Response body (first 500 chars): {Body}", 
            original.Length > 500 ? original.Substring(0, 500) + "..." : original);

        if (original.IndexOf("\"timestamp\"", StringComparison.Ordinal) < 0)
        {
            _logger?.LogDebug("[A2ATimestampRewriteHandler] No timestamp field found in response");
            return response;
        }

        string rewritten = TimestampRegex.Replace(original, m =>
        {
            var raw = m.Groups["dt"].Value;
            _logger?.LogInformation("[A2ATimestampRewriteHandler] Found timestamp: '{Timestamp}'", raw);

            // Only skip if it's actually ISO 8601 format (starts with yyyy-MM-ddT)
            if (Iso8601Regex.IsMatch(raw))
            {
                if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out _))
                {
                    _logger?.LogDebug("[A2ATimestampRewriteHandler] Timestamp already valid ISO 8601: '{Timestamp}'", raw);
                    return m.Value;
                }
            }

            // Try each format
            foreach (var fmt in DateFormats)
            {
                if (DateTimeOffset.TryParseExact(
                        raw,
                        fmt,
                        CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal,
                        out var dto))
                {
                    var iso = dto.ToUniversalTime().ToString("o");
                    _logger?.LogInformation("[A2ATimestampRewriteHandler] Converted '{Raw}' to '{Iso}' using format '{Format}'", raw, iso, fmt);
                    return $"\"timestamp\":\"{iso}\"";
                }
            }

            // Last resort: try generic parse
            if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dtoGeneric))
            {
                var iso = dtoGeneric.ToUniversalTime().ToString("o");
                _logger?.LogInformation("[A2ATimestampRewriteHandler] Converted '{Raw}' to '{Iso}' using generic parse", raw, iso);
                return $"\"timestamp\":\"{iso}\"";
            }

            // Fallback: leave unchanged (will likely cause error, but at least we tried)
            _logger?.LogWarning("[A2ATimestampRewriteHandler] Could not parse timestamp: '{Timestamp}'", raw);
            return m.Value;
        });

        if (!ReferenceEquals(original, rewritten))
        {
            _logger?.LogDebug("[A2ATimestampRewriteHandler] Response was rewritten");
            response.Content = new StringContent(rewritten, Encoding.UTF8, "application/json");
        }

        return response;
    }
}
