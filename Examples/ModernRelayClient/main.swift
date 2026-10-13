import BlockEditorApple
import BlockEditorCore
import Foundation

/// Process-restart reference for the same native host used by Apple surfaces.
/// The app owns each command, token, save location and synchronization request.
@main struct ModernRelayClientCommand {
    @MainActor static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 6, let endpoint = URL(string: arguments[1]) else {
                throw ModernSessionError.unavailable("usage: modern-relay-client FILE ENDPOINT RELAY_KEY DOCUMENT ACTOR ACTION [VALUES]")
            }
            let store = ModernHostStore(url: URL(fileURLWithPath: arguments[0]), documentID: arguments[3], actorID: arguments[4])
            let relay = try await ModernNativeRelayClient.open(store: store, endpoint: endpoint, relayKey: arguments[2],
                token: ProcessInfo.processInfo.environment["MODERN_RELAY_TOKEN"] ?? "")
            defer { relay.close() }
            let model = relay.persistence.model
            switch arguments[5] {
            case "inspect": break
            case "title-prefix":
                guard arguments.count == 7 else { throw EditorError.invalidChange }
                try model.perform { try $0.replaceTitle(range: 0..<0, with: arguments[6]); return nil }
                try await relay.persistence.save()
            case "appearance":
                guard arguments.count == 8 else { throw EditorError.invalidChange }
                try model.perform { try $0.setAppearance(field: arguments[6], value: arguments[7]); return nil }
                try await relay.persistence.save()
            case "columns":
                guard arguments.count == 8, let split = Int(arguments[7]) else { throw EditorError.invalidChange }
                try model.perform { try $0.resizeColumns(ModernColumnTarget(layout: $0.node(at: NodeAddress(arguments[6]))), splitBasisPoints: split).focus }
                try await relay.persistence.save()
            case "exchange": try await relay.exchange()
            case "undo": try model.undo(); try await relay.persistence.save()
            case "redo": try model.redo(); try await relay.persistence.save()
            case "resume-held": try relay.restoredHost?.resumeDeferredChanges(); try await relay.persistence.save()
            case "repair-undo":
                guard arguments.count == 7 else { throw EditorError.invalidChange }
                let targets = try JSONDecoder().decode([ChangeID].self, from: Data(arguments[6].utf8))
                try model.session.repairUndo(targets); try await relay.persistence.save()
            case "export":
                guard arguments.count == 7 else { throw EditorError.invalidChange }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(model.checkpoint()).write(to: URL(fileURLWithPath: arguments[6]), options: .atomic)
            default: throw EditorError.invalidChange
            }
            let output: [String: Any] = ["document": try JSONSerialization.jsonObject(with: model.document.json()),
                "pendingChanges": relay.pendingChanges, "receipt": try JSONSerialization.jsonObject(with: JSONEncoder().encode(relay.receipt)),
                "retainedRecovery": model.session.mergeRecovery != nil]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("Modern native relay action failed: \(error)\n".utf8)); exit(1)
        }
    }
}
