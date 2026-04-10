bash#!/bin/bash

SCRIPT_DIR="$(dirname "$0")"

LOG_DIR="$HOME/beta_VM/logs"

BINARY="$SCRIPT_DIR/log_report"

SOURCE="$SCRIPT_DIR/log_report.c"

SUMMARY_LOG="$LOG_DIR/log_summary.log"

if [ ! -f "$BINARY" ] || [ "$SOURCE" -nt "$BINARY" ]; then
    echo "Binary missing or source updated — compiling..."

    make -C "$SCRIPT_DIR" build

    if [ $? -ne 0 ]; then
        echo "ERROR: Compilation failed — cannot run report"
        exit 1
    fi

    echo "Compilation successful"
fi

LOG_FILES=$(find "$LOG_DIR" -name "*.log" -type f \
            ! -name "log_summary.log" \
            | sort)

if [ -z "$LOG_FILES" ]; then
    echo "No .log files found in $LOG_DIR"
    exit 0
fi

echo "Found log files:"
echo "$LOG_FILES" | while read f; do echo "  $f"; done

LOG_FILES_ARGS=$(echo "$LOG_FILES" | tr '\n' ' ')

echo ""
echo "Running log_report..."
echo ""

REPORT_OUTPUT=$("$BINARY" $LOG_FILES_ARGS)

if [ $? -ne 0 ]; then
    echo "ERROR: log_report exited with an error"
    exit 1
fi

echo "$REPORT_OUTPUT"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
    echo ""
    echo "========================================"
    echo "Report generated: $TIMESTAMP"
    echo "========================================"
    echo "$REPORT_OUTPUT"
} >> "$SUMMARY_LOG"

echo ""
echo "Report appended to $SUMMARY_LOG"