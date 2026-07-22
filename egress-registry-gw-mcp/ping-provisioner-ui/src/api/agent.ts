const REASONING_ENGINE_ID = import.meta.env.VITE_REASONING_ENGINE_ID as string;
const GCP_PROJECT = import.meta.env.VITE_GCP_PROJECT as string;
const GCP_REGION = (import.meta.env.VITE_GCP_REGION as string) || 'us-central1';
const WIF_PROVIDER = import.meta.env.VITE_WIF_PROVIDER as string;
// Service account to impersonate via WIF — optional, falls back to direct federation
const WIF_SERVICE_ACCOUNT = import.meta.env.VITE_WIF_SERVICE_ACCOUNT as string | undefined;

const VERTEX_BASE = `https://${GCP_REGION}-aiplatform.googleapis.com/v1beta1`;
const ENGINE_PATH = `projects/${GCP_PROJECT}/locations/${GCP_REGION}/reasoningEngines/${REASONING_ENGINE_ID}`;

// Exchange AIC bearer token for a Google access token via Workload Identity Federation.
async function getGoogleToken(aicToken: string): Promise<string> {
  const stsBody = new URLSearchParams({
    grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    audience: WIF_PROVIDER,
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    subject_token: aicToken,
    subject_token_type: 'urn:ietf:params:oauth:token-type:id_token',
    scope: 'https://www.googleapis.com/auth/cloud-platform',
  });

  const stsRes = await fetch('https://sts.googleapis.com/v1/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: stsBody,
  });
  if (!stsRes.ok) {
    const err = await stsRes.text();
    throw new Error(`WIF STS exchange failed ${stsRes.status}: ${err}`);
  }
  const { access_token: fedToken } = await stsRes.json();

  // If a service account is configured, impersonate it to get a scoped token.
  if (WIF_SERVICE_ACCOUNT) {
    const impRes = await fetch(
      `https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${WIF_SERVICE_ACCOUNT}:generateAccessToken`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${fedToken}`,
        },
        body: JSON.stringify({ scope: ['https://www.googleapis.com/auth/cloud-platform'] }),
      },
    );
    if (!impRes.ok) {
      const err = await impRes.text();
      throw new Error(`Service account impersonation failed ${impRes.status}: ${err}`);
    }
    const { accessToken } = await impRes.json();
    return accessToken;
  }

  return fedToken;
}

// v2: token passed as message prefix; session state API not used
export async function invokeProvisionerAgent(message: string, aicToken: string): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 120_000);

  try {
    const googleToken = await getGoogleToken(aicToken);

    // The Agent Runtime sessions API does not support object state — create
    // a plain session and pass the AIC token as a message prefix instead.
    const sessionRes = await fetch(`${VERTEX_BASE}/${ENGINE_PATH}/sessions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${googleToken}`,
      },
      body: JSON.stringify({ user_id: 'ping-user' }),
      signal: controller.signal,
    });
    if (!sessionRes.ok) {
      const err = await sessionRes.text();
      throw new Error(`Session creation failed ${sessionRes.status}: ${err}`);
    }
    const session = await sessionRes.json();
    // Response is a long-running operation; session is nested under response.name
    const sessionName: string = session.response?.name ?? session.name ?? '';
    const sessionId: string = sessionName.split('/').pop()!;
    const userId: string = session.response?.userId ?? session.userId ?? 'ping-user';

    // Stream the query and collect the final text response.
    const queryRes = await fetch(
      `${VERTEX_BASE}/${ENGINE_PATH}:streamQuery?alt=sse`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${googleToken}`,
        },
        body: JSON.stringify({
          class_method: 'stream_query',
          input: {
            user_id: userId,
            session_id: sessionId,
            // Prefix the AIC token so the agent's before_model_callback can
            // extract it and store it in session state for header_provider.
            message: `__AIC__:${aicToken} ${message}`,
          },
        }),
        signal: controller.signal,
      },
    );
    if (!queryRes.ok) {
      const err = await queryRes.text();
      throw new Error(`Agent query failed ${queryRes.status}: ${err}`);
    }

    // Parse SSE stream, collect last non-thought text part.
    const reader = queryRes.body!.getReader();
    const decoder = new TextDecoder();
    let finalText = '';
    let buf = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        try {
          const event = JSON.parse(line.slice(6));
          const parts = event?.content?.parts ?? [];
          for (const part of parts) {
            if (part.text && !part.thought_signature) finalText = part.text;
          }
        } catch { /* non-JSON SSE line */ }
      }
    }

    return finalText || '(no response)';
  } catch (err) {
    const msg =
      err instanceof Error && err.name === 'AbortError'
        ? 'Request timed out after 2 minutes'
        : err instanceof Error
          ? err.message
          : 'Network error';
    throw new Error(msg);
  } finally {
    clearTimeout(timeout);
  }
}
