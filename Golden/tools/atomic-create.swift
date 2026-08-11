import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: atomic-create.swift SOURCE TARGET\n".utf8))
    exit(64)
}

let source = CommandLine.arguments[1]
let target = CommandLine.arguments[2]
let result = source.withCString { sourcePath in
    target.withCString { targetPath in
        renameatx_np(
            AT_FDCWD,
            sourcePath,
            AT_FDCWD,
            targetPath,
            UInt32(RENAME_EXCL)
        )
    }
}
guard result == 0 else {
    let message = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("atomic no-replace create failed: \(message)\n".utf8))
    exit(1)
}
