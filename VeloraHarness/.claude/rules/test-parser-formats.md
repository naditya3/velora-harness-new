# Test Parser Formats Reference

This document describes the test output parser formats supported by VeloraHarness and the expected format for FAIL_TO_PASS and PASS_TO_PASS test lists in datasets.

## Parser Location

**File**: [evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/eval_standardized_swe.py](../../../evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/eval_standardized_swe.py)

**Parser Registry** (lines 343-349):
```python
PARSER_REGISTRY: Dict[str, Callable] = {
    "python/parse_log_pytest_v3": parse_log_pytest_v3,
    "python/parse_log_pytest": parse_log_pytest_v3,  # Alias
    "python/parse_log_unittest": parse_log_unittest,
    "php/parse_log_phpunit": parse_log_phpunit,
    "parsers/ruby_minitest_parser.py": parse_log_ruby_minitest,  # Dataset parser path
    "ruby/parse_log_minitest": parse_log_ruby_minitest,  # Standard alias
}
```

## Supported Test Frameworks

### 1. Python - pytest (pytest_v3)

**Parser Function**: `parse_log_pytest_v3` (lines 57-94)

**Test Name Format**: `path/to/test_file.py::TestClass::test_method`

**Example FAIL_TO_PASS/PASS_TO_PASS Format**:
```json
{
  "FAIL_TO_PASS": "[\"tests/test_feature.py::TestAuth::test_login\", \"tests/test_api.py::TestAPI::test_create\"]",
  "PASS_TO_PASS": "[\"tests/test_utils.py::TestUtils::test_format\"]"
}
```

**Test Output Format Recognized**:
- `PASSED tests/test_file.py::TestClass::test_method`
- `FAILED tests/test_file.py::TestClass::test_method`
- `ERROR tests/test_file.py::TestClass::test_method`
- `SKIPPED tests/test_file.py::TestClass::test_method`

**Dataset Field**:
```json
{
  "test_output_parser": "python/parse_log_pytest_v3"
}
```

---

### 2. Python - unittest

**Parser Function**: `parse_log_unittest` (lines 97-125)

**Test Name Format**: `test_method (module.TestClass)`

**Example FAIL_TO_PASS/PASS_TO_PASS Format**:
```json
{
  "FAIL_TO_PASS": "[\"test_login (tests.test_auth.TestAuth)\", \"test_create (tests.test_api.TestAPI)\"]",
  "PASS_TO_PASS": "[\"test_format (tests.test_utils.TestUtils)\"]"
}
```

**Test Output Format Recognized**:
- `test_method (module.TestClass) ... ok`
- `test_method (module.TestClass) ... FAIL`
- `test_method (module.TestClass) ... ERROR`
- `test_method (module.TestClass) ... skipped`

**Dataset Field**:
```json
{
  "test_output_parser": "python/parse_log_unittest"
}
```

---

### 3. PHP - PHPUnit

**Parser Function**: `parse_log_phpunit` (lines 128-272)

**Test Name Format**: `Namespace\\TestClass::testMethod`

**Example FAIL_TO_PASS/PASS_TO_PASS Format**:
```json
{
  "FAIL_TO_PASS": "[\"App\\\\Tests\\\\AuthTest::testLogin\", \"App\\\\Tests\\\\ApiTest::testCreate\"]",
  "PASS_TO_PASS": "[\"App\\\\Tests\\\\UtilsTest::testFormat\"]"
}
```

**Important**: Double escape backslashes in JSON strings!

**Test Output Format Recognized** (Testdox format):
```
Class Name (Namespace\TestClass)
 ✔ Test name passes
 ✘ Test name fails
```

Maps to: `Namespace\TestClass::testTestNamePasses`

**Dataset Field**:
```json
{
  "test_output_parser": "php/parse_log_phpunit"
}
```

---

### 4. Ruby - Minitest ⭐ NEW

**Parser Function**: `parse_log_ruby_minitest` (lines 275-354)

**Test Name Format**: `ClassName::SubClass#test_method`

**Example FAIL_TO_PASS/PASS_TO_PASS Format** (Shopify/liquid):
```json
{
  "FAIL_TO_PASS": "[\"SnippetTest::LaxMode#test_valid_inline_snippet\", \"SnippetTest::RigidMode#test_render_inline_snippet\"]",
  "PASS_TO_PASS": "[\"AssignTest#test_assign_score_exceeding_limit_from_composite_object\", \"ContextTest#test_access_hashes_with_hash_access_variables\"]"
}
```

**Key Format Rules**:
- Use `::` to separate class/module hierarchy
- Use `#` to separate class from test method
- Test method names typically start with `test_`
- Examples:
  - Simple: `MyTest#test_something`
  - Nested: `MyTest::SubClass#test_something`
  - Module + Class: `MyModule::MyTest#test_something`

**Test Output Format Recognized**:

**Format 1** (Primary - Minitest default):
```
ClassName::SubClass#test_method = 0.05 s = .
ClassName::SubClass#test_method = 0.05 s = F
ClassName::SubClass#test_method = 0.05 s = E
ClassName::SubClass#test_method = 0.05 s = S
```
Where result codes are:
- `.` = PASSED
- `F` = FAILED
- `E` = ERROR
- `S` or `N` = SKIPPED

**Format 2** (Alternative - bracketed):
```
ClassName::SubClass#test_method [PASS]
ClassName::SubClass#test_method [FAIL]
ClassName::SubClass#test_method [ERROR]
```

**Format 3** (Verbose):
```
test_method_name (ClassName::SubClass) = 0.01 s = .
```

**Dataset Field**:
```json
{
  "test_output_parser": "parsers/ruby_minitest_parser.py",
  "test_command": "bundle exec rake test"
}
```

