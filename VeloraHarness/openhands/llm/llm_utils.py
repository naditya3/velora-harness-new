import copy
from typing import TYPE_CHECKING

from openhands.core.config import LLMConfig
from openhands.core.logger import openhands_logger as logger
from openhands.llm.model_features import get_features

if TYPE_CHECKING:
    from litellm import ChatCompletionToolParam


def convert_messages_for_responses_api(messages: list[dict]) -> list[dict]:
    """Convert messages from Chat Completions format to Responses API format.

    Responses API requires different content type values:
    - User text: 'input_text' instead of 'text'
    - Assistant text: 'output_text' instead of 'text'
    """
    converted = []
    for msg in messages:
        msg_copy = copy.deepcopy(msg)
        role = msg_copy.get('role')

        # Convert content types based on role
        if isinstance(msg_copy.get('content'), list):
            for content_item in msg_copy['content']:
                if content_item.get('type') == 'text':
                    if role == 'user' or role == 'system':
                        content_item['type'] = 'input_text'
                    elif role == 'assistant':
                        content_item['type'] = 'output_text'

        converted.append(msg_copy)
    return converted


def check_tools(
    tools: list['ChatCompletionToolParam'], llm_config: LLMConfig
) -> list['ChatCompletionToolParam']:
    """Checks and modifies tools for compatibility with the current LLM."""
    # prevent mutation of input tools
    checked_tools = copy.deepcopy(tools)

    # Check if model uses Responses API format
    # BUT only convert if native_tool_calling is EXPLICITLY True
    # (XML mode and None need nested format for fn_call_converter)
    features = get_features(llm_config.model)
    if features.uses_responses_api and llm_config.native_tool_calling is True:
        logger.info(
            f'Converting tools to Responses API format for model {llm_config.model} '
            '(flat structure with name at top level instead of nested function object)'
        )
        # Convert from Chat Completions format to Responses API format
        # Chat Completions: {type: "function", function: {name, description, parameters}}
        # Responses API: {type: "function", name, description, parameters}
        converted_tools = []
        for tool in checked_tools:
            if 'function' in tool and tool.get('type') == 'function':
                # Flatten the structure by moving function fields to top level
                converted_tool = {
                    'type': tool['type'],
                    'name': tool['function']['name'],
                    'description': tool['function'].get('description', ''),
                    'parameters': tool['function'].get('parameters', {}),
                }
                # Preserve cache_control if present
                if 'cache_control' in tool:
                    converted_tool['cache_control'] = tool['cache_control']
                converted_tools.append(converted_tool)
            else:
                # Keep non-function tools as-is
                converted_tools.append(tool)
        return converted_tools

    # Special handling for Gemini models which don't support default fields and have limited format support
    if 'gemini' in llm_config.model.lower():
        logger.info(
            f'Removing default fields and unsupported formats from tools for Gemini model {llm_config.model} '
            "since Gemini models have limited format support (only 'enum' and 'date-time' for STRING types)."
        )
        # Strip off default fields and unsupported formats that cause errors with gemini-preview
        for tool in checked_tools:
            if 'function' in tool and 'parameters' in tool['function']:
                if 'properties' in tool['function']['parameters']:
                    for prop_name, prop in tool['function']['parameters'][
                        'properties'
                    ].items():
                        # Remove default fields
                        if 'default' in prop:
                            del prop['default']

                        # Remove format fields for STRING type parameters if the format is unsupported
                        # Gemini only supports 'enum' and 'date-time' formats for STRING type
                        if prop.get('type') == 'string' and 'format' in prop:
                            supported_formats = ['enum', 'date-time']
                            if prop['format'] not in supported_formats:
                                logger.info(
                                    f'Removing unsupported format "{prop["format"]}" for STRING parameter "{prop_name}"'
                                )
                                del prop['format']
        return checked_tools
    return checked_tools
