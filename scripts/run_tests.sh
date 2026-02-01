#!/bin/bash
# Test runner script with timeout
set +e

TIMEOUT=60
ARCH=${ARCH:-x86_64}
RUN_BOTH=${RUN_BOTH:-false}

# Color output support
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

run_tests_for_arch() {
    local arch=$1
    local log_file="test_output_${arch}.log"

    echo -e "${BLUE}Running ZK kernel tests (arch=${arch}, timeout=${TIMEOUT}s)...${NC}"

    # Build test runner
    echo "Building test runner for ${arch}..."
    zig build -Darch=$arch -Ddefault-boot=test_runner 2>&1 | tee "build_${arch}.log"
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}Build failed for ${arch}!${NC}"
        return 1
    fi

    # Run with timeout
    echo "Running tests for ${arch}..."
    timeout ${TIMEOUT}s zig build run -Darch=$arch -Ddefault-boot=test_runner -Dqemu-args="-nographic" > "$log_file" 2>&1

    # Simple check: look for "TEST_EXIT:" followed eventually by "0"
    if strings "$log_file" | grep -q "TEST_SUMMARY:"; then
        # Extract test counts
        SUMMARY=$(strings "$log_file" | grep "TEST_SUMMARY:" | tail -1)

        # Check the line after TEST_EXIT contains "0"
        EXIT_CODE=$(strings "$log_file" | grep -A 1 "TEST_EXIT:" | tail -1 | tr -d '\r\n ' | grep -o '[0-9]')

        if [ "$EXIT_CODE" = "0" ]; then
            echo -e "${GREEN}✓ All tests passed for ${arch}!${NC}"
            echo "  $SUMMARY"
            return 0
        else
            echo -e "${RED}✗ Some tests failed for ${arch}! (exit code: $EXIT_CODE)${NC}"
            echo "  $SUMMARY"
            return 1
        fi
    else
        echo -e "${RED}✗ Tests did not complete for ${arch} (timeout or crash)${NC}"
        echo "Last 20 lines of output:"
        strings "$log_file" | tail -20
        return 1
    fi
}

# Main execution
if [ "$RUN_BOTH" = "true" ]; then
    echo -e "${YELLOW}Running tests for both architectures...${NC}"
    echo ""

    # Run x86_64 tests
    run_tests_for_arch "x86_64"
    X86_RESULT=$?

    echo ""

    # Run aarch64 tests
    run_tests_for_arch "aarch64"
    AARCH64_RESULT=$?

    echo ""
    echo "========================================="
    echo "Multi-Architecture Test Summary"
    echo "========================================="

    if [ $X86_RESULT -eq 0 ]; then
        echo -e "x86_64:  ${GREEN}✓ PASS${NC}"
    else
        echo -e "x86_64:  ${RED}✗ FAIL${NC}"
    fi

    if [ $AARCH64_RESULT -eq 0 ]; then
        echo -e "aarch64: ${GREEN}✓ PASS${NC}"
    else
        echo -e "aarch64: ${RED}✗ FAIL${NC}"
    fi

    echo "========================================="

    # Exit with failure if either failed
    if [ $X86_RESULT -ne 0 ] || [ $AARCH64_RESULT -ne 0 ]; then
        exit 1
    fi

    exit 0
else
    # Run tests for single architecture
    run_tests_for_arch "$ARCH"
    exit $?
fi
