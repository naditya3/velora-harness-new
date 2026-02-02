"""Native OpenAI client for Responses API (gpt-5.2-codex, o3, etc.)

This module bypasses liteLLM to support the Responses API format which differs from
Chat Completions API in tool and message structure.
"""

from __future__ import annotations

import json
from typing import Any

from openai import OpenAI

from openhands.core.logger import openhands_logger as logger


def should_use_responses_api_native(model: str) -> bool:
    """Check if model requires native Responses API client instead of liteLLM."""
    from openhands.llm.model_features import get_features

    features = get_features(model)
    return features.uses_responses_api


def convert_to_responses_api_format(
    messages: list[dict],
    tools: list[dict] | None = None
) -> tuple[list[dict], list[dict] | None]:
    """Convert messages and tools to Responses API format.

    Responses API differences:
    - User/system text: type='input_text' (not 'text')
    - Assistant text: type='output_text' (not 'text')
    - Tools: flat structure with name at top level (not nested in 'function')
    """
    # Convert messages
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

    # Convert tools (already done by check_tools in llm_utils.py, but ensure consistency)
    converted_tools = None
    if tools:
        converted_tools = []
        for tool in tools:
            if 'function' in tool and tool.get('type') == 'function':
                # Already flat format from check_tools
                if 'name' in tool:
                    converted_tools.append(tool)
                else:
                    # Need to flatten
                    converted_tools.append({
                        'type': tool['type'],
                        'name': tool['function']['name'],
                        'description': tool['function'].get('description', ''),
                        'parameters': tool['function'].get('parameters', {}),
                    })
            else:
                converted_tools.append(tool)

    return converted_messages, converted_tools


def native_responses_api_completion(
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    api_key: str | None = None,
    temperature: float = 0.2,
    max_tokens: int | None = None,
    reasoning_effort: str | None = None,
    **kwargs: Any
) -> dict:
    """Make direct API call to OpenAI Responses API.

    Args:
        model: Model name (gpt-5.2-codex, o3, etc.)
        messages: Messages in OpenAI format
        tools: Tools in OpenAI format
        api_key: OpenAI API key
        temperature: Sampling temperature
        max_tokens: Maximum tokens in response
        reasoning_effort: Reasoning effort level (low/medium/high/xhigh)
        **kwargs: Additional parameters

    Returns:
        Response in Chat Completions format (for compatibility)
    """
    logger.info(f'Using native OpenAI Responses API for {model}')

    # Convert to Responses API format
    converted_messages, converted_tools = convert_to_responses_api_format(messages, tools)

    # Initialize OpenAI client
    import httpx

    # Responses API uses /v1/responses endpoint, not /v1/chat/completions
    base_url = "https://api.openai.com/v1"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

    # Build request parameters
    request_params = {
        'model': model,
        'messages': converted_messages,
        'temperature': temperature,
    }

    if max_tokens:
        request_params['max_tokens'] = max_tokens

    if reasoning_effort:
        request_params['reasoning_effort'] = reasoning_effort

    if converted_tools:
        request_params['tools'] = converted_tools

    logger.info(f'Responses API request to /v1/responses: model={model}, messages={len(converted_messages)}, tools={len(converted_tools) if converted_tools else 0}')

    # Make API call to /v1/responses endpoint
    try:
        with httpx.Client() as http_client:
            response_raw = http_client.post(
                f"{base_url}/responses",
                headers=headers,
                json=request_params,
                timeout=120.0
            )
            response_raw.raise_for_status()
            response_data = response_raw.json()

        # Convert response back to standard format
        # Responses API returns JSON dict, not object
        import time

        response_dict = {
            'id': response_data.get('id', ''),
            'object': response_data.get('object', 'chat.completion'),
            'created': response_data.get('created', int(time.time())),
            'model': response_data.get('model', model),
            'choices': [],
            'usage': response_data.get('usage', {
                'prompt_tokens': 0,
                'completion_tokens': 0,
                'total_tokens': 0,
            })
        }

        for choice in response_data.get('choices', []):
            message = choice.get('message', {})
            choice_dict = {
                'index': choice.get('index', 0),
                'message': {
                    'role': message.get('role', 'assistant'),
                    'content': message.get('content'),
                },
                'finish_reason': choice.get('finish_reason', 'stop'),
            }

            # Add tool calls if present
            if 'tool_calls' in message and message['tool_calls']:
                choice_dict['message']['tool_calls'] = [
                    {
                        'id': tc.get('id', ''),
                        'type': tc.get('type', 'function'),
                        'function': {
                            'name': tc.get('function', {}).get('name', ''),
                            'arguments': tc.get('function', {}).get('arguments', ''),
                        }
                    }
                    for tc in message['tool_calls']
                ]

            response_dict['choices'].append(choice_dict)

        total_tokens = response_data.get('usage', {}).get('total_tokens', 0)
        logger.info(f'Responses API call successful: {total_tokens} tokens')
        return response_dict

    except Exception as e:
        logger.error(f'Responses API call failed: {e}')
        raise
