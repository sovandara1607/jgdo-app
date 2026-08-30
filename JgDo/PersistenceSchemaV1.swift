import SwiftData

/// The schema shape as it has always shipped, now given an explicit version
/// identity so future field changes go through a real `SchemaMigrationPlan`
/// stage instead of an ad hoc edit to the `@Model` types.
///
/// `ClipboardItem.contentHash` and `Workspace.restoreOnLaunch` were added
/// after this file was first written, but deliberately WITHOUT bumping to a
/// nested `SchemaV2` type: both are optional/defaulted, purely additive
/// fields, which SwiftData's automatic lightweight migration infers on its
/// own — no custom `MigrationStage` needed, and `Persistence`'s backup/
/// non-destructive-fallback (see `PersistenceBackup`) is still the safety
/// net if inference ever fails for some other reason. A real `SchemaV2`
/// (nested types, an explicit `MigrationStage`) becomes necessary the
/// moment a change ISN'T purely additive — a rename, a type change, a
/// removed field, or a new non-optional field with no default.
///
/// `AppCombinationObservation`/`SmartLayoutSuggestion`/`SmartLayoutSlot`
/// (Smart Layouts) are, by the same reasoning, also additive: they're
/// brand-new model types with no prior rows to migrate, not a shape change
/// to anything that already has data — SwiftData creates their tables the
/// first time the augmented schema opens, same as any other new type added
/// to this list. `WindowPairScore` (dual-snap partner memory) is the same
/// story again.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [ClipboardItem.self, Workspace.self, WorkspaceWindow.self, AppUsageEvent.self,
         LayoutPreset.self, LayoutSlot.self, ParkedWindow.self,
         SnapGroup.self, SnapGroupMember.self,
         AppCombinationObservation.self, SmartLayoutSuggestion.self, SmartLayoutSlot.self,
         WindowPairScore.self]
    }
}

/// The app's full migration history. Empty `stages` today (SchemaV1 is the
/// only version), but the scaffold matters: once a second version lands
/// (e.g. `ClipboardItem.contentHash` in a later pass), it gets a real
/// `MigrationStage` here instead of `Persistence` falling back to its old
/// "delete the store and start over" behavior on a shape mismatch.
enum JgDoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
