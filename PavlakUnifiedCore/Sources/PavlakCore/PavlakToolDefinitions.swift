import Foundation

public enum PavlakToolDefinitions {
    public static var all: [[String: Any]] { [
        ["type": "web_search"],
        function(
            name: PavlakToolName.browserOpen.rawValue,
            description: "Abra uma URL visivelmente no Safari.",
            properties: [
                "url": ["type": "string", "description": "URL completa ou domínio."]
            ],
            required: ["url"]
        ),
        function(
            name: PavlakToolName.browserSearch.rawValue,
            description: "Faça uma pesquisa visível no Safari quando o usuário pedir para pesquisar no navegador.",
            properties: [
                "query": ["type": "string", "description": "Termos da pesquisa."]
            ],
            required: ["query"]
        ),
        function(
            name: PavlakToolName.appOpen.rawValue,
            description: "Abra um aplicativo instalado no macOS pelo nome.",
            properties: [
                "name": ["type": "string", "description": "Nome do aplicativo."]
            ],
            required: ["name"]
        ),
        function(
            name: PavlakToolName.fileFind.rawValue,
            description: "Localize arquivos pelo nome somente dentro da pasta autorizada.",
            properties: [
                "query": ["type": "string", "description": "Nome ou termos do arquivo."],
                "max_results": ["type": "integer", "minimum": 1, "maximum": 30]
            ],
            required: ["query", "max_results"]
        ),
        function(
            name: PavlakToolName.fileOpen.rawValue,
            description: "Abra um arquivo já localizado dentro da pasta autorizada.",
            properties: [
                "relative_path": ["type": "string", "description": "Caminho relativo à pasta autorizada."]
            ],
            required: ["relative_path"]
        ),
        function(
            name: PavlakToolName.systemNotify.rawValue,
            description: "Mostre uma notificação local no Mac.",
            properties: [
                "title": ["type": "string"],
                "body": ["type": "string"]
            ],
            required: ["title", "body"]
        ),
        function(
            name: PavlakToolName.inspectorRecentActions.rawValue,
            description: "Leia o histórico recente de ações do Pavlak.",
            properties: [
                "limit": ["type": "integer", "minimum": 1, "maximum": 100]
            ],
            required: ["limit"]
        )
    ] }

    private static func function(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ],
            "strict": true
        ]
    }
}
