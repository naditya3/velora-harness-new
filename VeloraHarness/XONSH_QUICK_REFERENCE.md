# Xonsh Quick Reference for VeloraHarness

## Common Bash to Xonsh Conversions

### 1. Variables and Environment

```python
# Bash
VAR="value"
export ENV_VAR="value"
echo $VAR

# Xonsh
var = "value"
$ENV_VAR = "value"
print(var)
print($ENV_VAR)
```

### 2. Command Execution

```python
# Bash
ls -la
output=$(ls -la)

# Xonsh
ls -la
output = $(ls -la).strip()
```

### 3. Variable Interpolation in Commands

```python
# Bash
docker tag $IMAGE $TAG

# Xonsh
docker tag @(image) @(tag)
```

### 4. Conditionals

```python
# Bash
if [ -f "$FILE" ]; then
    echo "exists"
fi

if [ -z "$VAR" ]; then
    echo "empty"
fi

# Xonsh
from pathlib import Path
if Path(file).exists():
    print("exists")

if not var:
    print("empty")
```

### 5. Loops

```python
# Bash
for i in $(seq 1 10); do
    echo $i
done

for file in *.txt; do
    echo $file
done

# Xonsh
for i in range(1, 11):
    print(i)

for file in Path('.').glob('*.txt'):
    print(file)
```

### 6. String Operations

```python
# Bash
VAR="${STRING/old/new}"
VAR="${STRING:0:5}"
VAR=$(echo "$STRING" | sed 's/old/new/')

# Xonsh
var = string.replace('old', 'new')
var = string[:5]
var = string.replace('old', 'new')
```

### 7. File Operations

```python
# Bash
if [ -f "$FILE" ]; then
if [ -d "$DIR" ]; then
if [ -e "$PATH" ]; then
mkdir -p "$DIR"

# Xonsh
from pathlib import Path
if Path(file).is_file():
if Path(dir).is_dir():
if Path(path).exists():
Path(dir).mkdir(parents=True, exist_ok=True)
```

### 8. JSON Processing

```python
# Bash
VALUE=$(cat file.json | jq -r '.key')

# Xonsh
import json
with open('file.json', 'r') as f:
    data = json.load(f)
value = data['key']
```

### 9. Error Handling

```python
# Bash
set -e
if ! command; then
    exit 1
fi

# Xonsh
# Commands raise exceptions on error
try:
    command
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
```

### 10. Functions

```python
# Bash
function my_func() {
    local arg1=$1
    echo "Hello $arg1"
}
my_func "world"

# Xonsh
def my_func(arg1):
    print(f"Hello {arg1}")

my_func("world")
```

## VeloraHarness Specific Patterns

### Setting Up Environment

```python
#!/usr/bin/env xonsh

# Environment variables
$DOCKER_BUILDKIT = "0"
$EVAL_DOCKER_IMAGE_PREFIX = "mswebench"
$USE_INSTANCE_IMAGE = "true"
$LANGUAGE = "python"
$RUN_WITH_BROWSING = "false"
$USE_HINT_TEXT = "false"
```

### Parsing Arguments

```python
import sys

def parse_args():
    args = sys.argv[1:]
    if len(args) < 2:
        print("ERROR: Missing required arguments")
        sys.exit(1)
    
    model_config = args[0]
    dataset = args[1]
    eval_limit = args[2] if len(args) > 2 else "1"
    max_iter = args[3] if len(args) > 3 else "200"
    
    return model_config, dataset, eval_limit, max_iter

model_config, dataset, eval_limit, max_iter = parse_args()
```

### Running Poetry Commands

```python
# Bash
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config $MODEL_CONFIG

# Xonsh
poetry run python evaluation/benchmarks/multi_swe_bench/run_infer.py \
    --agent-cls CodeActAgent \
    --llm-config @(model_config)
```

### Docker Operations

```python
# Check if image exists
existing_images = $(docker images --format "{{.Repository}}:{{.Tag}}").strip().split('\n')
if image_uri in existing_images:
    print(f"Image exists: {image_uri}")

# Tag image
docker tag @(source_image) @(target_tag)

# Remove images
docker rmi @(image_name)
```

### File Path Operations

```python
from pathlib import Path

# Find files
output_files = list(Path("evaluation/evaluation_outputs/outputs").rglob("output.jsonl"))

# Check existence
if Path(dataset).exists():
    print("Dataset found")

# Get absolute path
dataset_abs = str(Path(dataset).absolute())

# Create directories
Path(output_dir).mkdir(parents=True, exist_ok=True)
```

### AWS S3 Operations

```python
# Download from S3
aws s3 cp @(s3_path) @(local_file)

if $LASTRET != 0:
    print("ERROR: S3 download failed")
    sys.exit(1)
```

### JSON Data Handling

```python
import json

# Read JSON
with open(dataset_abs, 'r') as f:
    data = json.load(f)

instance_id = data.get('instance_id', '')
repo = data.get('repo', '')

# Write JSON
with open(output_file, 'w') as f:
    json.dump(report, f, indent=4)
```

## Tips and Best Practices

### 1. Mix Python and Shell Commands
```python
# Use Python for logic, shell for commands
for task_id in task_ids:
    if Path(f"output_{task_id}.jsonl").exists():
        continue  # Python logic
    
    poetry run python run_infer.py --task @(task_id)  # Shell command
```

### 2. Capture Command Output
```python
# Simple capture
output = $(command).strip()

# Multi-line output
lines = $(command).strip().split('\n')

# With error handling
try:
    result = $(command).strip()
except Exception as e:
    print(f"Command failed: {e}")
```

### 3. Check Exit Codes
```python
command arg1 arg2

if $LASTRET != 0:
    print("Command failed")
    sys.exit(1)
```

### 4. Working with Paths
```python
from pathlib import Path

# Always use Path for file operations
dataset_path = Path(dataset)
if dataset_path.exists():
    abs_path = dataset_path.absolute()
    parent_dir = dataset_path.parent
    filename = dataset_path.name
```

### 5. Environment Variable Access
```python
# Set
$MY_VAR = "value"

# Get
value = $MY_VAR

# Check existence
if 'MY_VAR' in ${...}:
    print("Variable exists")

# Delete
if 'MY_VAR' in ${...}:
    del $MY_VAR
```

## Common Pitfalls

### 1. String vs Command
```python
# Wrong - tries to execute as command
output = docker images

# Correct - executes command
output = $(docker images).strip()
```

### 2. Variable Interpolation
```python
# Wrong - won't interpolate
docker tag $image $tag

# Correct - uses @ for interpolation
docker tag @(image) @(tag)
```

### 3. Path Separators
```python
# Wrong - hard-coded separator
path = dir + "/" + file

# Correct - use Path
path = Path(dir) / file
```

### 4. Exit Codes
```python
# Bash
if ! command; then
    exit 1
fi

# Xonsh - use $LASTRET
command
if $LASTRET != 0:
    sys.exit(1)
```

## Debugging

### Print Debug Information
```python
# Enable xonsh trace
$XONSH_TRACE_SUBPROC = True

# Print variables
print(f"DEBUG: var={var}, type={type(var)}")

# Print environment
print(${...})
```

### Check Command Execution
```python
# See what command will execute
print(f"Running: docker tag {image} {tag}")
docker tag @(image) @(tag)

# Check exit code
print(f"Exit code: {$LASTRET}")
```

## Resources

- **Xonsh Documentation:** https://xon.sh/
- **Xonsh Tutorial:** https://xon.sh/tutorial.html
- **Xonsh API:** https://xon.sh/api/index.html
- **Xonsh Examples:** https://github.com/xonsh/xonsh/tree/main/examples
