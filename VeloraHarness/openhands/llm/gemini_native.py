"""
Native Google GenAI SDK integration for Gemini 3 models with thinking support.

This module provides direct integration with Google's GenAI SDK to support
thought_signatures in Gemini 3 Pro models with high reasoning mode.

liteLLM doesn't currently support thought_signatures properly, so we bypass it
for Gemini 3 models when thinking is enabled.
"""

import json
from typing import Any

from google import genai
from google.genai.types import (
    Content,
    FunctionDeclaration,
    GenerateContentConfig,
    Part,
    ThinkingConfig,
    Tool,
)

from openhands.core.logger import openhands_logger as logger


def should_use_native_gemini(model: str, completion_kwargs: dict | None) -> bool:
    """
    Determine if we should use native Gemini SDK instead of liteLLM.

    Returns True for Gemini 3 models with thinking enabled.
    """
    if 'gemini-3' not in model.lower() and 'gemini/gemini-3' not in model.lower():
        return False

    if completion_kwargs and 'thinkingLevel' in completion_kwargs:
        thinking_level = completion_kwargs['thinkingLevel']
        # Use native SDK for medium or high thinking
        return thinking_level in ['medium', 'high']

    return False


def convert_openai_messages_to_genai_contents(messages: list[dict]) -> list[Content]:
    """
    Convert OpenAI-format messages to Google GenAI Content objects.

    Args:
        messages: List of messages in OpenAI format

    Returns:
        List of Content objects for GenAI SDK
    """
    contents = []

    for msg in messages:
        role = msg.get('role', 'user')

        # Map OpenAI roles to GenAI roles
        if role == 'assistant':
            role = 'model'
        elif role == 'system':
            # System messages become user messages with context
            role = 'user'
        elif role == 'tool':
            # Tool responses stay as 'tool'
            role = 'tool'

        parts = []

        # Handle text content
        if isinstance(msg.get('content'), str) and msg['content']:
            parts.append(Part(text=msg['content']))
        elif isinstance(msg.get('content'), list):
            for item in msg['content']:
                if item.get('type') == 'text':
                    parts.append(Part(text=item['text']))

        # Handle tool/function calls
        if msg.get('tool_calls'):
            for tool_call in msg['tool_calls']:
                func = tool_call.get('function', {})
                parts.append(Part(
                    function_call={
                        'name': func.get('name'),
                        'args': json.loads(func.get('arguments', '{}'))
                    }
                ))

        # Handle tool responses
        if role == 'tool' and msg.get('name'):
            parts.append(Part.from_function_response(
                name=msg['name'],
                response=json.loads(msg.get('content', '{}'))
            ))

        if parts:
            contents.append(Content(role=role, parts=parts))

    return contents


def convert_openai_tools_to_genai_tools(tools: list[dict]) -> list[Tool]:
    """
    Convert OpenAI-format tools to Google GenAI Tool objects.

    Args:
        tools: List of tools in OpenAI format

    Returns:
        List of Tool objects for GenAI SDK
    """
    function_declarations = []

    for tool in tools:
        if tool.get('type') == 'function':
            func = tool.get('function', {})
            function_declarations.append(
                FunctionDeclaration(
                    name=func.get('name'),
                    description=func.get('description', ''),
                    parameters=func.get('parameters', {})
                )
            )

    return [Tool(function_declarations=function_declarations)] if function_declarations else []


def native_gemini_completion(
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    api_key: str | None = None,
    completion_kwargs: dict | None = None,
    **kwargs
) -> dict:
    """
    Make a completion request using native Google GenAI SDK.

    This function properly handles thought_signatures for Gemini 3 models.

    Args:
        model: Model name (e.g., 'gemini/gemini-3-pro-preview')
        messages: Conversation history in OpenAI format
        tools: Available tools/functions
        api_key: Google API key
        completion_kwargs: Additional parameters (thinkingLevel, etc.)
        **kwargs: Other parameters

    Returns:
        Response in OpenAI-compatible format
    """
    logger.info(f'Using native GenAI SDK for {model} with thinking support')

    # Initialize client
    client = genai.Client(api_key=api_key)

    # Clean model name
    model_name = model.replace('gemini/', '')

    # Convert messages to GenAI format
    contents = convert_openai_messages_to_genai_contents(messages)

    # Convert tools if provided
    genai_tools = convert_openai_tools_to_genai_tools(tools) if tools else None

    # Build configuration
    config_dict = {}

    # Add tools
    if genai_tools:
        config_dict['tools'] = genai_tools

    # Configure thinking
    if completion_kwargs and 'thinkingLevel' in completion_kwargs:
        thinking_level = completion_kwargs['thinkingLevel']
        config_dict['thinking_config'] = ThinkingConfig(
            include_thoughts=True,
            mode=thinking_level.upper() if thinking_level in ['low', 'high'] else 'HIGH'
        )

    # Add other generation parameters
    config_dict['temperature'] = kwargs.get('temperature', 0.0)
    if kwargs.get('max_tokens'):
        config_dict['max_output_tokens'] = kwargs['max_tokens']

    config = GenerateContentConfig(**config_dict)

    # Make API call
    try:
        response = client.models.generate_content(
            model=model_name,
            contents=contents,
            config=config
        )
    except Exception as e:
        logger.error(f'Native GenAI SDK error: {e}')
        raise

    # Convert response back to OpenAI format for compatibility
    openai_response = convert_genai_response_to_openai(response, model)

    return openai_response


def convert_genai_response_to_openai(genai_response, model: str) -> dict:
    """
    Convert Google GenAI response to OpenAI-compatible format.

    Args:
        genai_response: Response from GenAI SDK
        model: Model name

    Returns:
        Response in OpenAI format
    """
    choice = genai_response.candidates[0]
    content_parts = choice.content.parts

    # Extract text content (skip thinking parts)
    text_content = ''
    tool_calls = []

    for part in content_parts:
        # Check if this is a thought part (thinking)
        if hasattr(part, 'thought') and part.thought:
            # Skip thinking parts from final content
            continue

        # Extract text
        if part.text:
            text_content += part.text

        # Extract function calls
        if part.function_call:
            tool_calls.append({
                'id': f'call_{len(tool_calls)}',
                'type': 'function',
                'function': {
                    'name': part.function_call.name,
                    'arguments': json.dumps(dict(part.function_call.args))
                }
            })

    # Build OpenAI-compatible response
    message = {
        'role': 'assistant',
        'content': text_content or None,
    }

    if tool_calls:
        message['tool_calls'] = tool_calls

    # Store original GenAI content for history preservation
    # This is crucial - it contains thought_signatures that must be preserved
    message['_genai_content'] = choice.content

    # Build complete response
    openai_response = {
        'id': f'genai-{id(genai_response)}',
        'object': 'chat.completion',
        'created': int(genai_response.usage_metadata.candidates_billable_characters if hasattr(genai_response, 'usage_metadata') else 0),
        'model': model,
        'choices': [{
            'index': 0,
            'message': message,
            'finish_reason': 'tool_calls' if tool_calls else 'stop'
        }],
        'usage': {
            'prompt_tokens': genai_response.usage_metadata.prompt_token_count if hasattr(genai_response, 'usage_metadata') else 0,
            'completion_tokens': genai_response.usage_metadata.candidates_token_count if hasattr(genai_response, 'usage_metadata') else 0,
            'total_tokens': genai_response.usage_metadata.total_token_count if hasattr(genai_response, 'usage_metadata') else 0,
        }
    }

    return openai_response
