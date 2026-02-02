# Repomate Rubrics - Test Log Parsing and Analysis

This repository contains tools and data for parsing test logs, analyzing test results, and managing test execution data from various testing frameworks.

## Overview

This project provides:
- **Comprehensive test log parsers** for multiple testing frameworks (Python, JavaScript, Go, C/C++, Rust, and more)
- **Test result analysis data** from large-scale experiments
- **Repository snapshot archives** for reproducibility

## Repository Structure

```
repomate_rubrics/
├── harness/
│   ├── log_parsers.py          # Core test log parsing library
│   └── test_spec.py            # Example test specification and usage
├── python-only-below-0_1-rank-by-fp.csv  # Test result analysis data
└── images/                      # Repository snapshot tar archives (182 files)
```

---

## 📄 File Descriptions

### 1. `harness/log_parsers.py`

A comprehensive Python module for parsing test logs from various testing frameworks and converting them to standardized formats.

This parser is designed to work similarly to the SWE-bench harness, providing consistent output formats across different testing frameworks.

### 2. `python-only-below-0_1-rank-by-fp.csv`

CSV file containing Python test instances with associated metadata. Each row represents a test instance with the following key fields:
- `image_storage_uri`: Reference to the Docker image tar file
- `image_init_commands`: Commands to initialize the Docker container
- `test_command`: Command to execute tests
- `test_output_parser`: Parser to use from `log_parsers.py`

### 3. `images/`

Directory containing Docker images stored as tar files. Each image is named according to the `image_storage_uri` field in the CSV file.

---

## How to Use

### Quick Start

1. **Load the Docker image**
   - Locate the tar file in the `images/` folder using the `image_storage_uri` from the CSV
   - Load the image into Docker:
     ```bash
     docker load < images/<image_name>.tar
     ```

2. **Initialize the Docker container**
   - Run the initialization commands specified in `image_init_commands` from the CSV
   ```bash
   docker run -it <image_name> <init_commands>
   ```

3. **Execute tests**
   - Run the test command specified in `test_command` from the CSV
   ```bash
   <test_command>
   ```

4. **Parse test output**
   - Use the parser specified in `test_output_parser` to parse results
   - Import and use the appropriate parser from `harness/log_parsers.py`

### Example Usage

Refer to `harness/test_spec.py` for a complete example implementation. You may need to adapt the logic to fit your specific use case.

---

## Requirements

- Docker
- Python 3.x
- Access to the test instance CSV file and image archives

## Contributing

Contributions are welcome! Please ensure your code follows the existing patterns and includes appropriate documentation.
