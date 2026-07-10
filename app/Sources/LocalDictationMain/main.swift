import LocalDictation

@main
enum LocalDictationMain {
    static func main() {
        MainActor.assumeIsolated {
            LocalDictationBootstrap.run()
        }
    }
}
