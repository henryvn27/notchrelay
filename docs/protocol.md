# Bridge protocol

Protocol version 2 uses one newline-delimited JSON object per private Unix-domain socket connection, limited to 1 MiB.

```json
{
  "version": 2,
  "requestId": "UUID",
  "event": "sessionStart | working | approvalRequested | subagentStarted | subagentStopped | completed | failed | ping",
  "timestamp": "ISO-8601",
  "sessionId": "string",
  "turnId": "string-or-null",
  "cwd": "string",
  "agentId": "string-or-null",
  "agentType": "string-or-null",
  "toolName": "string-or-null",
  "toolInput": {},
  "authToken": "random-token"
}
```

Approval responses contain version 2, the same UUID, and `allow`, `deny`, or `defer`. The app rejects unsupported versions, invalid tokens, different peer users, malformed JSON, over-limit messages, and stale timestamps. The helper rejects malformed, version-mismatched, and request-mismatched responses.

`defer`, no response, timeout, and bridge errors produce no Codex permission decision. Stop prints neutral `{}` and never requests another turn.

Local lifecycle observation is not part of the bridge protocol. It produces only in-process display events and can never produce `approvalRequested` or an approval response.

For official `SubagentStart` and `SubagentStop` inputs, the helper keeps the parent `session_id` and carries the opaque `agent_id` as ephemeral child activity. A child stop never completes its parent or triggers a completion signal. Raw parent and child identifiers are never displayed; the UI shows only a sanitized agent count. Protocol v2 is intentionally rejected by v1 peers so an outdated helper cannot silently collapse child activity into the parent lifecycle.
