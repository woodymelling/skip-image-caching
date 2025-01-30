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

        func task(requests: [ImageRequest], imagePipeline: ImagePipeline) async {

            let validRequests = requests.filter { $0.url != nil }
            guard !validRequests.isEmpty else { return }


            // Get first available in cache
            let cached = validRequests
                .lazy
                .enumerated()
                .compactMap { offset, request in
                    imagePipeline.cache[request]
                        .map { (element: $0, offset: offset)}
                }
                .first

            if let cached {
                self.platformImage = cached.element.image
                self.displayedURLOffset = cached.offset
            }

            // Get async attempt
            await withTaskGroup(of: (offset: Int, result: PlatformImage?).self) { group in
                for request in validRequests.enumerated() {
                    group.addTask {
                        let fetchedImage = try? await imagePipeline.image(for: request.element)
                        return (request.offset, fetchedImage)
                    }
                }

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
        requests: [ImageRequest],
        @ViewBuilder content: @escaping (Image) -> I = { $0 },
        @ViewBuilder placeholder: () -> P
    ) {
        self.requests = requests
        self.content = content
        self.placeholder = placeholder()

        self.model = Model()
    }

    public init(
        url urls: URL?...,
        @ViewBuilder content: @escaping (Image) -> I = { $0 },
        @ViewBuilder placeholder: () -> P
    ) {
        self.init(
            requests: urls.map { ImageRequest(url: $0) },
            content: content,
            placeholder: placeholder
        )
    }

    var requests: [ImageRequest]
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
            await model.task(requests: requests, imagePipeline: .shared)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    @Entry
    public var imagePipeline: ImagePipeline = .shared
}


