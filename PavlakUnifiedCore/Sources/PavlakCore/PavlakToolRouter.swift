import Foundation

@MainActor
public final class PavlakToolRouter {
    private let ledger: PavlakActionLedger

    public init(ledger: PavlakActionLedger = .shared) {
        self.ledger = ledger
    }

    public func execute(action: PavlakAction) async -> String {
        do {
            try PavlakPermissionPolicy.authorize(tool: action.toolName.rawValue)
            let result = try await perform(action)
            await ledger.append(action: action, result: result, succeeded: true)
            return result
        } catch {
            let message = error.localizedDescription
            await ledger.append(action: action, result: message, succeeded: false)
            return "ERRO: \(message)"
        }
    }

    public func execute(name: String, arguments: [String: Any]) async -> String {
        do {
            let action = try action(name: name, arguments: arguments)
            return await execute(action: action)
        } catch {
            let message = error.localizedDescription
            await ledger.append(
                tool: name,
                arguments: arguments.mapValues { String(describing: $0) },
                result: message,
                succeeded: false
            )
            return "ERRO: \(message)"
        }
    }

    private func action(name: String, arguments: [String: Any]) throws -> PavlakAction {
        switch name {
        case PavlakToolName.browserOpen.rawValue:
            guard let url = arguments["url"] as? String else { throw PavlakError.invalidArguments("browser_open.url") }
            return .browserOpen(url: url)
        case PavlakToolName.browserSearch.rawValue:
            guard let query = arguments["query"] as? String else { throw PavlakError.invalidArguments("browser_search.query") }
            return .browserSearch(query: query)
        case PavlakToolName.appOpen.rawValue:
            guard let name = arguments["name"] as? String else { throw PavlakError.invalidArguments("app_open.name") }
            return .appOpen(name: name)
        case PavlakToolName.fileFind.rawValue:
            guard let query = arguments["query"] as? String else { throw PavlakError.invalidArguments("file_find.query") }
            let limit = (arguments["max_results"] as? NSNumber)?.intValue ?? 15
            return .fileFind(query: query, maxResults: limit)
        case PavlakToolName.fileOpen.rawValue:
            guard let path = arguments["relative_path"] as? String else { throw PavlakError.invalidArguments("file_open.relative_path") }
            return .fileOpen(relativePath: path)
        case PavlakToolName.systemNotify.rawValue:
            guard let title = arguments["title"] as? String,
                  let body = arguments["body"] as? String else { throw PavlakError.invalidArguments("system_notify.title/body") }
            return .systemNotify(title: title, body: body)
        case PavlakToolName.inspectorRecentActions.rawValue:
            let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 20
            return .inspectorRecentActions(limit: limit)
        default:
            throw PavlakError.unknownTool(name)
        }
    }

    private func perform(_ action: PavlakAction) async throws -> String {
        #if os(macOS)
        switch action {
        case .browserOpen(let url):
            return try await PavlakSafariTool.open(urlString: url)
        case .browserSearch(let query):
            return try await PavlakSafariTool.search(query: query)
        case .appOpen(let name):
            return try await PavlakMacTool.openApplication(named: name)
        case .fileFind(let query, let maxResults):
            return try PavlakFileTool.find(query: query, maxResults: maxResults)
        case .fileOpen(let relativePath):
            return try PavlakFileTool.open(relativePath: relativePath)
        case .systemNotify(let title, let body):
            return try await PavlakMacTool.notify(title: title, body: body)
        case .inspectorRecentActions(let limit):
            return await recentActions(limit: limit)
        }
        #else
        if case .inspectorRecentActions(let limit) = action {
            return await recentActions(limit: limit)
        }
        throw PavlakError.unsupportedPlatform("Esta ferramenta local exige o app Pavlak no macOS.")
        #endif
    }

    private func recentActions(limit: Int) async -> String {
        let records = await ledger.recent(limit: limit)
        guard !records.isEmpty else { return "Nenhuma ação registrada nesta sessão." }
        return records.map { record in
            let status = record.succeeded ? "OK" : "ERRO"
            return "[\(status)] \(record.tool) — \(record.result)"
        }.joined(separator: "\n")
    }
}
