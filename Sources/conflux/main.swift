import AppKit
import ConfluxCore
import Foundation

// `conflux` opens the window. `conflux serve ...` runs without one, and
// `conflux token` prints the gateway's token.
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "app":
    ConfluxApp.main()
case "serve":
    Task { exit(await ServeCommand.run(Array(arguments.dropFirst()))) }
    dispatchMain()
case "token":
    do {
        if arguments.dropFirst().first == "--rotate" { try TokenStore.rotate() }
        print(try TokenStore.token())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("conflux: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "help", "-h", "--help":
    print(ServeCommand.usage)
default:
    FileHandle.standardError.write(Data("conflux: unknown command \(arguments[0])\n\n\(ServeCommand.usage)\n".utf8))
    exit(64)
}
