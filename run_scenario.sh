#!/bin/bash

# Main script to run any scenario
# Usage: ./run_scenario.sh [scenario_name] [model]

set -euo pipefail

# Compose wrapper to support both v1 (docker-compose) and v2 (docker compose)
compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    docker compose "$@"
  fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
SCENARIO=${1:-inner_deception}
MODEL=${2:-gpt-5}

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Available scenarios
echo -e "${GREEN}Available Scenarios:${NC}"
echo "  1. inner_deception     - Calibration sandbagging test"
echo "  2. corporate_security_gpt5  - Corporate security scenario (GPT-5)"
echo "  3. corporate_security_o3    - Corporate security scenario (O3)"
echo "  4. exam_grading        - Exam grading misalignment"
echo "  5. clinical_trials     - Clinical trials misalignment"
echo ""

# Check if scenario exists
if [ ! -d "submissions/$SCENARIO" ]; then
    echo -e "${RED}Error: Scenario '$SCENARIO' not found in submissions/${NC}"
    echo "Please choose from the available scenarios above."
    exit 1
fi

echo -e "${YELLOW}Running scenario: $SCENARIO with model: $MODEL${NC}"

# Create output directory
OUTPUT_DIR="outputs/${SCENARIO}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

# Copy submission files to the template submission folder
echo "Setting up submission files..."
rm -rf submission/*
cp -r submissions/$SCENARIO/* submission/

# Ensure required files exist
if [ ! -f submission/PROMPT.json ]; then
    echo -e "${RED}Error: PROMPT.json not found in submission${NC}"
    exit 1
fi

if [ ! -f submission/DESCRIPTION.md ]; then
    echo -e "${RED}Error: DESCRIPTION.md not found in submission${NC}"
    exit 1
fi

# Update docker-compose with the selected model
export MODEL_NAME=$MODEL
export OUTPUT_PATH=$OUTPUT_DIR

# Run the experiment
echo -e "${GREEN}Starting Docker containers...${NC}"
# Ensure we always bring containers down, even on error/interrupt
cleanup() {
  echo "Cleaning up Docker containers and volumes..."
  compose down -v || true
}
trap cleanup EXIT

# Abort when the agent exits; this stops the submission container too
compose up --build --abort-on-container-exit 2>&1 | tee "$OUTPUT_DIR/run.log"

# Attempt to copy result artifacts before teardown
echo "Attempting to copy result artifacts from containers..."
if docker cp agent_controller:/app/result.json "$OUTPUT_DIR/result.json" 2>/dev/null; then
  echo "Copied agent result.json"
else
  echo "No agent result.json found"
fi
if docker cp submission_server:/output/result.txt "$OUTPUT_DIR/scorer_result.txt" 2>/dev/null; then
  echo "Copied scorer_result.txt"
else
  echo "No scorer_result.txt found"
fi

# Optionally post to Slack if webhook is configured
if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  echo "Posting summary + assessment answers to Slack (rich blocks)..."
  python3 scripts/slack_post.py "$OUTPUT_DIR" --webhook "$SLACK_WEBHOOK_URL" || echo "Slack post failed"
fi

# Check if the run completed successfully
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Scenario completed successfully${NC}"
    echo "Results saved to: $OUTPUT_DIR"
    
    # Check for result files
    if [ -f "$OUTPUT_DIR/result.json" ]; then
        echo ""
        echo "Result summary:"
        cat "$OUTPUT_DIR/result.json" | python3 -m json.tool | head -20
    fi
else
    echo -e "${RED}✗ Scenario failed${NC}"
    echo "Check logs at: $OUTPUT_DIR/run.log"
fi

# Cleanup Docker containers
echo "Cleaning up Docker containers and volumes..."
compose down -v

echo -e "${GREEN}Done!${NC}"
