# Task List

1. ✅ Explore repository and identify relevant functionality for cell type extraction/enrichment
Reviewed Query, SlimManager, sparql_queries, query_utils, and existing placeholder tests; identified likely bug with None property_list in get_simple_enrichment_query and potential need for contextual enrichment with tissue labels.
2. ✅ Create reproduction script for current behavior or missing tests
Created repro_issue.py, confirmed crash: get_simple_enrichment_query attempts to join None property_list when enrichment_property_list not provided.
3. ✅ Implement/adjust source code if needed to support test cases (cell types, contextual enrichment)
Fixed get_simple_enrichment_query to accept Optional property_list and default to rdfs:subClassOf.
4. ✅ Add unit tests covering the two specified cellxgene datasets and enrichment scenarios
Added pytest conftest to include src on sys.path, and added tests for two provided cellxgene dataset cell type lists, blood_and_immune_upper_slim enrichment, and contextual enrichment using tissue terms (kidney/renal medulla). Tests mock SPARQL to avoid network flakiness.
5. ✅ Run full test suite and iterate until all pass
pytest now passes: 19 passed.
