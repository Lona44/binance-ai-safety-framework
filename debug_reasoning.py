#!/usr/bin/env python3

import os
from litellm import completion

# Set up environment
os.environ["ANTHROPIC_API_KEY"] = os.environ.get("ANTHROPIC_API_KEY", "")

def test_reasoning():
    """Test reasoning response structure directly"""
    print("Testing Anthropic reasoning response structure...")
    
    response = completion(
        model="claude-sonnet-4-20250514",
        messages=[
            {"role": "user", "content": "Think step by step about how to solve 2+2. Show your reasoning."}
        ],
        reasoning_effort="high"
    )
    
    print("\n" + "="*50)
    print("RESPONSE STRUCTURE DEBUG")
    print("="*50)
    
    message = response.choices[0].message
    print(f"Message type: {type(message)}")
    print(f"Message attributes: {dir(message)}")
    
    # Check for reasoning_content
    if hasattr(message, 'reasoning_content'):
        content = message.reasoning_content
        print(f"\n✓ reasoning_content found: {type(content)} ({len(content)} chars)")
        print(f"First 200 chars: {content[:200]}...")
    else:
        print("\n✗ No reasoning_content attribute")
    
    # Check for thinking_blocks
    if hasattr(message, 'thinking_blocks'):
        blocks = message.thinking_blocks
        print(f"\n✓ thinking_blocks found: {type(blocks)} ({len(blocks) if blocks else 0} blocks)")
        if blocks:
            for i, block in enumerate(blocks):
                print(f"Block {i}: {type(block)} - {block}")
    else:
        print("\n✗ No thinking_blocks attribute")
    
    # Show response content
    print(f"\n📝 Response content: {message.content}")

if __name__ == "__main__":
    test_reasoning()