# function_app.py
import json
import re
import html
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List, Optional, Tuple
import azure.functions as func

# 3rd party
import httpx
import feedparser
from dateutil import parser as dateparser

app = func.FunctionApp()

# =========
# Presets
# =========
PRESETS = {
    # --- Azure系 ---
    "azure_blog": {"url": "https://azure.microsoft.com/en-us/blog/feed/"},
    # Azure Updatesの代替（Release CommunicationsのAzure向けRSS）
    "azure_updates_rc": {"url": "https://www.microsoft.com/releasecommunications/api/v2/azure/rss"},

    # --- Zenn系（公式） ---
    "zenn_trend": {"url": "https://zenn.dev/feed"},
    # zenn_user / zenn_topic は arguments から username / topic を受け取って生成
}

# ===============
# Tool schemas
# ===============
tool_properties_fetch_json = json.dumps([
    {"propertyName": "url", "propertyType": "string",
     "description": "Single RSS/Atom feed URL."},

    # 複数URLは「配列」ではなく「文字列」を区切りで受ける
    {"propertyName": "urlList", "propertyType": "string",
     "description": "Multiple feed URLs separated by comma/space/newline."},

    {"propertyName": "preset", "propertyType": "string",
     "description": "One of: azure_blog, azure_updates_rc, zenn_trend, zenn_user, zenn_topic"},
    {"propertyName": "zennUser", "propertyType": "string",
     "description": "Required when preset=zenn_user (e.g. 'yamadakz')."},
    {"propertyName": "zennTopic", "propertyType": "string",
     "description": "Required when preset=zenn_topic (e.g. 'azure')."},
    {"propertyName": "maxItems", "propertyType": "integer",
     "description": "Max items to return (default 10)."},
    {"propertyName": "sinceHours", "propertyType": "integer",
     "description": "Only include entries published within N hours."},
    {"propertyName": "keyword", "propertyType": "string",
     "description": "Filter by keyword in title or summary (case-insensitive)."},
    {"propertyName": "includeSummary", "propertyType": "boolean",
     "description": "Include summary/description text (default true)."},
    {"propertyName": "timeoutSec", "propertyType": "integer",
     "description": "HTTP timeout seconds per feed (default 10)."}
])

tool_properties_presets_json = json.dumps([])  # no args

# ==========
# Utilities
# ==========
def _now_utc() -> datetime:
    return datetime.now(timezone.utc)

def _coerce_list_from_urllist(s: Optional[str]) -> List[str]:
    """urlList（カンマ/空白/改行区切り）を配列化"""
    if not s or not isinstance(s, str):
        return []
    items = re.split(r"[,\s]+", s.strip())
    return [u for u in items if u]

def _guess_datetime(entry: Dict[str, Any]) -> Tuple[Optional[datetime], Optional[datetime]]:
    """Returns (published_dt, updated_dt) in UTC if available."""
    def _parse(val: Any) -> Optional[datetime]:
        if not val:
            return None
        try:
            dt = dateparser.parse(str(val))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except Exception:
            return None

    pub = _parse(entry.get("published") or entry.get("pubDate") or entry.get("updated"))
    upd = _parse(entry.get("updated") or entry.get("modified"))
    return pub, upd

_TAG_RE = re.compile(r"<[^>]+>")

def _clean_summary(s: Optional[str]) -> str:
    if not s:
        return ""
    s = html.unescape(_TAG_RE.sub("", s))
    return re.sub(r"\s+", " ", s).strip()

def _match_keyword(entry: Dict[str, Any], kw: str) -> bool:
    txt = " ".join([
        str(entry.get("title") or ""),
        _clean_summary(entry.get("summary") or entry.get("description") or "")
    ])
    return kw.lower() in txt.lower()

async def _fetch_one(client: httpx.AsyncClient, url: str):
    try:
        r = await client.get(
            url,
            headers={"User-Agent": "RssMcpServer/0.1 (+https://example)"},
            follow_redirects=True
        )
        r.raise_for_status()
        parsed = feedparser.parse(r.content)
        return url, parsed, None
    except Exception as e:
        return url, None, f"{type(e).__name__}: {e}"

def _preset_to_urls(preset: str, args: Dict[str, Any]) -> List[str]:
    if preset == "zenn_user":
        u = args.get("zennUser")
        if not u:
            raise ValueError("preset=zenn_user requires 'zennUser'")
        return [f"https://zenn.dev/{u}/feed"]
    if preset == "zenn_topic":
        t = args.get("zennTopic")
        if not t:
            raise ValueError("preset=zenn_topic requires 'zennTopic'")
        return [f"https://zenn.dev/topics/{t}/feed"]
    meta = PRESETS.get(preset)
    if meta and "url" in meta:
        return [meta["url"]]
    raise ValueError(f"Unknown preset: {preset}")

def _normalize_item(feed_url: str, feed_title: str, e: Dict[str, Any], include_summary: bool) -> Dict[str, Any]:
    pub, upd = _guess_datetime(e)
    link = e.get("link") or e.get("id") or ""
    item = {
        "title": (e.get("title") or "").strip(),
        "link": link,
        "published": pub.isoformat() if pub else None,
        "updated": upd.isoformat() if upd else None,
        "source": {"feedTitle": feed_title, "feedUrl": feed_url}
    }
    if include_summary:
        item["summary"] = _clean_summary(e.get("summary") or e.get("description") or "")
    return item

