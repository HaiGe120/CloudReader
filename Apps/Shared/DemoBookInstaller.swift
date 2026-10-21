import Foundation
import CloudReaderCore

enum DemoBookInstaller {
    static let bookID = UUID(uuidString: "0E7B7B49-9652-4E82-BA2E-84F58CC90D46")!
    static func makeBook(fileName: String) -> Book {
        var book = Book(
            id: bookID,
            title: "The Open Shelf",
            author: "The CloudReader Project",
            briefDescription: briefDescription,
            fileName: fileName,
            format: .txt
        )
        let releaseDate = Date(timeIntervalSince1970: 1_767_225_600)
        book.addedAt = releaseDate
        book.modifiedAt = releaseDate
        return book
    }

    static let briefDescription = "An original field guide to CloudReader’s goals, reading experience, portable library, cloud sync, privacy, and reader-controlled AI."
}
