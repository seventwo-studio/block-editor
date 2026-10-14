import Foundation

/// Immutable, separately validated field chains. Cross-field routing cannot
/// use this index; it continues through the complete graph projection.
struct WritingSeedIndex {
    private final class Owner {}
    let owner: AnyObject = Owner()
    let seeds: [WritingField: [WritingAtomSeed]]
    let hidden: [WritingField: Set<WritingAtomKey>]
    let projections: [WritingField: WritingProjection]
    let rawFields: [WritingField: RawWritingField]
    let fields: Set<WritingField>

    init?(atoms: [WritingAtomSeed], hiddenKeys: Set<WritingAtomKey>, fields: Set<WritingField>, extending prior: WritingSeedIndex? = nil) {
        var seeds = prior?.seeds ?? [:], hidden = prior?.hidden ?? [:]
        var projections = prior?.projections ?? [:]
        var rawFields = prior?.rawFields ?? [:]
        var additions: [WritingField: [WritingAtomSeed]] = [:]
        for atom in atoms {
            // Generated field chains must be closed in both edge and route.
            if let anchor = atom.edge.anchor, anchor.origin != atom.key.origin { return nil }
            switch atom.route {
            case .field(let field): guard field == atom.key.origin else { return nil }
            case .follow(let key): guard key.origin == atom.key.origin else { return nil }
            }
            additions[atom.key.origin, default: []].append(atom)
        }
        for key in hiddenKeys { hidden[key.origin, default: []].insert(key) }
        for field in fields {
            if projections[field] != nil { guard additions[field] == nil else { return nil }; continue }
            let values = additions[field] ?? []
            guard let projection = try? WritingProjection(seeds: values, edits: [], emptyFields: [field], hiddenSeeds: hidden[field] ?? []) else { return nil }
            seeds[field] = values; projections[field] = projection; rawFields[field] = RawWritingField(field)
        }
        guard additions.keys.allSatisfy({ projections[$0] != nil }) else { return nil }
        self.seeds = seeds; self.hidden = hidden; self.projections = projections; self.rawFields = rawFields
        self.fields = Set(projections.keys)
    }
}

struct WritingSeedData {
    let atoms: [WritingAtomSeed]
    let hidden: Set<WritingAtomKey>
    let index: WritingSeedIndex?
    let keys: Set<WritingAtomKey>
    let valueOrigins: WritingValueOrigins?
}

/// Strong ownership of immutable births and their checked scalar seed index.
/// This is internal projection data, never command or packet authorization.
final class WritingValueOrigins {
    let births: [WritingField: WritingFieldBirth]
    let index: WritingSeedIndex
    init(births: [WritingField: WritingFieldBirth], index: WritingSeedIndex) {
        self.births = births; self.index = index
    }
}

struct WritingValueBasis {
    let fields: Set<WritingField>
    let remaining: Set<WritingField>
    let activeNodes: Set<NodeID>
    let activeFields: [NodeID: Set<WritingField>]
}

/// Each snapshot owns its small field dictionary and shares immutable baseline
/// fields. Edited fields are rebuilt with the original checked graph algorithm;
/// there is no parent-snapshot chain or unchecked mutable cache.
struct IndependentWritingFields {
    let seedOwner: AnyObject
    let projections: [WritingField: WritingProjection]
    let seeds: [WritingField: [WritingAtomSeed]]
    let changed: Set<WritingField>

    static func make(index: WritingSeedIndex, edits: [WritingEdit], active: [ChangeID: Bool], emptyFields: Set<WritingField>) throws -> Self? {
        guard emptyFields.isSubset(of: index.fields) else { return nil }
        // Ordinary String equality admits canonically equivalent spellings.
        // Keep such wire references on full replay so cached virtual heads
        // cannot choose a different spelling for a captured identity.
        func exactOrigin(_ field: WritingField) -> Bool { index.rawFields[field] == RawWritingField(field) }
        var perField: [WritingField: [WritingEdit]] = [:]
        for edit in edits.sorted(by: { $0.id < $1.id }) {
            var mutations: [WritingField: [WritingMutation]] = [:]
            for mutation in edit.mutations {
                switch mutation {
                case .insert(let atom):
                    guard index.projections[atom.key.origin] != nil, exactOrigin(atom.key.origin) else { return nil }
                    if let anchor = atom.edge.anchor, anchor.origin != atom.key.origin || !exactOrigin(anchor.origin) { return nil }
                    switch atom.route {
                    case .field(let field): guard field == atom.key.origin, exactOrigin(field) else { return nil }
                    case .follow(let key): guard key.origin == atom.key.origin, exactOrigin(key.origin) else { return nil }
                    }
                    mutations[atom.key.origin, default: []].append(mutation)
                case .delete(let keys):
                    guard keys.allSatisfy({ exactOrigin($0.origin) }) else { return nil }
                    for (field, members) in Dictionary(grouping: keys, by: \.origin) {
                        guard index.projections[field] != nil else { return nil }
                        mutations[field, default: []].append(.delete(keys: members))
                    }
                case .format(let keys, let type, let mark):
                    guard keys.allSatisfy({ exactOrigin($0.origin) }) else { return nil }
                    for (field, members) in Dictionary(grouping: keys, by: \.origin) {
                        guard index.projections[field] != nil else { return nil }
                        mutations[field, default: []].append(.format(keys: members, type: type, mark: mark))
                    }
                default: return nil
                }
            }
            for (field, values) in mutations { perField[field, default: []].append(WritingEdit(id: edit.id, mutations: values)) }
        }
        var projections = index.projections
        for (field, values) in perField {
            projections[field] = try WritingProjection(seeds: index.seeds[field] ?? [], edits: values, active: active,
                emptyFields: [field], hiddenSeeds: index.hidden[field] ?? [])
        }
        return Self(seedOwner: index.owner, projections: projections, seeds: index.seeds, changed: Set(perField.keys))
    }
}
