.pragma library

// Map HTTP status codes from OpenAI-compatible endpoints to short,
// human-readable hints appended to error bubbles.

function httpErrorHint(status) {
    switch (status) {
    case 400: return "Bad request — the provider rejected the request. Check the model name.";
    case 401: return "Unauthorized — the API key is missing or invalid.";
    case 403: return "Forbidden — this key lacks permission for the model.";
    case 404: return "Not found — check the base URL and model name.";
    case 413: return "Payload too large — the conversation exceeds the provider's limit.";
    case 422: return "Unprocessable request — check the model name and parameters.";
    case 429: return "Rate limited or quota exceeded — wait a moment and retry.";
    case 500:
    case 502:
    case 503:
    case 504: return "The provider is having trouble (server error). Try again shortly.";
    default: return "";
    }
}

// Map curl exit codes (non-zero) to connection-level hints.

function curlExitHint(exitCode) {
    switch (exitCode) {
    case 6: return "Could not resolve the server address — check the base URL and network.";
    case 7: return "Could not connect to the server — is it running and reachable?";
    case 28: return "The request timed out.";
    case 35:
    case 53: return "TLS handshake failed — check the base URL scheme.";
    case 60: return "TLS certificate verification failed.";
    default: return "";
    }
}
