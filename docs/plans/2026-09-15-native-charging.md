# Native charging implementation plan

Goal: integrate the hardware-tested PowerUI limit path while preserving OS battery readings and legacy controls.

Design: runtime-check the private framework and all selectors. Offer only advertised native limits. Persist the original system limit before managing it; restore on disable/quit and recover after restart. A temporary 100% override restores the configured limit on cancel or disconnect. Do not expose sailing, heat inhibition, or discharge on the native backend.

1. Add failing native-limit lifecycle tests using an injected backend and isolated preferences.
2. Implement the runtime adapter and restoration controller; run tests and read-only hardware discovery.
3. Wire settings and menu commands into ChargeManager, prioritizing native support. Keep legacy behavior on other hardware.
4. Correct typed firmware writes and add encoding regression coverage.
5. Build with target-specific signing overrides, install, test charging and restoration, and ask for user UI confirmation.
6. Commit only task files, excluding local signing and unrelated files. Update PR with verified evidence and remaining private-API/hardware limitations.
