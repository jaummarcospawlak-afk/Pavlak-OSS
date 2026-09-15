import Testing
@testable import PavlakCore

@Test func parsesFunctionCall() {
    let response: [String: Any] = [
        "output": [[
            "type": "function_call",
            "call_id": "call_1",
            "name": "browser_search",
            "arguments": #"{"query":"Pavlak"}"#
        ]]
    ]
    let calls = PavlakResponsesClient.functionCalls(from: response)
    #expect(calls.count == 1)
    #expect(calls.first?.name == "browser_search")
    #expect(calls.first?.arguments["query"] as? String == "Pavlak")
}

@Test func parsesOutputText() {
    let response: [String: Any] = [
        "output": [[
            "type": "message",
            "content": [["type": "output_text", "text": "Concluído."]]
        ]]
    ]
    #expect(PavlakResponsesClient.text(from: response) == "Concluído.")
}
