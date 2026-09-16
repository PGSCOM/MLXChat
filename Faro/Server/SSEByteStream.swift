import Foundation
import FlyingSocks

/// Bridges a plain `AsyncStream<Data>` (easy to produce from an MLX
/// generation loop) into the buffered byte sequence FlyingFox needs for
/// a chunked-encoded streaming response body.
struct SSEByteStream: AsyncBufferedSequence {
    typealias Element = UInt8
    let chunks: AsyncStream<Data>

    func makeAsyncIterator() -> Iterator {
        Iterator(base: chunks.makeAsyncIterator())
    }

    struct Iterator: AsyncBufferedIteratorProtocol {
        var base: AsyncStream<Data>.Iterator
        var pending = Data()

        mutating func nextBuffer(suggested count: Int) async throws -> Data? {
            while pending.isEmpty {
                guard let next = await base.next() else { return nil }
                pending = next
            }
            let n = Swift.min(count, pending.count)
            let out = Data(pending.prefix(n))
            pending.removeFirst(n)
            return out
        }

        mutating func next() async throws -> UInt8? {
            try await nextBuffer(suggested: 1)?.first
        }
    }
}