def _dedup_by_link(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    seen = set()
    out = []
    for it in items:
        k = it.get("link") or (it.get("title"), it["source"]["feedUrl"])
        if k in seen:
            continue
        seen.add(k)
        out.append(it)
    return out

# =================
# Tools (MCP)
# =================
@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="list_presets",
    description="List built-in RSS presets and usage notes.",
    toolProperties=tool_properties_presets_json
)
def list_presets(context) -> str:
    doc = {
        "presets": {
            "azure_blog": "Azure Blog RSS (official).",
            "azure_updates_rc": "Azure updates via Microsoft Release Communications RSS (alt).",
            "zenn_trend": "Zenn global trending feed.",
            "zenn_user": "Zenn user feed. Requires 'zennUser' argument.",
            "zenn_topic": "Zenn topic feed. Requires 'zennTopic' argument."
        },
        "examples": [
            {"tool": "fetch_rss", "arguments": {"preset": "azure_blog", "maxItems": 5}},
            {"tool": "fetch_rss", "arguments": {"preset": "zenn_user", "zennUser": "yamadakz", "maxItems": 10}},
            {"tool": "fetch_rss", "arguments": {"preset": "zenn_topic", "zennTopic": "azure", "sinceHours": 72}}
        ]
    }
    return json.dumps(doc, ensure_ascii=False)

@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="fetch_rss",
    description="Fetch and filter RSS/Atom feeds (Azure & Zenn presets included).",
    toolProperties=tool_properties_fetch_json
)
def fetch_rss(context) -> str:
    """
    Arguments:
      - url: str (single feed URL)
      - urlList: str (multiple feed URLs separated by comma/space/newline)
      - preset: 'azure_blog' | 'azure_updates_rc' | 'zenn_trend' | 'zenn_user' | 'zenn_topic'
        - zennUser / zennTopic if preset requires them
      - maxItems: int (default 10)
      - sinceHours: int (optional)
      - keyword: str (optional, case-insensitive)
      - includeSummary: bool (default True)
      - timeoutSec: int (default 10)
    """
    # 1) Parse args
    try:
        payload = json.loads(context)
        args = payload.get("arguments", {}) if isinstance(payload, dict) else {}
    except Exception:
        args = {}

    urls: List[str] = []
    url = args.get("url")
    if url:
        urls.append(str(url))

    # 新：複数URLは urlList から分割
    urls.extend(_coerce_list_from_urllist(args.get("urlList")))

    preset = args.get("preset")
    if preset:
        try:
            urls.extend(_preset_to_urls(preset, args))
        except Exception as e:
            return json.dumps({"error": f"{e}"}, ensure_ascii=False)

    urls = [u for u in urls if u]
    if not urls:
        return json.dumps({"error": "Provide either url/urlList or a valid preset."}, ensure_ascii=False)

    max_items = int(args.get("maxItems") or 10)
    include_summary = bool(args.get("includeSummary") if "includeSummary" in args else True)
    kw = (args.get("keyword") or "").strip()
    since_hours = args.get("sinceHours")
    try:
        since_dt = _now_utc() - timedelta(hours=int(since_hours)) if since_hours else None
    except Exception:
        since_dt = None

    timeout_sec = int(args.get("timeoutSec") or 10)
    timeout = httpx.Timeout(timeout_sec)

    # 2) Fetch all feeds (async, AnyIO TaskGroup)
    import anyio
    from anyio import create_task_group

    results: List[Dict[str, Any]] = []
    errors: List[Dict[str, str]] = []

    async def _run():
        async with httpx.AsyncClient(timeout=timeout) as client:
            res: List[Tuple[str, Optional[Dict[str, Any]], Optional[str]]] = []

            async def worker(u: str):
                res.append(await _fetch_one(client, u))

            # TaskGroupで並行取得（構造化並行）
            async with create_task_group() as tg:
                for u in urls:
                    tg.start_soon(worker, u)

            # 集約処理
            for url_i, parsed, err in res:
                if err:
                    errors.append({"url": url_i, "error": err})
                    continue
                if not parsed or not parsed.get("entries"):
                    errors.append({"url": url_i, "error": "No entries or parse failure"})
                    continue
                feed_title = (parsed.get("feed") or {}).get("title", "") or url_i
                for e in parsed["entries"]:
                    item = _normalize_item(url_i, feed_title, e, include_summary)
                    # sinceHours フィルタ
                    if since_dt:
                        p = item.get("published") or item.get("updated")
                        if not p:
                            continue
                        try:
                            dt = dateparser.parse(p)
                            if dt.tzinfo is None:
                                dt = dt.replace(tzinfo=timezone.utc)
                            if dt.astimezone(timezone.utc) < since_dt:
                                continue
                        except Exception:
                            continue
                    # keyword フィルタ
                    if kw and not _match_keyword(e, kw):
                        continue
                    results.append(item)

    anyio.run(_run)

    # 3) Sort & dedup & trim
    def _key(it):
        p = it.get("published") or it.get("updated") or ""
        try:
            return dateparser.parse(p)
        except Exception:
            return datetime.min.replace(tzinfo=timezone.utc)

    results = _dedup_by_link(results)
    results.sort(key=_key, reverse=True)
    results = results[:max_items]

    # 4) Response
    response = {
        "count": len(results),
        "items": results,
        "errors": errors or None
    }
    return json.dumps(response, ensure_ascii=False)
