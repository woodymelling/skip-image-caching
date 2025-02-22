@_exported import Nuke
import SwiftUI

public struct CachedAsyncImage<I: View, P: View>: View {
    @Observable
    class Model {
        #if canImport(SwiftUI)
        public var image: Image? {
            #if os(macOS)
            platformImage.map { Image(nsImage: $0) }
            #else
            platformImage.map { Image(uiImage: $0) }
            #endif
        }
        #endif

        private var platformImage: PlatformImage?
        private var displayedURLOffset: Int = .max

        func task(requests: [PipelinedRequest]) async {

            let validRequests = requests.filter { $0.url != nil }
            guard !validRequests.isEmpty else { return }


            // Get first available in cache
            let cachedImage = validRequests
                .lazy
                .enumerated()
                .compactMap { offset, request in
                    request.cachedImage.map { (image: $0, offset: offset) }
                }
                .first

            if let cachedImage {
                print("Cache hit!")
                self.platformImage = cachedImage.image
                self.displayedURLOffset = cachedImage.offset
            }

            // Get asynchronously from the cache
            await withTaskGroup(of: (offset: Int, result: PlatformImage?).self) { group in
                for (offset, request) in validRequests.enumerated() {
                    group.addTask {
                        let fetchedImage = try? await request.image()
                        return (offset, fetchedImage)
                    }
                }

                // Only move the image
                for await (offset, image) in group {
                    if let image, offset < displayedURLOffset {
                        self.displayedURLOffset = offset
                        self.platformImage = image
                    }
                }
            }
        }
    }

    public init(
        requests: [PipelinedRequest],
        @ViewBuilder content: @escaping (Image) -> I = { $0 },
        @ViewBuilder placeholder: () -> P
    ) {
        self.requests = requests
        self.content = content
        self.placeholder = placeholder()
    }

    public init(
        requests: [ImageRequest],
        on pipeline: ImagePipeline = .shared,
        @ViewBuilder content: @escaping (Image) -> I = { $0 },
        @ViewBuilder placeholder: () -> P
    ) {
        self.requests = requests.map { PipelinedRequest(request: $0, on: pipeline) }
        self.content = content
        self.placeholder = placeholder()

        self.model = Model()
    }

    public init(
        url urls: URL?...,
        on pipeline: ImagePipeline = .shared,
        @ViewBuilder content: @escaping (Image) -> I = { $0 },
        @ViewBuilder placeholder: () -> P
    ) {
        self.init(
            requests: urls.map { ImageRequest(url: $0) },
            on: pipeline,
            content: content,
            placeholder: placeholder
        )
    }

    var requests: [PipelinedRequest]
    var content: (Image) -> I
    var placeholder: P

    @State var model = Model()


    @Environment(\.imagePipeline) var imagePipeline

    public var body: some View {
        Group {
            if let image = model.image {
                content(image)
            } else {
                placeholder
            }
        }
        .task {
            await model.task(requests: requests)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    @Entry
    public var imagePipeline: ImagePipeline = .shared
}


@dynamicMemberLookup
public struct PipelinedRequest {
    public var imageRequest: ImageRequest
    public var pipeline: ImagePipeline

    public func image() async throws -> PlatformImage? {
        try await pipeline.image(for: imageRequest)
    }

    public var cachedImage: PlatformImage? {
        print(self.pipeline.cache)
        return self.pipeline.cache[self.imageRequest]?.image
    }

    public init(request: ImageRequest, on pipeline: ImagePipeline) {
        self.imageRequest = request
        self.pipeline = pipeline
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<ImageRequest, T>) -> T {
        imageRequest[keyPath: keyPath]
    }
}

extension ImageRequest {
    public func withPipeline(_ pipeline: ImagePipeline) -> PipelinedRequest {
        PipelinedRequest(request: self, on: pipeline)
    }
}
