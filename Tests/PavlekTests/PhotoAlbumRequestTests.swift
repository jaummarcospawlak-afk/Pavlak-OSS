#if os(macOS)
import XCTest
@testable import Pavlek

final class PhotoAlbumRequestTests: XCTestCase {
    func testObservedTravelRequestDropsConnectingPreposition() {
        let name = PhotoAlbumRequest.name(from: "pavlak, localize meu album de viajens ")
        XCTAssertEqual(name, "viajens")
        XCTAssertTrue(PhotoAlbumRequest.isTrips(name))
    }

    func testEquivalentTravelRequestsIdentifyTheSameCollection() {
        for command in ["Localize meu álbum de viagens", "Procure no álbum Viagens",
                        "Busque o álbum chamado VIAGENS.", "pavlak localize meu albuns de viajens"] {
            XCTAssertTrue(PhotoAlbumRequest.isTrips(PhotoAlbumRequest.name(from: command)))
        }
    }

    func testQuotedAlbumNamesRemainLiteral() {
        XCTAssertEqual(PhotoAlbumRequest.name(from: "Localize o álbum chamado “De Janeiro a Março”"),
                       "De Janeiro a Março")
        XCTAssertEqual(PhotoAlbumRequest.name(from: "Procure no álbum Documentos"), "Documentos")
    }

    func testUnavailableTripExplainsCurrentIntegrationLimit() {
        let message = PhotoAlbumRequest.unavailableMessage(for: "viajens")
        XCTAssertTrue(message.contains("Fotos › Coleções › Viagens"))
        XCTAssertTrue(message.contains("ainda não é consultada"))
        XCTAssertFalse(PhotoAlbumRequest.isTrips("Viagens de trabalho"))
    }
}
#endif
