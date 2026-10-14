# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: modern-context.swift.ts >> input caret follows peer prefixes and author deactivation after cached native reads
- Location: tests/modern-context.swift.ts:51:0

# Error details

```
Error: evaluate: TypeError: peer.undo is not a function
    at eval (eval at evaluate (:311:30), <anonymous>:3:10)
    at UtilityScript.evaluate (<anonymous>:313:16)
    at UtilityScript.<anonymous> (<anonymous>:1:44)
```