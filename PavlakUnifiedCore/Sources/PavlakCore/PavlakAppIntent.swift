#if os(macOS) && canImport(AppIntents)
import AppIntents

@available(macOS 13.0, *)
public struct RunPavlakIntent: AppIntent {
    public static let title: LocalizedStringResource = "Executar no Pavlak"
    public static let description = IntentDescription("Envia uma solicitação ao Pavlak.")

    @Parameter(title: "Solicitação")
    public var command: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Executar \(\.$command) no Pavlak")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = await PavlakAgentEngine.shared.run(command)
        return .result(value: result)
    }
}
#endif
