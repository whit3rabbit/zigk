#!/bin/bash
# Test runner script with timeout
set +e

TIMEOUT=30
ARCH=${ARCH:-x86_64}

echo "Running ZK kernel tests (arch=$ARCH, timeout=${TIMEOUT}s)..."

# Build test runner
zig build -Darch=$ARCH -Ddefault-boot=test_runner
if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Run with timeout
timeout ${TIMEOUT}s zig build run -Darch=$ARCH -Ddefault-boot=test_runner -Dqemu-args="-nographic" > test_output.log 2>&1

# Simple check: look for "TEST_EXIT:" followed eventually by "0"
CLEAN_OUTPUT=$(strings test_output.log | grep "TEST_EXIT\|^[0-9]")

if strings test_output.log | grep -q "TEST_SUMMARY:"; then
    # Check the line after TEST_EXIT contains "0"
    EXIT_CODE=$(strings test_output.log | grep -A 1 "TEST_EXIT:" | tail -1 | tr -d '\r\n ' | grep -o '[0-9]')
    
    if [ "$EXIT_CODE" = "0" ]; then
        echo "All tests passed!"
        exit 0
    else
        echo "Some tests failed! (exit code: $EXIT_CODE)"
        exit 1
    fi
else
    echo "Tests did not complete"
    exit 1
fi
