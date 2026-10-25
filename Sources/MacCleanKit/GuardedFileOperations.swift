import Foundation
import Darwin

/// Destructive operations pin parent directories with file descriptors and
/// never follow a symlink while opening a path. A selected entry is moved into
/// a private, same-volume staging directory before it is changed. Its identity
/// is checked after that atomic move, not just before it.
public enum GuardedFileOperations {
    public static func trash(_ url: URL, inode: UInt64 = 0, device: Int32 = 0) throws -> URL {
        let captured = try CapturedFile(url, inode: inode, device: device)
        do {
            // Ask Foundation for the volume-appropriate Trash using an item
            // that still exists. If this fails, restore the captured entry.
            let trash = try FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask,
                appropriateFor: captured.stagingURL.appendingPathComponent("original"), create: true)
            let destination = try PinnedDirectory(trash)
            let name = "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)"
                + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
            try captured.move(to: destination, name: name)
            return destination.url.appendingPathComponent(name)
        }
        catch { try captured.restore(); throw error }
    }

    public static func remove(_ url: URL, inode: UInt64 = 0, device: Int32 = 0) throws {
        let captured = try CapturedFile(url, inode: inode, device: device)
        do { try captured.remove() }
        catch { try captured.restore(); throw error }
    }

    public static func secureErase(_ url: URL) throws {
        let captured = try CapturedFile(url)
        do { try captured.overwriteAndRemove() }
        catch { try captured.restore(); throw error }
    }
}

enum GuardedFileError: LocalizedError, Equatable {
    case changed
    case symbolicLink
    case hardLinked
    case directory
    case recovery(URL)

    var errorDescription: String? {
        switch self {
        case .changed: "The file changed after selection. Rescan before trying again."
        case .symbolicLink: "Refusing a symbolic link in a destructive operation."
        case .hardLinked: "Secure erase cannot overwrite a file with other hard links."
        case .directory: "Secure erase cannot be used on directories."
        case .recovery(let url): "The original path is occupied. The staged item is preserved at \(url.path)."
        }
    }
}

func fileSystemError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

struct FileIdentity {
    let value: stat

    init(directory: Int32, name: String) throws {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fileSystemError() }
        value = info
    }

    init(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileSystemError() }
        value = info
    }

    var isDirectory: Bool { value.st_mode & S_IFMT == S_IFDIR }
    var isRegular: Bool { value.st_mode & S_IFMT == S_IFREG }
    var isSymlink: Bool { value.st_mode & S_IFMT == S_IFLNK }

    func sameObject(as other: FileIdentity) -> Bool {
        value.st_dev == other.value.st_dev && value.st_ino == other.value.st_ino
            && (value.st_mode & S_IFMT) == (other.value.st_mode & S_IFMT)
    }

    func sameRevision(as other: FileIdentity) -> Bool {
        sameObject(as: other) && value.st_size == other.value.st_size
            && value.st_mtimespec.tv_sec == other.value.st_mtimespec.tv_sec
            && value.st_mtimespec.tv_nsec == other.value.st_mtimespec.tv_nsec
            && value.st_ctimespec.tv_sec == other.value.st_ctimespec.tv_sec
            && value.st_ctimespec.tv_nsec == other.value.st_ctimespec.tv_nsec
    }
}

/// Canonicalize legitimate macOS aliases once, then open every component
/// relative to an already-open parent. A replacement symlink is refused by
/// the kernel. No later mutation uses the original absolute pathname.
final class PinnedDirectory {
    let descriptor: Int32
    let url: URL

    init(_ url: URL) throws {
        // Foundation standardization can shorten /private/var back to the
        // /var symlink. Walk the POSIX realpath string, not URL.pathComponents.
        guard let resolved = realpath(url.path(percentEncoded: false), nil) else { throw fileSystemError() }
        let canonical = String(cString: resolved)
        free(resolved)
        self.url = URL(fileURLWithPath: canonical, isDirectory: true)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw fileSystemError() }
        do {
            for part in canonical.split(separator: "/") {
                let component = String(part)
                guard component != ".", component != ".." else { throw GuardedFileError.changed }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw fileSystemError() }
                close(current)
                current = next
            }
        } catch {
            close(current)
            throw error
        }
        descriptor = current
    }

    deinit { close(descriptor) }
}

/// An entry detached from its public pathname. Errors restore it without
/// overwriting anything. If another app recreated that pathname, retain the
/// staged entry for recovery and report its location.
final class CapturedFile {
    let parent: PinnedDirectory
    let originalName: String
    let stagingName: String
    let stagingDescriptor: Int32
    let stagingURL: URL
    let identity: FileIdentity
    private var active = true

