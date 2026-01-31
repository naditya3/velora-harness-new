"""Direct OpenAI SDK Responses API support for GPT-5.2-Codex

BYPASSES liteLLM to avoid reasoning_effort bugs (GitHub issues #13699, #16032).
Uses official OpenAI Python SDK for direct, reliable API access.

This implementation:
1. Uses OpenAI SDK directly (not liteLLM)
2. Supports xhigh reasoning effort (validated as official GPT-5.2 feature)
3. Uses previous_response_id for state management (OpenAI handles context)
4. Handles tool calling in Responses API format

INTEGRATION:
- Pass `conversation_id` to track state between turns
- For OpenHands, use `state.session_id` or generate with `generate_conversation_id()`
- State is automatically cleared on API errors
"""

from __future__ import annotations

import json
import uuid
from typing import Any

from openai import OpenAI
from litellm.types.utils import ModelResponse

from openhands.core.logger import openhands_logger as logger


# ============================================================================
# STATE MANAGEMENT: Track response IDs per conversation
# ============================================================================
# Key: conversation_id, Value: {'response_id': str, 'pending_tool_calls': list, 'processed_call_ids': set}
_response_state: dict[str, dict] = {}


def generate_conversation_id() -> str:
    """Generate a unique conversation ID for state tracking."""
    return f"conv_{uuid.uuid4().hex[:16]}"


def get_conversation_state(conversation_id: str | None) -> dict | None:
    """Get stored state for a conversation."""
    if not conversation_id:
        return None
    return _response_state.get(conversation_id)


def store_conversation_state(
    conversation_id: str | None,
    response_id: str,
    pending_tool_calls: list | None = None,
    processed_call_ids: set | None = None
):
    """Store state after a successful API call."""
    if not conversation_id:
        return
    
    # Get existing processed_call_ids and add new ones
    existing = _response_state.get(conversation_id, {})
    all_processed = existing.get('processed_call_ids', set())
    if processed_call_ids:
        all_processed = all_processed | processed_call_ids
    
    _response_state[conversation_id] = {
        'response_id': response_id,
        'pending_tool_calls': pending_tool_calls or [],
        'processed_call_ids': all_processed,
    }
    logger.info(f'[STATE] Stored response_id={response_id} for conversation={conversation_id}, processed={len(all_processed)} call_ids')


def clear_conversation_state(conversation_id: str | None):
    """Clear state for a conversation (e.g., on error or reset)."""
    if conversation_id and conversation_id in _response_state:
        del _response_state[conversation_id]
        logger.info(f'[STATE] Cleared state for conversation={conversation_id}')


