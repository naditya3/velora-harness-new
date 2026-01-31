"""LiteLLM-based Responses API support for gpt-5.2-codex

Uses liteLLM's built-in responses() method instead of custom HTTP client.
"""

from __future__ import annotations

from typing import Any

from litellm import responses as litellm_responses
from litellm.types.utils import ModelResponse

from openhands.core.logger import openhands_logger as logger


def should_use_litellm_responses(model: str, native_tool_calling: bool | None = None, reasoning_effort: str | None = None) -> bool:
    """Check if model requires liteLLM's responses() method.

    Uses responses() when:
    1. Native tool calling is enabled, OR
    2. Model has reasoning_effort set (reasoning_effort requires Responses API)

    When native_tool_calling is False and no reasoning_effort, uses standard completion() with XML tool calling.
    """
    from openhands.llm.model_features import get_features

    features = get_features(model)

    # MUST use responses() for Responses API models when reasoning_effort is set
    # (reasoning_effort is only supported in Responses API, not Chat Completions)
    if features.uses_responses_api and reasoning_effort:
        return True

    # Otherwise, only use responses() for Responses API models with native tool calling enabled
    return features.uses_responses_api and native_tool_calling is True


def litellm_responses_completion(
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    api_key: str | None = None,
    temperature: float = 0.2,
    max_tokens: int | None = None,
    reasoning_effort: str | None = None,
    **kwargs: Any
) -> ModelResponse:
    """Call gpt-5.2-codex using liteLLM's responses() method.

    liteLLM has native support for Responses API since Oct 2025.
    This bypasses Chat Completions and uses /v1/responses endpoint.
    """
    logger.info(f'Using liteLLM responses() method for {model}')

    # Convert messages to Responses API format (text → input_text/output_text)
    converted_messages = []
    for msg in messages:
        msg_copy = msg.copy()
        role = msg_copy.get('role')

        # Convert content types
        if isinstance(msg_copy.get('content'), list):
            converted_content = []
            for item in msg_copy['content']:
                item_copy = item.copy()
                if item_copy.get('type') == 'text':
                    if role in ['user', 'system']:
                        item_copy['type'] = 'input_text'
                    elif role == 'assistant':
                        item_copy['type'] = 'output_text'
                converted_content.append(item_copy)
            msg_copy['content'] = converted_content

        converted_messages.append(msg_copy)

    logger.info(f'Converted {len(converted_messages)} messages to Responses API format')

    # Prepare request parameters for liteLLM responses()
    # CRITICAL: liteLLM's responses() expects 'input' parameter (not 'messages')
    # This is different from completion() which uses 'messages'
    request_params = {
        'model': model,
        'input': converted_messages,  # ✅ CORRECT: liteLLM responses() uses 'input'
        'api_key': api_key,
    }

    # NOTE: Responses API does NOT support temperature parameter

    if max_tokens:
        request_params['max_output_tokens'] = max_tokens  # responses() parameter name

    if reasoning_effort:
        request_params['reasoning_effort'] = reasoning_effort

    # Convert tools from Chat Completions format to Responses API format
    # Chat Completions: {'type': 'function', 'function': {'name': '...', 'description': '...', 'parameters': {...}}}
    # Responses API: {'type': 'function', 'name': '...', 'description': '...', 'parameters': {...}}
    if tools:
        converted_tools = []
        for idx, tool in enumerate(tools):
            if isinstance(tool, dict):
                if 'type' in tool and tool['type'] == 'function':
                    if 'function' in tool:  # Nested format (Chat Completions)
                        function_obj = tool['function']
                        flattened_tool = {
                            'type': 'function',
                            'name': function_obj.get('name'),
                            'description': function_obj.get('description', ''),
                        }
                        if 'parameters' in function_obj:
                            flattened_tool['parameters'] = function_obj['parameters']
                        if 'strict' in function_obj:
                            flattened_tool['strict'] = function_obj['strict']
                        
                        if flattened_tool['name']:
                            converted_tools.append(flattened_tool)
                            logger.debug(f"Converted tool #{idx}: {flattened_tool['name']}")
                        else:
                            logger.warning(f"Tool #{idx} missing 'name' field: {tool}")
                    elif 'name' in tool:  # Already flattened format (Responses API)
                        converted_tools.append(tool)
                        logger.debug(f"Tool #{idx} already in Responses API format: {tool['name']}")
                    else:
                        logger.warning(f"Tool #{idx} missing both 'function' and 'name': {tool}")
                else:
                    logger.warning(f"Tool #{idx} missing 'type': {tool}")
            else:
                logger.warning(f"Tool #{idx} is not a dict: {type(tool)}")
        
        if converted_tools:
            request_params['tools'] = converted_tools
            logger.info(f"Converted {len(converted_tools)} tools for Responses API")
        else:
            logger.warning("No valid tools after conversion, omitting tools parameter")

    logger.info(f'liteLLM responses() call: model={model}, reasoning={reasoning_effort}, messages={len(converted_messages)}')

    try:
        response = litellm_responses(**request_params)

        # Convert to standard format
        response_dict = {
            'id': response.id if hasattr(response, 'id') else '',
            'object': 'chat.completion',
            'created': response.created_at if hasattr(response, 'created_at') else 0,
            'model': model,
            'choices': [],
            'usage': {}
        }

        # Extract usage if available
        if hasattr(response, 'usage'):
            usage_obj = response.usage
            response_dict['usage'] = {
                'prompt_tokens': getattr(usage_obj, 'input_tokens', 0) or getattr(usage_obj, 'prompt_tokens', 0),
                'completion_tokens': getattr(usage_obj, 'output_tokens', 0) or getattr(usage_obj, 'completion_tokens', 0),
                'total_tokens': getattr(usage_obj, 'total_tokens', 0),
            }
            # Add reasoning_tokens if present (xhigh reasoning)
            if hasattr(usage_obj, 'reasoning_tokens'):
                response_dict['usage']['reasoning_tokens'] = getattr(usage_obj, 'reasoning_tokens', 0)

        # Extract choices - Responses API uses 'output' instead of 'choices'
        if hasattr(response, 'output'):
            # Responses API format - single output
            choice_dict = {
                'index': 0,
                'message': {
                    'role': 'assistant',
                    'content': str(response.output) if response.output else '',
                },
                'finish_reason': response.status if hasattr(response, 'status') else 'stop',
            }

            # Handle tool calls if present in output
            if hasattr(response, 'tools') and response.tools:
                choice_dict['message']['tool_calls'] = []
                for tc in response.tools:
                    tool_call = {
                        'id': getattr(tc, 'id', ''),
                        'type': 'function',
                        'function': {
                            'name': getattr(tc, 'name', ''),
                            'arguments': getattr(tc, 'arguments', ''),
                        }
                    }
                    choice_dict['message']['tool_calls'].append(tool_call)

            response_dict['choices'].append(choice_dict)
            
        elif hasattr(response, 'choices'):
            # Standard Chat Completions format (fallback)
            for choice in response.choices:
                choice_dict = {
                    'index': getattr(choice, 'index', 0),
                    'message': {
                        'role': 'assistant',
                        'content': getattr(choice, 'output_text', '') if hasattr(choice, 'output_text') else getattr(choice.message, 'content', ''),
                    },
                    'finish_reason': getattr(choice, 'finish_reason', 'stop'),
                }

                # Handle tool calls if present
                if hasattr(choice, 'message') and hasattr(choice.message, 'tool_calls'):
                    if choice.message.tool_calls:
                        choice_dict['message']['tool_calls'] = [
                            {
                                'id': tc.id,
                                'type': tc.type,
                                'function': {
                                    'name': tc.function.name,
                                    'arguments': tc.function.arguments,
                                }
                            }
                            for tc in choice.message.tool_calls
                        ]

                response_dict['choices'].append(choice_dict)
        
        logger.info(f'liteLLM responses() successful: {response_dict["usage"].get("total_tokens", 0)} tokens')
        
        # Convert dict to ModelResponse object for compatibility
        return ModelResponse(**response_dict)

    except Exception as e:
        import traceback
        logger.error(f'liteLLM responses() failed: {e}')
        logger.error(f'Full traceback: {traceback.format_exc()}')
        raise
