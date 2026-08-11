import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: atomic-promote.swift STAGING ACCEPTED\n".utf8))
    exit(64)
}

let fileManager = FileManager.default
let staging = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let accepted = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let backupName = ".\(accepted.lastPathComponent).previous-\(UUID().uuidString)"
let backup = accepted.deletingLastPathComponent().appendingPathComponent(backupName)

do {
    _ = try fileManager.replaceItemAt(
        accepted,
        withItemAt: staging,
        backupItemName: backupName,
        options: []
    )
    do {
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
    } catch {
        FileHandle.standardError.write(Data(
            "warning: promoted successfully; backup cleanup failed: \(error.localizedDescription)\n".utf8
        ))
    }
} catch {
    FileHandle.standardError.write(Data("atomic promotion failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
