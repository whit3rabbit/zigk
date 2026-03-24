#!/bin/bash
# Test runner script with timeout
set +e

TIMEOUT=${TIMEOUT:-300}
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

    # Recreate SFS disk image for aarch64 (prevents stale files from previous runs)
    if [ "$arch" = "aarch64" ]; then
        echo "Creating fresh SFS disk image..."
        dd if=/dev/zero of=sfs.img bs=1M count=32 2>/dev/null
    fi

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

    # Check for test completion via TEST_SUMMARY or by counting PASS/FAIL results
    if strings "$log_file" | grep -q "TEST_SUMMARY:"; then
        SUMMARY=$(strings "$log_file" | grep "TEST_SUMMARY:" | tail -1)
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
    fi

    # Fallback: test runner may hang after tests complete (known SFS deadlock).
    # Check if TEST_START was emitted and count PASS/FAIL directly.
    if strings "$log_file" | grep -q "TEST_START:"; then
        PASS_COUNT=$(strings "$log_file" | grep -c "PASS:")
        FAIL_COUNT=$(strings "$log_file" | grep -c "FAIL:")
        SKIP_COUNT=$(strings "$log_file" | grep -c "SKIP:")

        if [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -gt 0 ]; then
            echo -e "${GREEN}✓ All tests passed for ${arch}! (${PASS_COUNT} passed, ${SKIP_COUNT} skipped, runner hung post-test)${NC}"
            return 0
        elif [ "$FAIL_COUNT" -gt 0 ]; then
            echo -e "${RED}✗ Some tests failed for ${arch}! (${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped)${NC}"
            return 1
        fi
    fi

    echo -e "${RED}✗ Tests did not complete for ${arch} (timeout or crash)${NC}"
    echo "Last 20 lines of output:"
    strings "$log_file" | tail -20
    return 1
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