def openai_responses_completion(
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    api_key: str | None = None,
    max_tokens: int | None = None,
    reasoning_effort: str | None = None,
    conversation_id: str | None = None,
    **kwargs: Any
) -> ModelResponse:
    """Call GPT-5.2-Codex using OpenAI SDK with previous_response_id state management.
    
    This implementation uses OpenAI's built-in state management:
    - First call: Send full initial context (system as instructions, user messages as input)
    - Subsequent calls: Use previous_response_id, only send new function_call_outputs
    
    Args:
        model: Model identifier (e.g., "gpt-5.2-codex")
        messages: Conversation history in Chat Completions format
        tools: Function definitions for tool calling
        api_key: OpenAI API key
        max_tokens: Maximum tokens to generate
        reasoning_effort: Reasoning level (low, medium, high, xhigh)
        conversation_id: Unique ID for this conversation (for state tracking)
        **kwargs: Additional parameters (ignored for direct SDK)
    
    Returns:
        ModelResponse: Compatible response with choices, usage, tool_calls, etc.
    """
    logger.info(f'[OPENAI-SDK] Using DIRECT OpenAI SDK for {model} (bypassing liteLLM)')
    logger.info(f'[OPENAI-SDK] conversation_id={conversation_id}')
    
    # Initialize OpenAI client
    client = OpenAI(api_key=api_key)
    
    # Check if we have a previous response for this conversation
    state = get_conversation_state(conversation_id)
    prev_response_id = state.get('response_id') if state else None
    
    if prev_response_id:
        # =====================================================================
        # SUBSEQUENT CALL: Use previous_response_id, only send new items
        # =====================================================================
        logger.info(f'[STATE] Found previous_response_id={prev_response_id}')
        
        # Get already-processed call_ids so we don't resend them
        processed_call_ids = state.get('processed_call_ids', set())
        
        # Extract ONLY NEW function_call_outputs from messages (role='tool')
        # Skip any that we've already sent in previous calls
        new_items = []
        new_call_ids = set()
        for msg in messages:
            if msg.get('role') == 'tool':
                tool_call_id = msg.get('tool_call_id', '')
                
                # Skip if we've already processed this call_id
                if tool_call_id in processed_call_ids:
                    continue
                
                tool_content = msg.get('content', '')
                
                # Convert content to string if needed
                if not isinstance(tool_content, str):
                    tool_content = json.dumps(tool_content) if tool_content else ''
                
                # CRITICAL: Use the EXACT ID from OpenAI - do NOT normalize!
                new_items.append({
                    'type': 'function_call_output',
                    'call_id': tool_call_id,
                    'output': tool_content,
                })
                new_call_ids.add(tool_call_id)
                logger.info(f'[STATE] Added NEW function_call_output: call_id={tool_call_id}')
        
        logger.info(f'[STATE] Skipped {len(processed_call_ids)} already-processed, sending {len(new_items)} new')
        
        request_params = {
            'model': model,
            'previous_response_id': prev_response_id,
            'input': new_items if new_items else [],
            'store': True,  # Enable OpenAI's state management
        }
        
        logger.info(f'[STATE] Subsequent call with {len(new_items)} new function_call_outputs')
    
    else:
        # =====================================================================
        # FIRST CALL: Convert initial messages to Responses API format
        # =====================================================================
        logger.info('[STATE] No previous response - starting fresh conversation')
        
        # Extract system message as instructions, user messages as input
        instructions = None
        input_items = []
        
        for msg in messages:
            role = msg.get('role')
            content = msg.get('content', '')
            
            # Convert content to string if needed
            if not isinstance(content, str):
                if isinstance(content, list):
                    # Extract text from content blocks
                    text_parts = []
                    for item in content:
                        if isinstance(item, dict) and 'text' in item:
                            text_parts.append(item['text'])
                        elif isinstance(item, str):
                            text_parts.append(item)
                    content = '\n'.join(text_parts)
                else:
                    content = json.dumps(content) if content else ''
            
            if role == 'system':
                # System message becomes instructions parameter
                if instructions:
                    instructions += '\n\n' + content
                else:
                    instructions = content
                logger.info(f'[CONVERT] System message -> instructions ({len(content)} chars)')
            
            elif role == 'user':
                # User messages become input items
                input_items.append({
                    'type': 'message',
                    'role': 'user',
                    'content': [{'type': 'input_text', 'text': content}],
                })
                logger.info(f'[CONVERT] User message -> input item ({len(content)} chars)')
            
            elif role == 'assistant':
                # On first call, we generally shouldn't have assistant messages
                # But if we do (e.g., pre-filled context), include as output
                if content and content.strip():
                    input_items.append({
                        'type': 'message',
                        'role': 'assistant',
                        'content': [{'type': 'output_text', 'text': content}],
                    })
                    logger.info(f'[CONVERT] Assistant message -> output item ({len(content)} chars)')
                
                # Handle tool_calls on assistant messages (shouldn't happen on first call)
                if 'tool_calls' in msg:
                    logger.warning('[CONVERT] Unexpected tool_calls on first call - skipping')
            
            elif role == 'tool':
                # Tool results shouldn't be in first call either
                logger.warning('[CONVERT] Unexpected tool message on first call - skipping')
        
        request_params = {
            'model': model,
            'input': input_items,
            'store': True,  # Enable OpenAI's state management
        }
        
        if instructions:
            request_params['instructions'] = instructions
        
        logger.info(f'[CONVERT] First call with {len(input_items)} input items')
    
    # =========================================================================
    # ADD COMMON PARAMETERS: reasoning, tools, max_tokens
    # =========================================================================
    
    # Add reasoning effort
    if reasoning_effort:
        request_params['reasoning'] = {'effort': reasoning_effort}
        logger.info(f'[REASONING] Using reasoning_effort={reasoning_effort}')
    
    # Convert and add tools
    if tools:
        converted_tools = []
        for tool in tools:
            if isinstance(tool, dict) and tool.get('type') == 'function':
                if 'function' in tool:
                    # Nested format (Chat Completions) -> flatten for Responses API
                    func = tool['function']
                    flattened = {
                        'type': 'function',
                        'name': func.get('name'),
                        'description': func.get('description', ''),
                    }
                    if 'parameters' in func:
                        flattened['parameters'] = func['parameters']
                    if 'strict' in func:
                        flattened['strict'] = func['strict']
                    converted_tools.append(flattened)
                elif 'name' in tool:
                    # Already in Responses API format
                    converted_tools.append(tool)
        
        if converted_tools:
            request_params['tools'] = converted_tools
            logger.info(f'[TOOLS] Added {len(converted_tools)} tools')
    
    # Add max tokens
    if max_tokens:
        request_params['max_output_tokens'] = max_tokens
    
    # =========================================================================
    # MAKE THE API CALL
    # =========================================================================
    logger.info(f'[OPENAI-SDK] Calling responses.create() with store=True')
    
    try:
        response = client.responses.create(**request_params)
        
        logger.info(f'[OPENAI-SDK] Response received: id={response.id}')
        
        # Extract tool calls from output (for state tracking)
        pending_tool_calls = []
        for item in (response.output or []):
            if getattr(item, 'type', None) == 'function_call':
                pending_tool_calls.append({
                    'id': getattr(item, 'id', ''),
                    'name': getattr(item, 'name', ''),
                })
        
        # Store the response ID for next turn
        # Include the call_ids we just processed so we don't resend them
        store_conversation_state(
            conversation_id,
            response.id,
            pending_tool_calls,
            new_call_ids if prev_response_id else set()
        )
        
        # =====================================================================
        # CONVERT RESPONSE TO ModelResponse FORMAT
        # =====================================================================
        response_dict = {
            'id': response.id,
            'object': 'chat.completion',
            'created': int(response.created_at) if hasattr(response, 'created_at') else 0,
            'model': response.model,
            'choices': [],
        }
        
        # Extract usage
        if hasattr(response, 'usage') and response.usage:
            usage_obj = response.usage
            response_dict['usage'] = {
                'prompt_tokens': getattr(usage_obj, 'input_tokens', 0),
                'completion_tokens': getattr(usage_obj, 'output_tokens', 0),
                'total_tokens': getattr(usage_obj, 'total_tokens', 0),
            }
            if hasattr(usage_obj, 'reasoning_tokens'):
                response_dict['usage']['reasoning_tokens'] = getattr(usage_obj, 'reasoning_tokens', 0)
                logger.info(f'[REASONING] reasoning_tokens={response_dict["usage"]["reasoning_tokens"]}')
        
        # Extract output content and tool calls
        content_text = ''
        tool_calls_list = []
        
        if hasattr(response, 'output') and response.output:
            for item in response.output:
                item_type = getattr(item, 'type', 'unknown')
                
                if item_type == 'message':
                    # Extract text from message
                    if hasattr(item, 'content'):
                        for content_item in item.content:
                            if hasattr(content_item, 'text'):
                                content_text += content_item.text
                
                elif item_type == 'function_call':
                    # Extract tool call - use call_id (not id!) for correlation
                    # OpenAI returns: {id: "fc_xxx", call_id: "call_xxx", ...}
                    # function_call_output must use call_id to correlate
                    tool_call_id = getattr(item, 'call_id', None) or getattr(item, 'id', f'call_{len(tool_calls_list)}')
                    tool_call_name = getattr(item, 'name', '')
                    tool_call_args = getattr(item, 'arguments', None)
                    
                    logger.info(f'[OUTPUT] Tool call: id={tool_call_id}, name={tool_call_name}')
                    
                    # Convert arguments to JSON string if needed
                    if isinstance(tool_call_args, dict):
                        tool_call_args = json.dumps(tool_call_args)
                    elif tool_call_args is None:
                        tool_call_args = '{}'
                    
                    tool_calls_list.append({
                        'id': tool_call_id,  # Use exact ID - don't normalize!
                        'type': 'function',
                        'function': {
                            'name': tool_call_name,
                            'arguments': tool_call_args,
                        }
                    })
        
        # Build choice
        choice_dict = {
            'index': 0,
            'message': {
                'role': 'assistant',
                'content': content_text if content_text else None,
            },
            'finish_reason': response.status if hasattr(response, 'status') else 'stop',
        }
        
        if tool_calls_list:
            choice_dict['message']['tool_calls'] = tool_calls_list
            logger.info(f'[OUTPUT] Added {len(tool_calls_list)} tool calls to response')
        
        response_dict['choices'].append(choice_dict)
        
        logger.info(f'[OPENAI-SDK] Complete: {response_dict.get("usage", {}).get("total_tokens", 0)} tokens')
        
        return ModelResponse(**response_dict)
    
    except Exception as e:
        logger.error(f'[OPENAI-SDK] API call failed: {e}')
        
        # Clear state on error so next call starts fresh
        clear_conversation_state(conversation_id)
        
        import traceback
        logger.error(f'[OPENAI-SDK] Traceback:\n{traceback.format_exc()}')
        raise
