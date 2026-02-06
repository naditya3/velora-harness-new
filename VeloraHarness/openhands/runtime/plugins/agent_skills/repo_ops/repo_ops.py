try:
    from openhands_aci.indexing.locagent.tools import (
        explore_tree_structure,
        get_entity_contents,
        search_code_snippets,
    )
except ImportError:
    # Fallback stub implementations when openhands-aci is not available
    def get_entity_contents(*args, **kwargs):
        return "Repository operations not available (openhands-aci not installed)"

    def search_code_snippets(*args, **kwargs):
        return "Repository operations not available (openhands-aci not installed)"

    def explore_tree_structure(*args, **kwargs):
        return "Repository operations not available (openhands-aci not installed)"

__all__ = [
    'get_entity_contents',
    'search_code_snippets',
    'explore_tree_structure',
]
