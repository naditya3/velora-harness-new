#!/usr/bin/env bash
# Monitor Gemini Trajectory Generation Progress

LOG_FILE="/home/ec2-user/VeloraTrajectories/outputs/gemini_run.log"
OUTPUT_DIR="evaluation/evaluation_outputs/outputs/data__gemini_trajectories_50.jsonl-train/CodeActAgent/gemini-2.0-flash-exp_maxiter_50_N_gemini_trajectories_50"

echo "========================================"
echo "Gemini Trajectory Generation Monitor"
echo "========================================"
echo ""

# Check if process is running
if pgrep -f "run_infer.py.*gemini_trajectories_50" > /dev/null; then
    echo "✓ Process is running"
    echo "  PID: $(pgrep -f 'run_infer.py.*gemini_trajectories_50')"
else
    echo "⚠ Process not found"
    echo "  Check if it completed or crashed"
fi

echo ""
echo "--- Progress ---"
if [ -f "$LOG_FILE" ]; then
    echo "Latest log entries:"
    tail -20 "$LOG_FILE" | grep -E "(INFO|Instances processed|Starting evaluation)" || echo "No recent progress updates"
fi

echo ""
echo "--- Output Files ---"
cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness || exit
if [ -d "$OUTPUT_DIR" ]; then
    echo "Output directory: $OUTPUT_DIR"
    if [ -f "$OUTPUT_DIR/output.jsonl" ]; then
        LINES=$(wc -l < "$OUTPUT_DIR/output.jsonl")
        echo "  Generated trajectories: $LINES / 50"
    else
        echo "  No trajectories generated yet"
    fi

    if [ -f "$OUTPUT_DIR/metadata.json" ]; then
        echo "  Metadata file: ✓"
    fi
else
    echo "  Output directory not created yet"
fi

echo ""
echo "--- Commands ---"
echo "  Follow logs: tail -f $LOG_FILE"
echo "  Check output: cd /home/ec2-user/VeloraTrajectories/jaeger/VeloraHarness && ls -lh $OUTPUT_DIR/"
echo "  Kill process: pkill -f 'run_infer.py.*gemini_trajectories_50'"
echo "========================================"