    init(_ url: URL, inode: UInt64 = 0, device: Int32 = 0,
         beforeCapture: (() throws -> Void)? = nil) throws {
        try SafetyGuard().validatePath(url)
        originalName = url.lastPathComponent
        guard !originalName.isEmpty, originalName != "/", originalName != ".", originalName != ".."
        else { throw GuardedFileError.changed }
        parent = try PinnedDirectory(url.deletingLastPathComponent())
        // Validate what was actually pinned as well as the caller's path.
        try SafetyGuard().validatePath(parent.url.appendingPathComponent(originalName))
        let expected = try FileIdentity(directory: parent.descriptor, name: originalName)
        guard !expected.isSymlink else { throw GuardedFileError.symbolicLink }
        if inode != 0, UInt64(expected.value.st_ino) != inode { throw GuardedFileError.changed }
        if device != 0, expected.value.st_dev != device { throw GuardedFileError.changed }
        stagingName = ".macsai-operation-\(UUID().uuidString)"
        stagingURL = parent.url.appendingPathComponent(stagingName)
        guard mkdirat(parent.descriptor, stagingName, 0o700) == 0 else { throw fileSystemError() }
        let stage = openat(parent.descriptor, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else {
            let error = fileSystemError()
            unlinkat(parent.descriptor, stagingName, AT_REMOVEDIR)
            throw error
        }
        stagingDescriptor = stage
        do {
            try beforeCapture?()
            guard renameatx_np(parent.descriptor, originalName, stage, "original", UInt32(RENAME_EXCL)) == 0
            else { throw fileSystemError() }
            let actual = try FileIdentity(directory: stage, name: "original")
            guard expected.sameObject(as: actual), !actual.isSymlink else {
                guard renameatx_np(stage, "original", parent.descriptor, originalName, UInt32(RENAME_EXCL)) == 0
                else { throw GuardedFileError.recovery(stagingURL.appendingPathComponent("original")) }
                throw GuardedFileError.changed
            }
            identity = actual
        } catch {
            // Never recursively remove this directory on failure. It may
            // contain the only surviving copy of an item we could not restore.
            let restoreFailed = renameatx_np(stage, "original", parent.descriptor,
                                             originalName, UInt32(RENAME_EXCL)) != 0 && errno != ENOENT
            close(stage)
            unlinkat(parent.descriptor, stagingName, AT_REMOVEDIR)
            if restoreFailed { throw GuardedFileError.recovery(stagingURL.appendingPathComponent("original")) }
            throw error
        }
    }

    deinit {
        if active {
            // Fail safe: a concurrent replacement at the original path wins;
            // its existence must never cause an overwrite of either file.
            _ = renameatx_np(stagingDescriptor, "original", parent.descriptor, originalName, UInt32(RENAME_EXCL))
        }
        close(stagingDescriptor)
        _ = unlinkat(parent.descriptor, stagingName, AT_REMOVEDIR)
    }

    func openOriginal(_ flags: Int32) throws -> Int32 {
        let fd = openat(stagingDescriptor, "original", flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fileSystemError() }
        do {
            guard identity.sameObject(as: try FileIdentity(descriptor: fd)) else { throw GuardedFileError.changed }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    func restore() throws {
        guard renameatx_np(stagingDescriptor, "original", parent.descriptor, originalName, UInt32(RENAME_EXCL)) == 0
        else { throw GuardedFileError.recovery(stagingURL.appendingPathComponent("original")) }
        active = false
    }

    func move(to destination: PinnedDirectory, name: String) throws {
        guard renameatx_np(stagingDescriptor, "original", destination.descriptor, name, UInt32(RENAME_EXCL)) == 0
        else { throw fileSystemError() }
        active = false
    }

    func remove() throws {
        try Self.removeEntry(directory: stagingDescriptor, name: "original")
        active = false
    }

    /// Publish a verified replacement without overwriting a concurrently
    /// recreated destination. Keep the original until publication succeeds.
    func replace(with name: String) throws {
        guard renameatx_np(stagingDescriptor, name, parent.descriptor, originalName, UInt32(RENAME_EXCL)) == 0
        else { throw fileSystemError() }
        active = false
        guard unlinkat(stagingDescriptor, "original", 0) == 0
        else { throw GuardedFileError.recovery(stagingURL.appendingPathComponent("original")) }
    }

    func overwriteAndRemove() throws {
        guard !identity.isDirectory else { throw GuardedFileError.directory }
        guard identity.isRegular else { throw GuardedFileError.changed }
        let fd = try openOriginal(O_WRONLY)
        defer { close(fd) }
        // A hard link is a second name for the same inode. Never overwrite
        // its content, even if the other name lives outside the selected tree.
        let current = try FileIdentity(descriptor: fd)
        guard current.value.st_nlink == 1 else { throw GuardedFileError.hardLinked }
        var remaining = current.value.st_size
        let zeros = [UInt8](repeating: 0, count: 65_536)
        while remaining > 0 {
            let count = Int(min(remaining, off_t(zeros.count)))
            let written = zeros.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw fileSystemError() }
            remaining -= off_t(written)
        }
        guard ftruncate(fd, 0) == 0, fsync(fd) == 0 else { throw fileSystemError() }
        guard identity.sameObject(as: try FileIdentity(directory: stagingDescriptor, name: "original"))
        else { throw GuardedFileError.changed }
        try remove()
    }

    /// Recursive removal uses only directory-relative syscalls. Links inside
    /// a selected directory are unlinked as links, never traversed.
    private static func removeEntry(directory: Int32, name: String) throws {
        let entry = try FileIdentity(directory: directory, name: name)
        if entry.isDirectory {
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw fileSystemError() }
            defer { close(child) }
            guard entry.sameObject(as: try FileIdentity(descriptor: child)) else { throw GuardedFileError.changed }
            let duplicate = dup(child)
            guard duplicate >= 0 else { throw fileSystemError() }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw fileSystemError() }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let next = readdir(stream) else {
                    if errno != 0 { throw fileSystemError() }
                    break
                }
                let childName = withUnsafePointer(to: &next.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if childName != ".", childName != ".." { try removeEntry(directory: child, name: childName) }
            }
            guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw fileSystemError() }
        } else {
            guard unlinkat(directory, name, 0) == 0 else { throw fileSystemError() }
        }
    }
}
