"""Linter module for OpenHands.

Part of this Linter module is adapted from Aider (Apache 2.0 License, [original
code](https://github.com/paul-gauthier/aider/blob/main/aider/linter.py)).
- Please see the [original repository](https://github.com/paul-gauthier/aider) for more information.
- The detailed implementation of the linter can be found at: https://github.com/OpenHands/openhands-aci.
"""

try:
    from openhands_aci.linter import DefaultLinter, LintResult
except ImportError:
    # Fallback stub implementation when openhands-aci is not available
    class LintResult:
        def __init__(self, text='', edits=None, errors=None):
            self.text = text
            self.edits = edits or []
            self.errors = errors or []

    class DefaultLinter:
        def lint(self, code, language=None):
            return LintResult(text=code, edits=[], errors=[])

__all__ = ['DefaultLinter', 'LintResult']
