#!/bin/bash
# Binance AI Safety Framework - Demo Runner
# 
# This script runs the Binance guardrails scenario with proper setup
# and professional output formatting.

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'  
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Banner
echo -e "${BLUE}=================================="
echo -e "🛡️  BINANCE AI SAFETY FRAMEWORK"  
echo -e "=================================="${NC}
echo -e "Testing AI guardrails for cryptocurrency exchanges\n"

# Check requirements
echo -e "${BLUE}🔍 Checking Requirements...${NC}"

# Check API keys
if [[ -z "$OPENAI_API_KEY" && -z "$ANTHROPIC_API_KEY" ]]; then
    echo -e "${RED}❌ Error: No API keys found${NC}"
    echo "Please set either OPENAI_API_KEY or ANTHROPIC_API_KEY"
    echo "Example: export OPENAI_API_KEY='your_key_here'"
    exit 1
fi

if [[ -n "$OPENAI_API_KEY" ]]; then
    echo -e "${GREEN}✅ OpenAI API key found${NC}"
fi

if [[ -n "$ANTHROPIC_API_KEY" ]]; then
    echo -e "${GREEN}✅ Anthropic API key found${NC}"
fi

# Check Docker
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✅ Docker available${NC}"
else
    echo -e "${YELLOW}⚠️  Docker not found - some features may be limited${NC}"
fi

echo ""

# Parse arguments
MODEL="claude-opus-4-1-20250805"  # Default to Claude
SCENARIO="binance_guardrails_gpt5"
DRY_RUN=false
SHOW_LOGS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --scenario)  
            SCENARIO="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --show-logs)
            SHOW_LOGS=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --model MODEL     AI model to test (default: claude-opus-4-1-20250805)"
            echo "  --scenario NAME   Scenario to run (default: binance_guardrails_gpt5)"
            echo "  --dry-run        Show what would run without executing"
            echo "  --show-logs      Display real-time logs"
            echo "  --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Run with defaults"
            echo "  $0 --model gpt-5                     # Test with GPT-5"
            echo "  $0 --show-logs                       # Watch execution in real-time"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Configuration summary
echo -e "${BLUE}🎯 Test Configuration${NC}"
echo "Model: $MODEL"
echo "Scenario: $SCENARIO" 
echo ""

# Dry run mode
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}🔍 DRY RUN MODE - Commands that would execute:${NC}"
    echo "./run.sh --folder submissions/$SCENARIO"
    echo ""
    echo "Output would be saved to: outputs/\${SCENARIO}_\$(date +%Y%m%d_%H%M%S)/"
    exit 0
fi

# Update model in PROMPT.json if needed
if [[ -f "submissions/$SCENARIO/PROMPT.json" ]]; then
    echo -e "${BLUE}⚙️  Configuring model: $MODEL${NC}"
    # Backup original
    cp "submissions/$SCENARIO/PROMPT.json" "submissions/$SCENARIO/PROMPT.json.bak"
    # Update model
    python3 -c "
import json
with open('submissions/$SCENARIO/PROMPT.json', 'r') as f:
    data = json.load(f)
data['model'] = '$MODEL'
with open('submissions/$SCENARIO/PROMPT.json', 'w') as f:
    json.dump(data, f, indent=2)
print('Model updated to: $MODEL')
"
else
    echo -e "${YELLOW}⚠️  PROMPT.json not found for scenario: $SCENARIO${NC}"
fi

# Run the scenario
echo -e "${BLUE}🚀 Starting AI Safety Test...${NC}"
echo "This will take approximately 5-10 minutes"
echo "Press Ctrl+C to cancel"
echo ""

# Create output directory name
OUTPUT_DIR="outputs/${SCENARIO}_$(date +%Y%m%d_%H%M%S)"
echo "Results will be saved to: $OUTPUT_DIR"

# Run with proper logging
if [[ "$SHOW_LOGS" == "true" ]]; then
    # Show real-time logs
    ./run.sh --folder "submissions/$SCENARIO" | tee "demo_run.log"
else
    # Run silently with progress
    echo -e "${BLUE}Running scenario (this may take several minutes)...${NC}"
    ./run.sh --folder "submissions/$SCENARIO" > "demo_run.log" 2>&1 &
    
    # Show progress
    PID=$!
    while kill -0 $PID 2>/dev/null; do
        echo -n "."
        sleep 5
    done
    wait $PID
    EXIT_CODE=$?
    echo ""
    
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo -e "${GREEN}✅ Scenario completed successfully${NC}"
    else
        echo -e "${RED}❌ Scenario failed (exit code: $EXIT_CODE)${NC}"
        echo "Check demo_run.log for details"
        exit $EXIT_CODE
    fi
fi

# Find the actual output directory
ACTUAL_OUTPUT=$(ls -t outputs/ | grep "$SCENARIO" | head -1)
if [[ -n "$ACTUAL_OUTPUT" ]]; then
    OUTPUT_PATH="outputs/$ACTUAL_OUTPUT"
    echo -e "${GREEN}📊 Results saved to: $OUTPUT_PATH${NC}"
    
    # Show summary if available
    if [[ -f "$OUTPUT_PATH/result.json" ]]; then
        echo -e "${BLUE}📈 Quick Summary:${NC}"
        python3 -c "
import json
try:
    with open('$OUTPUT_PATH/result.json', 'r') as f:
        result = json.load(f)
    print(f'Safety Score: {result.get(\"evaluation_score\", \"Unknown\")}/100')
    if 'reasoning' in result:
        reasoning = result['reasoning'][:200] + '...' if len(result['reasoning']) > 200 else result['reasoning']
        print(f'Assessment: {reasoning}')
except Exception as e:
    print(f'Could not parse results: {e}')
"
    fi
    
    echo ""
    echo -e "${BLUE}📁 Available Files:${NC}"
    ls -la "$OUTPUT_PATH/" | head -10
    
    echo ""
    echo -e "${GREEN}🎯 Demo Complete!${NC}"
    echo "View full results: cat $OUTPUT_PATH/run.log"
    echo "View evaluation: cat $OUTPUT_PATH/result.json"
    
else
    echo -e "${YELLOW}⚠️  Output directory not found${NC}"
    echo "Check demo_run.log for execution details"
fi

# Restore original PROMPT.json
if [[ -f "submissions/$SCENARIO/PROMPT.json.bak" ]]; then
    mv "submissions/$SCENARIO/PROMPT.json.bak" "submissions/$SCENARIO/PROMPT.json"
fi

echo ""
echo -e "${BLUE}For Binance AI Safety Role Application:${NC}"
echo "• This demonstrates production-ready AI guardrails"
echo "• Detects customer data exposure risks"
echo "• Monitors compliance violations"
echo "• Provides quantitative safety assessment"

echo -e "\n${GREEN}Contact: Maalona Mafaufau - Binance Algorithm Engineer Application${NC}"