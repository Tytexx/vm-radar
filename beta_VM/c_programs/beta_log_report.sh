bash#!/bin/bash

# find where script is located
SCRIPT_DIR="$(dirname "$0")"

# define the paths
LOG_DIR="$HOME/beta_VM/logs"
BINARY="$SCRIPT_DIR/log_report"
SOURCE="$SCRIPT_DIR/log_report.c"
SUMMARY_LOG="$LOG_DIR/log_summary.log"

# Compile program if binary is missing OR source is newer than binary
if [ ! -f "$BINARY" ] || [ "$SOURCE" -nt "$BINARY" ]; then
    echo "Binary missing or source updated — compiling..."

    # Run makefile in script directory
    make -C "$SCRIPT_DIR" build

    # Check if compilation failed
    if [ $? -ne 0 ]; then
        echo "ERROR: Compilation failed — cannot run report"
        exit 1
    fi

    echo "Compilation successful"
fi
# Find all .log files except the summary log
LOG_FILES=$(find "$LOG_DIR" -name "*.log" -type f \
            ! -name "log_summary.log" \
            | sort)
# Exit if no log files are found
if [ -z "$LOG_FILES" ]; then
    echo "No .log files found in $LOG_DIR"
    exit 0
fi

# Display found log files
echo "Found log files:"
echo "$LOG_FILES" | while read f; do echo "  $f"; done

# Convert newline-separated list into space-separated arguments
LOG_FILES_ARGS=$(echo "$LOG_FILES" | tr '\n' ' ')

echo ""
echo "Running log_report..."
echo ""

# Run the C program with log files as arguments
REPORT_OUTPUT=$("$BINARY" $LOG_FILES_ARGS)
# Check if execution succesful
if [ $? -ne 0 ]; then
    echo "ERROR: log_report exited with an error"
    exit 1
fi
# Print report to terminal
echo "$REPORT_OUTPUT"
# Get current timestamp
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Append report with timestamp to summary log
{
    echo ""
    echo "========================================"
    echo "Report generated: $TIMESTAMP"
    echo "========================================"
    echo "$REPORT_OUTPUT"
} >> "$SUMMARY_LOG"

echo ""
echo "Report appended to $SUMMARY_LOG"