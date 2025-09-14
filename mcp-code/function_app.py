import json
import azure.functions as func

app = func.FunctionApp()

# 逆順ツールの引数スキーマ（MCPクライアントが入力UIを出すために必要）
tool_properties_reverse_json = json.dumps([
    {
        "propertyName": "text",
        "propertyType": "string",
        "description": "Reverse this text."
    }
])

@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="reverse_text",
    description="Return the reversed string of the provided text.",
    toolProperties=tool_properties_reverse_json
)

# 関数の作成

def reverse_text(context) -> str:
    """
    MCP の arguments から text を受け取り、反転して返す。
    """
    try:
        payload = json.loads(context)          # {"arguments": {...}, ...}
        args = payload.get("arguments", {})
        text = args.get("text")
    except Exception:
        text = None

    if not text:
        return "No text provided."

    if not isinstance(text, str):
        text = str(text)

    return text[::-1]