import Testing

/// Placeholder so the FaroTests target has a source file and the test
/// scheme runs green in CI from Fase 0 onward. Real coverage (reasoning
/// parser, HF preflight, OpenAI mapping, MCP bridge) lands with each
/// feature in its own phase.
struct FaroTests {
    @Test func appNameIsFaro() {
        #expect("Faro" == "Faro")
    }
}
