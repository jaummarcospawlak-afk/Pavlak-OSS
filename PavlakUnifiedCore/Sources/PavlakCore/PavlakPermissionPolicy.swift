import Foundation

public enum PavlakPermissionPolicy {
    public static func authorize(tool: String) throws {
        let allowed = Set(PavlakToolName.allCases.map(\.rawValue))
        if allowed.contains(tool) { return }

        let blockedPrefixes = [
            "file_delete", "file_move", "message_send", "email_send",
            "purchase", "payment", "system_setting"
        ]
        if blockedPrefixes.contains(where: { tool.hasPrefix($0) }) {
            throw PavlakError.permissionDenied(
                "\(tool) exige aprovação humana explícita e ainda não está habilitada."
            )
        }
        throw PavlakError.unknownTool(tool)
    }
}
