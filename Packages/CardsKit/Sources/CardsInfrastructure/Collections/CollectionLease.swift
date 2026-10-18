import CardsCore
import Darwin
import Foundation

/// A persistent inode, not a PID file. Never unlink a published lock, even after a crash.
final class CollectionLease {
    private var descriptor: Int32?

    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CollectionAccessError.fileSystem(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw CollectionAccessError.locked }
            throw CollectionAccessError.fileSystem(code)
        }
        self.descriptor = descriptor
    }

    /// Release at the lifecycle boundary, even if an async frame still retains this object.
    /// The owner serializes access. Never unlink the inode or close a reused descriptor twice.
    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        Darwin.close(descriptor)
    }

    deinit { release() }
}
