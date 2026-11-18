"""Small helper for talking to Toolbelt's MCP endpoint from Python (pip install mcp).

    async with Toolbelt("watcher") as tb:
        rows = await tb.call("toolbelt_sql", query="SELECT 1")

Settings come from the environment (see README.md):
    TOOLBELT_MCP_URL   http://<HOST_IP>:3100/ns/<namespace id>/mcp
    TOOLBELT_TOKEN     tb_... token for that namespace
    TOOLBELT_NAMESPACE the namespace id (tools need it as namespace_id)

Works with the mcp package 1.x and 2.x (2.x renamed the HTTP client and its fields).
"""
import json
import os
from contextlib import AsyncExitStack
from datetime import datetime, timezone

from mcp import ClientSession

try:  # mcp 1.x
    from mcp.client.streamable_http import streamablehttp_client as _client_v1
except ImportError:  # mcp 2.x
    _client_v1 = None
    from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client


class Toolbelt:
    def __init__(self, agent: str):
        self.agent = agent
        self.url = os.environ["TOOLBELT_MCP_URL"]
        self.token = os.environ["TOOLBELT_TOKEN"]
        self.namespace = os.environ["TOOLBELT_NAMESPACE"]

    async def __aenter__(self):
        headers = {"Authorization": f"Bearer {self.token}", "X-Toolbelt-Agent": self.agent}
        self._stack = AsyncExitStack()
        try:
            if _client_v1:
                read, write, _ = await self._stack.enter_async_context(
                    _client_v1(self.url, headers=headers, timeout=120, sse_read_timeout=300))
            else:
                http = await self._stack.enter_async_context(create_mcp_http_client(headers=headers))
                read, write = await self._stack.enter_async_context(
                    streamable_http_client(self.url, http_client=http))
            self._session = await self._stack.enter_async_context(ClientSession(read, write))
            await self._session.initialize()
        except BaseException:
            await self._stack.aclose()
            raise
        return self

    async def __aexit__(self, *exc):
        await self._stack.aclose()

    async def call(self, tool: str, **args):
        """Call a Toolbelt tool; returns its JSON result. Raises on a tool error."""
        args.setdefault("namespace_id", self.namespace)
        res = await self._session.call_tool(tool, args)
        structured = getattr(res, "structuredContent", None) or getattr(res, "structured_content", None)
        if structured:
            out = structured
            out = out.get("result", out) if isinstance(out, dict) and set(out) == {"result"} else out
        else:
            text = "".join(getattr(c, "text", "") for c in res.content)
            try:
                out = json.loads(text)
            except ValueError:
                out = text
        if getattr(res, "isError", None) or getattr(res, "is_error", None):
            raise RuntimeError(f"{tool} failed: {out}")
        return out


def rows_of(result):
    """Rows (list of dicts) from a toolbelt_sql result, whatever wrapper it comes in."""
    if isinstance(result, list):
        return result
    if isinstance(result, dict):
        for k in ("rows", "data", "results", "records"):
            v = result.get(k)
            if isinstance(v, list):
                if v and isinstance(v[0], list) and isinstance(result.get("columns"), list):
                    cols = [c["name"] if isinstance(c, dict) else c for c in result["columns"]]
                    return [dict(zip(cols, row)) for row in v]
                return v
    return []


def when(ts):
    """A timestamp column as toolbelt_sql returns it (epoch milliseconds) -> readable UTC."""
    if isinstance(ts, (int, float)) or (isinstance(ts, str) and ts.isdigit()):
        return datetime.fromtimestamp(int(ts) / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    return str(ts)
