import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// On-device Spotlight indexing for logged meals.
///
/// Privacy posture: only a meal's name, type, and date are ever indexed. The
/// searchable attribute set is limited to `title` and `contentDescription`
/// with generic wording — nutrition amounts and photos are never included,
/// and `thumbnailData` is always left unset. Indexing/deindexing is
/// best-effort local convenience: failures are logged via `Observability`
/// and never thrown to callers, since Spotlight visibility is not part of
/// Fuel's data model and must never block a meal save/delete.
@MainActor
enum SpotlightIndexer {
    /// Shared domain identifier for every indexed meal, used to bulk-deindex
    /// everything in one call (e.g. when local data is wiped).
    static let mealsDomainIdentifier = "meals"

    /// Indexes (or re-indexes) a single meal. Safe to call again for the same
    /// meal — CoreSpotlight replaces the existing item for the identifier.
    static func index(meal: Meal) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = meal.name
        attributeSet.contentDescription = "\(meal.type.rawValue) logged on \(dateFormatter.string(from: meal.date))"

        let item = CSSearchableItem(
            uniqueIdentifier: meal.id.uuidString,
            domainIdentifier: mealsDomainIdentifier,
            attributeSet: attributeSet
        )

        // Submit synchronously in main-actor mutation order, but do not make the
        // editor wait for the system indexing service's completion callback.
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                Observability.log(error, category: .data, message: "Spotlight index(meal:) failed")
            }
        }
    }

    /// Removes a single meal from the index, e.g. after a meal is deleted.
    static func deindex(mealID: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [mealID.uuidString]) { error in
            if let error {
                Observability.log(error, category: .data, message: "Spotlight deindex(mealID:) failed")
            }
        }
    }

    /// Removes every indexed meal, e.g. when the user deletes all local data.
    static func deindexAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [mealsDomainIdentifier]) { error in
            if let error {
                Observability.log(error, category: .data, message: "Spotlight deindexAll() failed")
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
