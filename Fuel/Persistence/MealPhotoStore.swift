import Foundation

protocol MealPhotoStore: Sendable {
    func save(_ data: Data, id: UUID) async throws -> String
    func load(fileName: String) async throws -> Data
    func delete(fileName: String) async throws
    func deleteAll() async throws
}

actor LocalMealPhotoStore: MealPhotoStore {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = applicationSupport.appending(path: "MealPhotos", directoryHint: .isDirectory)
        }
    }

    func save(_ data: Data, id: UUID) throws -> String {
        try prepareDirectory()
        let fileName = "\(id.uuidString).mealphoto"
        let destination = directory.appending(path: fileName)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return fileName
    }

    func load(fileName: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: fileName))
    }

    func delete(fileName: String) throws {
        let url = directory.appending(path: fileName)
        guard fileManager.fileExists(atPath: url.path()) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func prepareDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
