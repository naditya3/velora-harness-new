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
    previous_output_items: list[dict] | None = None,  # NEW: For reasoning accumulation
    **kwargs: Any
) -> dict:
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

    # Append previous output_items to input for reasoning accumulation (CRITICAL!)
    if previous_output_items:
        logger.info(f'[REASONING] Appending {len(previous_output_items)} previous output_items for context')
        converted_messages.extend(previous_output_items)
        logger.info(f'[REASONING] Total items in input after appending: {len(converted_messages)}')

    logger.info(f'Converted {len(converted_messages)} messages to Responses API format')

    # DEBUG: Log first message to verify conversion
    if converted_messages:
        first_msg = converted_messages[0]
        if isinstance(first_msg.get('content'), list) and first_msg['content']:
            content_type = first_msg['content'][0].get('type', 'MISSING')
            logger.info(f'DEBUG: First message content[0].type = {content_type} (should be input_text)')

    # Prepare request parameters for liteLLM responses()
    # CRITICAL: liteLLM's responses() expects 'input' parameter (not 'messages')
    # This is different from completion() which uses 'messages'
    request_params = {
        'model': model,
        'input': converted_messages,  # ✅ CORRECT: liteLLM responses() uses 'input'
        'api_key': api_key,
    }

    # NOTE: Responses API does NOT support temperature parameter
    # Removed: 'temperature': temperature,

    if max_tokens:
        request_params['max_output_tokens'] = max_tokens  # responses() parameter name

    if reasoning_effort:
        # liteLLM expects reasoning={'effort': 'xhigh'}, not reasoning_effort='xhigh'
        request_params['reasoning'] = {'effort': reasoning_effort}

    # DEBUG: Log tools parameter received
    if tools:
        logger.info(f'[DEBUG-A] Tools parameter received: count={len(tools) if isinstance(tools, list) else 0}, type={type(tools)}')
        logger.info(f'[DEBUG-B] First tool BEFORE conversion: {tools[0] if tools else None}')

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
        
        logger.info(f'[DEBUG-D] Tools AFTER conversion: count={len(converted_tools)}, first={converted_tools[0] if converted_tools else None}')
        
        if converted_tools:
            request_params['tools'] = converted_tools
            logger.info(f"Converted {len(converted_tools)} tools for Responses API")
        else:
            logger.warning("No valid tools after conversion, omitting tools parameter")
    
    logger.info(f'[DEBUG-E] Final request_params: has_tools={"tools" in request_params}, tools_preview={request_params.get("tools", [])[:1] if "tools" in request_params else None}')

    # #region agent log
    # CRITICAL DEBUG: Log ALL request_params keys to verify reasoning is included
    logger.info(f'[DEBUG-PARAMS] Full request_params keys: {list(request_params.keys())}')
    logger.info(f'[DEBUG-PARAMS] reasoning in params: {"reasoning" in request_params}')
    if 'reasoning' in request_params:
        logger.info(f'[DEBUG-PARAMS] reasoning value: {request_params["reasoning"]}')
    else:
        logger.warning(f'[DEBUG-PARAMS] ⚠️ reasoning MISSING from request_params!')
    # #endregion

    logger.info(f'liteLLM responses() call: model={model}, reasoning={reasoning_effort}, messages_in_input={len(converted_messages)}')

    try:
        # #region agent log
        # Log the actual call to liteLLM
        logger.info(f'[DEBUG-LITELLM] Calling litellm.responses() with params: {list(request_params.keys())}')
        # #endregion
        
        response = litellm_responses(**request_params)

        # #region agent log
        # Log response object attributes to see if reasoning info is present
        logger.info(f'[DEBUG-RESPONSE] Response attributes: {dir(response)}')
        if hasattr(response, 'usage'):
            logger.info(f'[DEBUG-RESPONSE] Usage attributes: {dir(response.usage)}')
        # #endregion

        # DEBUG: Log raw response structure
        logger.info(f'[DEBUG-F] Raw response type: {type(response)}')
        logger.info(f'[DEBUG-H] Has choices attr: {hasattr(response, "choices")}')
        logger.info(f'[DEBUG-J] Has output attr: {hasattr(response, "output")}')
        if hasattr(response, 'output'):
            logger.info(f'[DEBUG-K] Output content: {str(response.output)[:200]}...')
        
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
            
            # CRITICAL: Store output_items for next turn's reasoning accumulation
            if hasattr(response, 'output') and response.output:
                # Convert output items to dict format for storage
                output_items_list = []
                if isinstance(response.output, list):
                    for item in response.output:
                        if hasattr(item, 'model_dump'):
                            output_items_list.append(item.model_dump())
                        elif isinstance(item, dict):
                            output_items_list.append(item)
                        else:
                            # Try to convert to dict
                            output_items_list.append({'type': getattr(item, 'type', 'unknown'), 'content': str(item)})
                choice_dict['message']['output_items'] = output_items_list
                logger.info(f'[REASONING] Stored {len(output_items_list)} output_items in message for next turn')

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
        
        logger.info(f'[DEBUG-L] Choices count after extraction: {len(response_dict["choices"])}')
        logger.info(f'liteLLM responses() successful: {response_dict["usage"].get("total_tokens", 0)} tokens, reasoning_tokens={response_dict["usage"].get("reasoning_tokens", 0)}')
        
        # Convert dict to ModelResponse object for compatibility
        return ModelResponse(**response_dict)

    except Exception as e:
        import traceback
        logger.error(f'liteLLM responses() failed: {e}')
        logger.error(f'Full traceback: {traceback.format_exc()}')
        raise
