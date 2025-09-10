import os
import json
import logging
from types import SimpleNamespace

try:
    import anthropic
except Exception as e:  # pragma: no cover
    print(f"WARNING: Failed to import anthropic library: {e}")
    anthropic = None

# Set up logging for debugging tool call issues
logger = logging.getLogger("agent.providers.anthropic_shim")

# Track consecutive empty bash calls to prevent infinite loops
_consecutive_empty_bash_calls = 0
_max_empty_bash_calls = 3


def _is_dictlike(obj):
    return isinstance(obj, dict)


def _to_text_block(text: str):
    return {"type": "text", "text": text or ""}


class AnthropicShim:
    """
    Thin compatibility layer exposing an OpenAI-like
    client.chat.completions.create(...) over Anthropic Messages API.
    """

    class _Chat:
        def __init__(self, parent):
            self._parent = parent

        class _Completions:
            def __init__(self, parent):
                self._parent = parent

            def create(self, model: str, messages, tools=None, tool_choice=None, **kwargs):
                if anthropic is None:
                    raise RuntimeError("anthropic package is not installed in the agent container")

                # Extract system message (first system)
                system = None
                converted_messages = []
                pending_user_blocks = []

                def flush_user_blocks():
                    nonlocal pending_user_blocks
                    if pending_user_blocks:
                        converted_messages.append({
                            "role": "user",
                            "content": list(pending_user_blocks),
                        })
                        pending_user_blocks = []

                # Convert OpenAI-style messages to Anthropic blocks
                def _get(o, key, default=None):
                    if isinstance(o, dict):
                        return o.get(key, default)
                    return getattr(o, key, default)

                for m in messages or []:
                    role = _get(m, "role")
                    content = _get(m, "content", "")

                    if role == "system":
                        # Concatenate multiple system messages if present
                        system = (system + "\n\n" + content) if system else str(content)
                        continue

                    if role == "user":
                        flush_user_blocks()
                        pending_user_blocks.append(_to_text_block(str(content)))
                        continue

                    if role == "assistant":
                        flush_user_blocks()
                        a_blocks = []
                        if content:
                            a_blocks.append(_to_text_block(str(content)))
                        for tc in (_get(m, "tool_calls") or []):
                            # tc may be dict or object
                            tcf = _get(tc, "function") or {}
                            if not isinstance(tcf, dict):
                                tcf = {
                                    "name": _get(_get(tc, "function"), "name", ""),
                                    "arguments": _get(_get(tc, "function"), "arguments", "{}"),
                                }
                            name = (tcf.get("name") or "")
                            args_raw = (tcf.get("arguments") or "{}")
                            try:
                                args = json.loads(args_raw)
                            except Exception as e:
                                logger.warning(f"Failed to parse tool arguments for {name}: {args_raw}. Error: {e}")
                                args = {}
                            a_blocks.append({
                                "type": "tool_use",
                                "id": _get(tc, "id") or "tool_use_1",
                                "name": name,
                                "input": args,
                            })
                        converted_messages.append({
                            "role": "assistant",
                            "content": a_blocks or [_to_text_block("")],
                        })
                        continue

                    if role == "tool":
                        # Convert tool result to a user message block
                        tool_call = _get(m, "tool_call")
                        tool_use_id = _get(m, "tool_call_id") or (_get(tool_call, "id") if tool_call else None)
                        tool_content = _get(m, "content")
                        if not isinstance(tool_content, str):
                            try:
                                tool_content = json.dumps(tool_content)
                            except Exception:
                                tool_content = str(tool_content)
                        pending_user_blocks.append({
                            "type": "tool_result",
                            "tool_use_id": tool_use_id or "tool_use_1",
                            "content": [_to_text_block(tool_content or "")],
                        })
                        continue

                    # Fallback: treat anything else as user text
                    flush_user_blocks()
                    converted_messages.append({
                        "role": "user",
                        "content": [_to_text_block(str(content))],
                    })

                flush_user_blocks()

                # Convert tools
                a_tools = []
                for t in (tools or []):
                    t_type = _get(t, "type")
                    t_fn = _get(t, "function")
                    if (t_type == "function") and t_fn:
                        fn = t_fn if isinstance(t_fn, dict) else {
                            "name": _get(t_fn, "name", ""),
                            "description": _get(t_fn, "description", ""),
                            "parameters": _get(t_fn, "parameters", {"type": "object"}),
                        }
                        a_tools.append({
                            "name": fn.get("name", ""),
                            "description": fn.get("description", ""),
                            "input_schema": fn.get("parameters", {"type": "object"}),
                        })

                # Map tool_choice if specified
                a_tool_choice = None
                if isinstance(tool_choice, dict):
                    # Expecting {"type":"function","function":{"name":"..."}}
                    if tool_choice.get("type") == "function":
                        fn = (tool_choice.get("function") or {})
                        name = fn.get("name")
                        if name:
                            a_tool_choice = {"type": "tool", "name": name}
                elif isinstance(tool_choice, str):
                    # Anthropic defaults to auto if omitted; map 'none' explicitly
                    if tool_choice.lower() == "none":
                        a_tool_choice = {"type": "none"}
                    else:
                        # For 'auto' or other strings, omit to let API decide
                        a_tool_choice = None

                # Create Anthropic client and call
                client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

                kwargs = {
                    "model": model,
                    "messages": converted_messages,
                    "max_tokens": 1024,
                }
                if a_tools:
                    kwargs["tools"] = a_tools
                if system:
                    kwargs["system"] = system
                if a_tool_choice is not None:
                    kwargs["tool_choice"] = a_tool_choice

                # Allow configurable token budget
                try:
                    max_toks_env = int(os.environ.get("ANTHROPIC_MAX_TOKENS", "0"))
                    if max_toks_env > 0:
                        kwargs["max_tokens"] = max_toks_env
                except Exception:
                    pass

                resp = client.messages.create(**kwargs)

                # Convert back to OpenAI-like response
                text_parts = []
                tool_calls = []
                for block in getattr(resp, "content", []) or []:
                    btype = getattr(block, "type", None) if not _is_dictlike(block) else block.get("type")
                    if btype == "text":
                        txt = getattr(block, "text", "") if not _is_dictlike(block) else block.get("text", "")
                        text_parts.append(txt)
                    elif btype == "tool_use":
                        bid = getattr(block, "id", None) if not _is_dictlike(block) else block.get("id")
                        name = getattr(block, "name", "") if not _is_dictlike(block) else block.get("name", "")
                        binput = getattr(block, "input", {}) if not _is_dictlike(block) else block.get("input", {})
                        
                        # Enhanced error handling for tool calls
                        if not binput or binput == {}:
                            logger.warning(f"Claude returned empty tool arguments for {name}. This may cause tool execution to fail.")
                            
                            # For bash tool specifically, provide helpful error context and fix empty calls
                            if name == "bash":
                                global _consecutive_empty_bash_calls
                                _consecutive_empty_bash_calls += 1
                                
                                logger.warning(f"Bash tool requires 'command' parameter. Empty call #{_consecutive_empty_bash_calls}")
                                
                                if _consecutive_empty_bash_calls <= _max_empty_bash_calls:
                                    # Provide escalating help messages
                                    if _consecutive_empty_bash_calls == 1:
                                        error_msg = "ERROR: bash tool called with empty arguments. Please provide a command parameter. Example: {'command': 'ls -la'}"
                                    elif _consecutive_empty_bash_calls == 2:
                                        error_msg = "ERROR: bash tool still called with empty arguments. You MUST provide a 'command' parameter. Format: {'command': 'your_command_here'}. For example: {'command': 'cat /app/integration.py'}"
                                    else:
                                        error_msg = "ERROR: Repeated empty bash calls detected. This suggests a tool formatting issue. Please check your tool call syntax and ensure you're providing {'command': 'actual_command'}."
                                    
                                    binput = {"command": f"echo '{error_msg}'"}
                                    logger.info(f"Converted empty bash call #{_consecutive_empty_bash_calls} to error message")
                                else:
                                    # After max attempts, suggest termination
                                    binput = {"command": "echo 'ERROR: Too many empty bash calls. Consider using terminate tool to end this session.'"}
                                    logger.error(f"Max empty bash calls ({_max_empty_bash_calls}) exceeded. Suggesting termination.")
                        else:
                            # Reset counter on successful tool call
                            if name == "bash":
                                global _consecutive_empty_bash_calls
                                _consecutive_empty_bash_calls = 0
                        
                        # Log tool call details for debugging
                        logger.debug(f"Tool call: {name} with input: {binput}")
                        
                        tool_calls.append(SimpleNamespace(
                            id=bid or "tool_use_1",
                            type="function",
                            function=SimpleNamespace(name=name, arguments=json.dumps(binput)),
                        ))

                message = SimpleNamespace(
                    role="assistant",
                    content="".join(text_parts).strip(),
                    tool_calls=tool_calls or None,
                )
                choice = SimpleNamespace(message=message)
                return SimpleNamespace(choices=[choice])

        def __getattr__(self, name):  # compat for client.chat.completions
            if name == "completions":
                return AnthropicShim._Chat._Completions(self._parent)
            raise AttributeError(name)

    def __init__(self):
        self.chat = AnthropicShim._Chat(self)
