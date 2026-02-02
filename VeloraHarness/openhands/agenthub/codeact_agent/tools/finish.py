from litellm import ChatCompletionToolParam, ChatCompletionToolParamFunctionChunk

from openhands.llm.tool_names import FINISH_TOOL_NAME

_FINISH_DESCRIPTION = """Signals the completion of the current task or conversation.

IMPORTANT: Use this tool ONLY when you have thoroughly completed the task:
- You have taken MULTIPLE actions (at least 3-5 steps)
- You have VERIFIED your solution works (tests pass, changes validated)
- You have explored, implemented, tested, and confirmed the fix

DO NOT use this tool if:
- You have only taken 1-2 actions
- You haven't verified that your solution works
- You're unsure whether the task is complete
- Tests are still failing or you haven't run tests yet

The message should include:
- A clear summary of all actions taken and their results
- Verification that tests pass or the solution works
- Any next steps for the user
- Explanation if you're unable to complete the task
"""

FinishTool = ChatCompletionToolParam(
    type='function',
    function=ChatCompletionToolParamFunctionChunk(
        name=FINISH_TOOL_NAME,
        description=_FINISH_DESCRIPTION,
        parameters={
            'type': 'object',
            'required': ['message'],
            'properties': {
                'message': {
                    'type': 'string',
                    'description': 'Final message to send to the user',
                },
            },
        },
    ),
)
