import AIProviderApple
import AIProviderLocal
import AssistantAI
import AssistantDomain
import AssistantCore
import AssistantPersistence
import AssistantPlatform
import AssistantTools
import DevSupport
import Foundation
import MockPlatform

/// Command-line harness for the Windows development stage.
///
/// This is a scaffold for exercising the core, not a product surface. It wires
/// the real engine to the mock platform and the scripted development provider,
/// then prints what the assistant said, what it planned, and what the mock
/// platform recorded — clearly labelled as simulated.
@main
struct DevHarness {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        do {
            let session = try await HarnessSession.make(
                storageDirectory: storageDirectory(from: arguments)
            )

            if arguments.contains("--providers") {
                await session.printProviders()
                return
            }

            if arguments.contains("--demo") {
                try await session.runDemo()
            } else {
                try await session.runInteractive()
            }
        } catch {
            FileHandle.standardError.write(Data("Harness failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func storageDirectory(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--store"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func printUsage() {
        print(
            """
            assistant-dev — development harness for the assistant core

              (no arguments)   interactive session, in-memory storage
              --demo           run a scripted transcript and exit
              --providers      list registered AI providers and their availability
              --store <path>   persist conversations/tasks/memory as JSON in <path>
              --help           this message

            Everything the harness reports as "simulated" was recorded in memory
            only. No calendar event, notification or alarm reaches any device.
            """
        )
    }
}
