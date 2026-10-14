import Foundation

/// The immutable modern baseline uses the same structural and scalar atom
/// projections as body writing. This is an internal seed, not protocol-7
/// transaction admission or an authoring/session API.
struct ModernProjectionSeed {
    let documentID: String
    let structure: StructuralState
    let births: [WritingField: WritingFieldBirth]
    let atoms: [WritingAtomSeed]
    let hidden: Set<WritingAtomKey>
    let atomIndex: WritingSeedIndex?
    var fields: Set<WritingField> { Set(births.keys) }
    var title: WritingField { WritingField(node: .document(documentID: documentID), name: "title") }

    /// Modern replay starts from these immutable births and only appends new
    /// field births. Never substitute current rendered values or author activity
    /// for baseline atoms: inactive edits and conversions still retain them.
    func retainedAtoms(_ retained: [WritingField: WritingFieldBirth]) -> WritingSeedData {
        let additional = retained.filter { births[$0.key] == nil }
        guard !additional.isEmpty else { return WritingSeedData(atoms: atoms, hidden: hidden, index: atomIndex) }
        let fresh = seedWritingAtoms(additional)
        let index = atomIndex.flatMap { WritingSeedIndex(atoms: fresh.atoms, hiddenKeys: fresh.hidden, fields: Set(additional.keys), extending: $0) }
        return WritingSeedData(atoms: atoms + fresh.atoms, hidden: hidden.union(fresh.hidden), index: index)
    }

    init(_ document: ModernDocument) {
        documentID = document.documentID
        structure = StructuralState.seed(document)
        births = retainedWritingFields(structure)
        let seeded = seedWritingAtoms(births)
        atoms = seeded.atoms; hidden = seeded.hidden
        atomIndex = WritingSeedIndex(atoms: seeded.atoms, hiddenKeys: seeded.hidden, fields: Set(births.keys))
    }

    /// Call only with the projection of admitted operations over this baseline.
    /// ModernDocument validation still checks the resulting schema and limits.
    func document(projecting projection: WritingProjection) throws -> ModernDocument {
        var output = structure
        let values = try projectedWritingValues(structure: &output, projection: projection,
            seeds: atoms, fields: fields, births: births, retainedOrigins: true)
        return try output.document(documentID: documentID, text: values)
    }

    func document() throws -> ModernDocument {
        try document(projecting: WritingProjection(seeds: atoms, edits: [], emptyFields: fields, hiddenSeeds: hidden, seedIndex: atomIndex))
    }
}
