import Testing
@testable import PavlakCore

@Test func parsesVisibleSafariSearch() {
    let plan = PavlakLocalIntentParser().plan(for: "Pavlak, pesquise OpenAI Responses API no Safari")
    #expect(plan == [.browserSearch(query: "OpenAI Responses API")])
}

@Test func parsesKnownApplicationOpen() {
    let plan = PavlakLocalIntentParser().plan(for: "abra o aplicativo Pages")
    #expect(plan == [.appOpen(name: "Pages")])
}

@Test func parsesFocusedFileSearch() {
    let plan = PavlakLocalIntentParser().plan(for: "localize meu contrato de locação no Finder")
    #expect(plan == [.fileFind(query: "contrato de locação", maxResults: 15)])
}

@Test func doesNotMisroutePhotoLibraryToFinder() {
    let plan = PavlakLocalIntentParser().plan(for: "localize minha identidade em minha galeria")
    #expect(plan == nil)
}

@Test func parsesURL() {
    let plan = PavlakLocalIntentParser().plan(for: "abra https://openai.com")
    #expect(plan == [.browserOpen(url: "https://openai.com")])
}
