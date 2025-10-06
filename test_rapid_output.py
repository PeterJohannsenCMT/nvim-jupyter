#!/usr/bin/env python3
"""
Test script to reproduce the "too many open files" issue.
This script prints output rapidly to stress-test the nvim-jupyter plugin.
"""
import time

# Test 1: Rapid print statements
print("=== Test 1: Rapid print statements ===")
for i in range(1000):
    print(f"Line {i}: Testing rapid output...")
    if i % 100 == 0:
        time.sleep(0.01)  # Small delay every 100 lines

print("\n=== Test 2: Large chunks of text ===")
for i in range(100):
    print("x" * 1000)  # 1KB per line
    if i % 20 == 0:
        time.sleep(0.01)

print("\n=== Test 3: Progress bar simulation (carriage returns) ===")
for i in range(100):
    print(f"\rProgress: {i}%", end="", flush=True)
    time.sleep(0.01)
print()  # Final newline

print("\n=== All tests completed successfully! ===")
