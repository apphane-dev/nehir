import Darwin

@main
enum NehirCtlMain {
    static func main() async {
        exit(await CLIRuntime.run(arguments: CommandLine.arguments))
    }
}
