#if os(iOS)
import SwiftUI
@preconcurrency import Photos
import UIKit

struct PhotoAlbumResultView: View {
    let album: PhotoAlbumMatch
    @ObservedObject var service: PhotoAlbumService
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            coverView
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).font(.headline).foregroundStyle(.primary)
                Text(album.itemCount == 1 ? "1 item" : "\(album.itemCount) itens")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .task(id: album.coverAssetIdentifier) {
            guard let identifier = album.coverAssetIdentifier else { return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = fetched.firstObject else { return }
            cover = await service.image(for: asset, size: CGSize(width: 240, height: 240))
        }
    }

    @ViewBuilder private var coverView: some View {
        if let cover {
            Image(uiImage: cover).resizable().scaledToFill()
                .frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(.secondary)
                .frame(width: 76, height: 76).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct PhotoAlbumDetailView: View {
    let album: PhotoAlbumMatch
    @ObservedObject var service: PhotoAlbumService
    @State private var selection: Set<String> = []
    @State private var sharingItems: [UIImage] = []
    @State private var showingShareSheet = false
    @State private var isPreparingShare = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(service.albumAssets, id: \.localIdentifier) { asset in
                    SelectablePhotoCell(asset: asset, service: service, isSelected: selection.contains(asset.localIdentifier)) {
                        if selection.contains(asset.localIdentifier) { selection.remove(asset.localIdentifier) }
                        else { selection.insert(asset.localIdentifier) }
                    }
                }
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                Button {
                    prepareShare()
                } label: {
                    if isPreparingShare { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Compartilhar \(selection.count)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(isPreparingShare)
                .padding().background(.bar)
            }
        }
        .sheet(isPresented: $showingShareSheet) { ActivityView(items: sharingItems) }
        .onAppear { service.open(album) }
    }

    private func prepareShare() {
        isPreparingShare = true
        Task {
            sharingItems = await service.imagesForSharing(assetIDs: selection)
            isPreparingShare = false
            showingShareSheet = !sharingItems.isEmpty
        }
    }
}

private struct SelectablePhotoCell: View {
    let asset: PHAsset
    @ObservedObject var service: PhotoAlbumService
    let isSelected: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { Color(.tertiarySystemFill).overlay { ProgressView() } }
                }
                .aspectRatio(1, contentMode: .fit).clipped()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? Color.white : Color.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.localIdentifier) { image = await service.image(for: asset, size: CGSize(width: 360, height: 360)) }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
#endif
