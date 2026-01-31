using System;
using System.Linq;

namespace AutoSignIn;

public class WorkflowOptions
{
    // Full URL to the specific Agent workflow endpoint.
    public string AgentUrl { get; set; } = string.Empty;

    // Derived workflow name (last path segment)
    public string WorkflowName
        => string.IsNullOrEmpty(AgentUrl) ? string.Empty : new Uri(AgentUrl).Segments.Last().TrimEnd('/');

    // Base service URL without the workflow segment (no trailing slash)
    public string ServiceBaseUrl
    {
        get
        {
            if (string.IsNullOrEmpty(AgentUrl)) return string.Empty;
            var trimmed = AgentUrl.TrimEnd('/');
            var lastSlash = trimmed.LastIndexOf('/');
            return lastSlash > 0 ? trimmed.Substring(0, lastSlash) : trimmed;
        }
    }
}
