// license:GPLv3+

import Foundation

struct LibraryTable: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        let titles = [
            "Attack from Mars": "Attack from Mars",
            "Black Hole": "Black Hole",
            "Gorgar": "Gorgar",
            "Meteor": "Meteor",
            "Middle Earth": "Middle Earth",
            "The Machine - Bride Of Pinbot": "The Machine: Bride of Pinbot",
            "VR Room Time Machine": "Time Machine"
        ]
        return titles.first { name.hasPrefix($0.key + " (") }?.value ?? name
    }
}

enum TableLibrary {
    private static let extensions: Set<String> = ["vpx", "vpz"]

    static func tables(in documents: URL) -> [LibraryTable] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var tables: [LibraryTable] = []
        while let file = files.nextObject() as? URL {
            guard let metadata = try? file.resourceValues(forKeys: Set(keys)), metadata.isSymbolicLink != true else {
                files.skipDescendants()
                continue
            }
            if extensions.contains(file.pathExtension.lowercased()),
               metadata.isRegularFile == true || metadata.isDirectory == true {
                tables.append(LibraryTable(url: file))
                files.skipDescendants()
            } else if metadata.isDirectory == true,
                      ["pinmame", "cache", "user", "music", "autosave"].contains(file.lastPathComponent.lowercased()) {
                files.skipDescendants()
            }
        }
        return tables.sorted {
            let byTitle = $0.title.localizedStandardCompare($1.title)
            return byTitle == .orderedSame ? $0.url.path < $1.url.path : byTitle == .orderedAscending
        }
    }

    /// Import a folder as one VPX directory. PinMAME looks for pinmame/roms
    /// beside the tables. VPX looks for backglass files beside their tables.
    static func importFolder(_ source: URL, to documents: URL) throws -> [LibraryTable] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        func entries(_ dir: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .filter { try $0.resourceValues(forKeys: keys).isSymbolicLink != true }
        }
        let contents = try entries(source)
        let sources = contents.filter { extensions.contains($0.pathExtension.lowercased()) }
        guard !sources.isEmpty else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Choose a folder with VPX tables and their companion files."
            ])
        }

        let imports = documents.appending(path: "Table Imports", directoryHint: .isDirectory)
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        let destination = imports.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        // Stage outside the catalog so a failed copy never exposes a partial table.
        let stage = imports.appending(path: ".\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        let romFolder = "pinmame/roms"
        let romSource = source.appending(path: romFolder, directoryHint: .isDirectory)
        let romDestination = stage.appending(path: romFolder, directoryHint: .isDirectory)
        let roms = contents + ((try? entries(romSource)) ?? [])
        try fm.createDirectory(at: romDestination, withIntermediateDirectories: true)
        func copy(_ file: URL, to target: URL) throws {
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
        }
        for rom in roms where rom.pathExtension.lowercased() == "zip" {
            guard try rom.resourceValues(forKeys: keys).isRegularFile == true else { continue }
            try copy(rom, to: romDestination.appending(path: rom.lastPathComponent))
        }
        let backglasses = contents.filter { $0.pathExtension.lowercased() == "directb2s" }
        for table in sources {
            try copy(table, to: stage.appending(path: table.lastPathComponent))
            let stem = table.deletingPathExtension().lastPathComponent
            let matching = backglasses.filter {
                stem.lowercased().hasPrefix($0.deletingPathExtension().lastPathComponent.lowercased())
            }
            if let backglass = matching.max(by: { $0.lastPathComponent.count < $1.lastPathComponent.count }) {
                try copy(backglass, to: stage.appending(path: stem + ".directb2s"))
            }
        }
        // Keep existing tables, ROMs and per-ROM saves on repeat imports.
        if fm.fileExists(atPath: destination.path) {
            let importedROMs = destination.appending(path: romFolder, directoryHint: .isDirectory)
            try fm.createDirectory(at: importedROMs, withIntermediateDirectories: true)
            for file in try entries(romDestination) { try copy(file, to: importedROMs.appending(path: file.lastPathComponent)) }
            let files = try entries(stage)
            for file in files where file.lastPathComponent != "pinmame" {
                try copy(file, to: destination.appending(path: file.lastPathComponent))
            }
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
        return tables(in: documents)
    }
}