---

## Creating New Datasets

### Step 1: Determine Test Framework

Identify the test framework used by the repository:
- Python: Check for `pytest`, `unittest`, or `nose`
- PHP: Check for `PHPUnit`
- Ruby: Check for `Minitest` or `RSpec`
- Other languages: May need new parser implementation

### Step 2: Run Tests Locally

Run the test command and capture the output format:
```bash
# Python pytest
pytest -v

# Python unittest
python -m unittest -v

# PHP PHPUnit
phpunit --testdox

# Ruby Minitest
bundle exec rake test
```

### Step 3: Extract Test Names

Extract the exact test names from the output, following the format rules above.

**CRITICAL**: The test names in `FAIL_TO_PASS` and `PASS_TO_PASS` must **EXACTLY MATCH** the format that the parser expects!

### Step 4: Format Dataset

Create the JSONL dataset with the correct parser reference:

```json
{
  "instance_id": "unique_id",
  "repo": "owner/repo",
  "base_commit": "commit_hash",
  "language": "Ruby",
  "test_command": "bundle exec rake test",
  "test_output_parser": "parsers/ruby_minitest_parser.py",
  "FAIL_TO_PASS": "[\"Test1#test_method1\", \"Test2#test_method2\"]",
  "PASS_TO_PASS": "[\"Test3#test_method3\", \"Test4#test_method4\"]",
  "image_storage_uri": "s3://bucket/path/to/image.tar"
}
```

### Step 5: Validate Format

Before running evaluation, verify:
1. Test names match parser format exactly
2. JSON escaping is correct (e.g., `\\` for PHP namespaces)
3. Parser exists in PARSER_REGISTRY
4. Test command produces output that parser can handle

---

## Adding New Parsers

To add support for a new test framework:

1. **Implement Parser Function** in [eval_standardized_swe.py](../../../evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/eval_standardized_swe.py):
   ```python
   def parse_log_my_framework(log: str, grading_spec: Any = None) -> Dict[str, str]:
       """Parser for MyFramework test output."""
       test_status_map = {}
       # Parse log and populate test_status_map
       # Keys: test names, Values: TestStatus enum
       return test_status_map
   ```

2. **Register in PARSER_REGISTRY**:
   ```python
   PARSER_REGISTRY: Dict[str, Callable] = {
       # ... existing parsers ...
       "language/parse_log_my_framework": parse_log_my_framework,
   }
   ```

3. **Document Format** in this file

4. **Test with Sample Output** before running full evaluation

---

## Troubleshooting

### Issue: Tests not being parsed correctly

**Symptom**: Evaluation shows 0 tests passed/failed, or wrong test counts

**Solutions**:
1. Check that test names in dataset exactly match parser format
2. Verify test_output_parser field matches a key in PARSER_REGISTRY
3. Run test command manually and compare output format with parser expectations
4. Check for special characters or encoding issues in test names

### Issue: Parser not found

**Symptom**: Error like "Unknown parser 'xyz', using parse_log_pytest_v3"

**Solutions**:
1. Verify test_output_parser value is a valid key in PARSER_REGISTRY
2. Check for typos in parser name
3. Ensure parser function is registered in PARSER_REGISTRY

### Issue: Some tests are missing from results

**Symptom**: Only partial test results, some tests not in output

**Solutions**:
1. Check if test output format is consistent (some tests may use different format)
2. Verify parser regex patterns match all test name variations
3. Check for log truncation (test output may be too long)
4. Ensure parser handles multi-line output correctly

---

## Example: Shopify/liquid Dataset (Ruby Minitest)

**Dataset Reference**: [VeloraHarness/data/Shopify/1769848885641113.jsonl](../../../data/Shopify/1769848885641113.jsonl)

**Test Framework**: Ruby Minitest

**Parser**: `parsers/ruby_minitest_parser.py` → `parse_log_ruby_minitest`

**Test Command**: `bundle exec rake test`

**Test Name Format**: `ClassName::SubClass#test_method`

**Example Tests**:
- FAIL_TO_PASS: `SnippetTest::LaxMode#test_valid_inline_snippet`
- PASS_TO_PASS: `AssignTest#test_assign_score_exceeding_limit_from_composite_object`

**Test Output Example**:
```
SnippetTest::LaxMode#test_valid_inline_snippet = 0.05 s = .
SnippetTest::RigidMode#test_render_inline_snippet = 0.03 s = F
AssignTest#test_assign_score_exceeding_limit_from_composite_object = 0.01 s = .
```

This format is parsed correctly by the `parse_log_ruby_minitest` function.

---

## Quick Reference Table

| Language | Framework | Parser Key | Test Name Format | Example |
|----------|-----------|------------|------------------|---------|
| Python | pytest | `python/parse_log_pytest_v3` | `path/to/file.py::Class::test_name` | `tests/test_auth.py::TestAuth::test_login` |
| Python | unittest | `python/parse_log_unittest` | `test_name (module.Class)` | `test_login (tests.test_auth.TestAuth)` |
| PHP | PHPUnit | `php/parse_log_phpunit` | `Namespace\\Class::testName` | `App\\Tests\\AuthTest::testLogin` |
| Ruby | Minitest | `parsers/ruby_minitest_parser.py` | `Class::SubClass#test_name` | `SnippetTest::LaxMode#test_valid_inline_snippet` |

---

**Last Updated**: 2026-02-03
**Related Files**:
- [eval_standardized_swe.py](../../../evaluation/benchmarks/multi_swe_bench/scripts/swe-hard/eval_standardized_swe.py)
- [Example dataset](../../../data/Shopify/1769848885641113.jsonl)
