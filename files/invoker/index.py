"""
Bedrock agent invoker — minimal Lambda handler bundled by the
terraform-aws-bedrock-agentcore module.

API Gateway HTTP API (payload v2) -> this Lambda -> bedrock-agent-runtime
:InvokeAgent against the agent alias provisioned by the module.

Environment variables (set by aws_lambda_function.invoker):
    AGENT_ID        — bedrock agent identifier
    AGENT_ALIAS_ID  — bedrock agent alias identifier

Request body (JSON):
    { "prompt": "<text>", "sessionId": "<optional>" }
"""

from __future__ import annotations

import json
import logging
import os
import uuid

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_AGENT_ID = os.environ["AGENT_ID"]
_AGENT_ALIAS_ID = os.environ["AGENT_ALIAS_ID"]

_client = boto3.client("bedrock-agent-runtime")


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event: dict, _context) -> dict:
    """API Gateway v2 proxy handler — extracts prompt, calls InvokeAgent,
    aggregates the streamed completion chunks into a single text response."""
    try:
        raw_body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64

            raw_body = base64.b64decode(raw_body).decode("utf-8")
        payload = json.loads(raw_body)
    except (ValueError, TypeError) as exc:
        logger.warning(json.dumps({"event": "bad_request", "error": str(exc)}))
        return _response(400, {"error": "invalid JSON body"})

    prompt = payload.get("prompt")
    if not prompt:
        return _response(400, {"error": "missing 'prompt' in request body"})

    session_id = payload.get("sessionId") or str(uuid.uuid4())

    try:
        result = _client.invoke_agent(
            agentId=_AGENT_ID,
            agentAliasId=_AGENT_ALIAS_ID,
            sessionId=session_id,
            inputText=prompt,
        )
    except Exception as exc:  # pragma: no cover — surfaced as 502 to caller
        logger.exception(json.dumps({"event": "invoke_agent_failed"}))
        return _response(502, {"error": "invoke_agent failed", "detail": str(exc)})

    completion_chunks: list[str] = []
    for chunk_event in result.get("completion", []):
        chunk = chunk_event.get("chunk") or {}
        data = chunk.get("bytes")
        if data:
            completion_chunks.append(data.decode("utf-8"))

    answer = "".join(completion_chunks)
    logger.info(json.dumps({"event": "invoke_agent_ok", "sessionId": session_id, "len": len(answer)}))
    return _response(200, {"sessionId": session_id, "completion": answer})
