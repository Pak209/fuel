import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MealPhotoStoreError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "Fuel could not safely read that image. Choose another photo or log the meal without one."
    }
}

/// Cheap metadata validation shared by every image entry point. It deliberately
/// runs before UIKit or Vision decode so compressed pixel bombs and arbitrary
/// binary data never reach persistence or an expensive image decoder.
enum MealImageValidator {
    nonisolated static let maximumBytes = 8_000_000
    nonisolated static let maximumDimension = 20_000.0
    nonisolated static let maximumPixels = 60_000_000.0

    nonisolated static func isValid(_ data: Data, maximumBytes allowedBytes: Int = maximumBytes) -> Bool {
        guard !data.isEmpty, data.count <= allowedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              UTType(identifier as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) as? [CFString: Any],
              let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return dimensionsAreSafe(width: widthValue.doubleValue, height: heightValue.doubleValue)
    }

    nonisolated static func dimensionsAreSafe(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite
            && width > 0 && height > 0
            && width <= maximumDimension && height <= maximumDimension
            && width * height <= maximumPixels
    }
}

/// One photo currently held on disk, with the timestamp the retention sweep ages it against.
struct StoredMealPhoto: Hashable, Sendable {
    var fileName: String
    var modifiedAt: Date
}

protocol MealPhotoStore: Sendable {
    func save(_ data: Data, id: UUID) async throws -> String
    func load(fileName: String) async throws -> Data
    func delete(fileName: String) async throws
    func deleteAll() async throws
    func stageForDeletion(fileName: String) async throws
    func restoreStaged(fileName: String) async throws
    func deleteStaged(fileName: String) async throws
    /// Everything the store is holding. Used to find photos no record references any more.
    func storedPhotos() async throws -> [StoredMealPhoto]
    func stagedPhotos() async throws -> [StoredMealPhoto]
}

actor LocalMealPhotoStore: MealPhotoStore {
    private let directory: URL
    private let deletedDirectory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = applicationSupport.appending(path: "MealPhotos", directoryHint: .isDirectory)
        }
        deletedDirectory = self.directory.appending(path: ".Deleted", directoryHint: .isDirectory)
    }

    func save(_ data: Data, id: UUID) throws -> String {
        guard MealImageValidator.isValid(data) else { throw MealPhotoStoreError.invalidImage }
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

    func stageForDeletion(fileName: String) throws {
        let source = directory.appending(path: fileName)
        guard fileManager.fileExists(atPath: source.path()) else { return }
        try prepareDeletedDirectory()
        let destination = deletedDirectory.appending(path: fileName)
        if fileManager.fileExists(atPath: destination.path()) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
        try fileManager.setAttributes([.modificationDate: Date.now], ofItemAtPath: destination.path())
    }

    func restoreStaged(fileName: String) throws {
        let source = deletedDirectory.appending(path: fileName)
        guard fileManager.fileExists(atPath: source.path()) else { return }
        try prepareDirectory()
        let destination = directory.appending(path: fileName)
        if fileManager.fileExists(atPath: destination.path()) {
            try fileManager.removeItem(at: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    func deleteStaged(fileName: String) throws {
        let url = deletedDirectory.appending(path: fileName)
        guard fileManager.fileExists(atPath: url.path()) else { return }
        try fileManager.removeItem(at: url)
    }

    func storedPhotos() throws -> [StoredMealPhoto] {
        try storedPhotos(in: directory)
    }

    func stagedPhotos() throws -> [StoredMealPhoto] {
        try storedPhotos(in: deletedDirectory)
    }

    private func storedPhotos(in targetDirectory: URL) throws -> [StoredMealPhoto] {
        guard fileManager.fileExists(atPath: targetDirectory.path()) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: targetDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents.compactMap { url in
            guard url.pathExtension == "mealphoto" else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return StoredMealPhoto(fileName: url.lastPathComponent, modifiedAt: modified ?? .distantPast)
        }
    }

    private func prepareDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path()
        )
    }

    private func prepareDeletedDirectory() throws {
        try prepareDirectory()
        guard !fileManager.fileExists(atPath: deletedDirectory.path()) else { return }
        try fileManager.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: deletedDirectory.path()
        )
    }
}
