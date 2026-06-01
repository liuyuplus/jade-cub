//
//  ShelfPanelView.swift
//  PingIsland
//
//  Drag-and-drop file shelf panel for the island.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ShelfPanelView: View {
    @ObservedObject private var store = ShelfStore.shared
    @State private var isDropTargeted = false
    @State private var selectedItemIds: Set<UUID> = []
    @State private var copyToastText: String?
    @State private var copyToastDismissWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                header

                Group {
                    if store.items.isEmpty {
                        emptyDropZone
                    } else {
                        itemList
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let copyToastText {
                copyToast(copyToastText)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            store.addItemProviders(providers)
        }
        .onChange(of: store.items) { _, items in
            let visibleIds = Set(items.map(\.id))
            selectedItemIds.formIntersection(visibleIds)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("Shelf")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text("\(store.items.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())

            selectAllButton

            Spacer(minLength: 0)

            if !selectedItems.isEmpty {
                Button {
                    store.copyItemsToPasteboard(selectedItems)
                    showCopyToast("已复制 \(selectedItems.count) 个文件")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(selectedItems.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.black.opacity(0.86))
                    .frame(height: 24)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("复制已选文件")
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: selectedItemIds)
    }

    private var selectAllButton: some View {
        Button {
            toggleSelectAll()
        } label: {
            Image(systemName: selectAllIconName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selectAllForeground)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(isAllSelected ? 0.15 : 0.075))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isAllSelected ? "取消全选" : "全选")
    }

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(isDropTargeted ? 0.92 : 0.5))

            Text("Drop files here")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            Text("Files are copied into Jade Cub's local shelf")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 138)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isDropTargeted ? 0.1 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isDropTargeted ? 0.28 : 0.1),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
        )
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(store.items) { item in
                    ShelfItemRow(
                        item: item,
                        store: store,
                        isSelected: selectedItemIds.contains(item.id)
                    ) { selected in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            if selected {
                                selectedItemIds.insert(item.id)
                            } else {
                                selectedItemIds.remove(item.id)
                            }
                        }
                    }
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .center)),
                                removal: .opacity
                                    .combined(with: .scale(scale: 0.94, anchor: .center))
                                    .combined(with: .move(edge: .trailing))
                            )
                        )
                }
            }
            .padding(.vertical, 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: store.items)
        }
        .frame(maxHeight: 260)
        .overlay(alignment: .bottom) {
            if isDropTargeted {
                dropOverlay
            }
        }
    }

    private var dropOverlay: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
            Text("Add to Shelf")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.82))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .padding(.bottom, 4)
    }

    private var selectedItems: [ShelfItem] {
        store.items.filter { selectedItemIds.contains($0.id) }
    }

    private var isAllSelected: Bool {
        !store.items.isEmpty && selectedItemIds.count == store.items.count
    }

    private var selectAllIconName: String {
        isAllSelected ? "checkmark.square.fill" : "checkmark.square"
    }

    private var selectAllForeground: Color {
        isAllSelected ? TerminalColors.green.opacity(0.95) : Color.white.opacity(0.68)
    }

    private func toggleSelectAll() {
        if isAllSelected {
            selectedItemIds.removeAll()
        } else {
            selectedItemIds = Set(store.items.map(\.id))
        }
    }

    private func showCopyToast(_ text: String) {
        copyToastDismissWorkItem?.cancel()

        withAnimation(.easeOut(duration: 0.14)) {
            copyToastText = text
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.22)) {
                copyToastText = nil
            }
        }
        copyToastDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.45, execute: workItem)
    }

    private func copyToast(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.black.opacity(0.84))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.94))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    let store: ShelfStore
    let isSelected: Bool
    let onSelectionChange: (Bool) -> Void

    @State private var isHovering = false
    @State private var isCopyButtonHovering = false
    @State private var isRemoveButtonHovering = false
    @State private var isRemoving = false
    @State private var thumbnail: NSImage?
    @State private var fileIconImage: NSImage?
    @State private var inlineCopyToastVisible = false
    @State private var inlineCopyToastWorkItem: DispatchWorkItem?
    @State private var optimisticSelection: Bool?

    var body: some View {
        HStack(spacing: 9) {
            selectionButton

            fileIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(item.originalName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(item.kind.label)
                    Text(Self.dateFormatter.string(from: item.addedAt))
                    if let size = item.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            copyButton

            Button {
                removeWithAnimation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .black))
                    .foregroundStyle(removeButtonForeground)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(removeButtonBackground)
                    )
                    .scaleEffect(isRemoveButtonHovering ? 1.0 : 0.92)
                    .opacity(isRemoveButtonHovering ? 1 : 0.72)
            }
            .buttonStyle(.plain)
            .help("移除")
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isRemoveButtonHovering = hovering
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.105 : 0.062))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(isHovering ? 0.14 : 0.07), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isRemoving ? 0 : 1)
        .scaleEffect(isRemoving ? 0.97 : 1, anchor: .center)
        .offset(x: isRemoving ? 16 : 0)
        .animation(.easeOut(duration: 0.14), value: isRemoving)
        .onTapGesture(count: 2) {
            store.open(item)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("打开") { store.open(item) }
            Button("在访达中显示") { store.revealInFinder(item) }
            Button("复制文件") { store.copyItemToPasteboard(item) }
            Button("复制路径") { store.copyPath(item) }
            Divider()
            Button("移除") { removeWithAnimation() }
        }
        .onAppear {
            loadFileIconIfNeeded()
            loadThumbnailIfNeeded()
        }
        .onChange(of: isSelected) { _, selected in
            optimisticSelection = selected
        }
    }

    private var copyButton: some View {
        Button {
            store.copyItemToPasteboard(item)
            showInlineCopyToast()
        } label: {
            ZStack(alignment: .leading) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(actionButtonForeground)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(actionButtonBackground))
                    .scaleEffect(isCopyButtonHovering ? 1.0 : 0.92)
                    .opacity(isCopyButtonHovering ? 1 : 0.72)

                if inlineCopyToastVisible {
                    Text("已复制")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.84))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.94))
                        .clipShape(Capsule())
                        .fixedSize()
                        .offset(x: -48)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .help("复制文件")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isCopyButtonHovering = hovering
            }
        }
    }

    private var selectionButton: some View {
        Image(systemName: effectiveSelection ? "checkmark.square.fill" : "square")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(selectionColor)
            .frame(width: 22, height: 38)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard abs(value.translation.width) < 6,
                              abs(value.translation.height) < 6 else {
                            return
                        }
                        toggleSelection()
                    }
            )
            .help(effectiveSelection ? "取消选择" : "选择")
    }

    @ViewBuilder
    private var fileIcon: some View {
        if item.kind == .image,
           let image = thumbnail {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Group {
                if let fileIconImage {
                    Image(nsImage: fileIconImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: fallbackIconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.64))
                }
            }
            .frame(width: 30, height: 30)
            .padding(4)
            .frame(width: 38, height: 38)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var removeButtonForeground: Color {
        isRemoveButtonHovering ? .black.opacity(0.82) : .white.opacity(0.44)
    }

    private var removeButtonBackground: Color {
        isRemoveButtonHovering ? .white.opacity(0.9) : .white.opacity(0.08)
    }

    private var actionButtonForeground: Color {
        isCopyButtonHovering ? .black.opacity(0.82) : .white.opacity(0.5)
    }

    private var actionButtonBackground: Color {
        isCopyButtonHovering ? .white.opacity(0.88) : .white.opacity(0.08)
    }

    private var selectionColor: Color {
        effectiveSelection ? TerminalColors.green.opacity(0.95) : Color.white.opacity(isHovering ? 0.5 : 0.28)
    }

    private var effectiveSelection: Bool {
        optimisticSelection ?? isSelected
    }

    private var fallbackIconName: String {
        switch item.kind {
        case .folder:
            return "folder.fill"
        case .image:
            return "photo.fill"
        case .pdf:
            return "doc.richtext.fill"
        case .document:
            return "doc.text.fill"
        case .spreadsheet:
            return "tablecells.fill"
        case .presentation:
            return "rectangle.on.rectangle.fill"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .archive:
            return "archivebox.fill"
        case .file:
            return "doc.fill"
        }
    }

    private func removeWithAnimation() {
        guard !isRemoving else { return }

        withAnimation(.easeOut(duration: 0.14)) {
            isRemoving = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                store.remove(item)
            }
        }
    }

    private func toggleSelection() {
        let nextSelection = !effectiveSelection

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            optimisticSelection = nextSelection
            onSelectionChange(nextSelection)
        }
    }

    private func showInlineCopyToast() {
        inlineCopyToastWorkItem?.cancel()

        withAnimation(.easeOut(duration: 0.12)) {
            inlineCopyToastVisible = true
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.22)) {
                inlineCopyToastVisible = false
            }
        }
        inlineCopyToastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: workItem)
    }

    private func loadThumbnailIfNeeded() {
        guard item.kind == .image, thumbnail == nil else { return }

        let url = item.storedURL
        Task.detached(priority: .utility) {
            guard let image = Self.makeThumbnail(for: url, maxPixelSize: 96) else { return }
            await MainActor.run {
                thumbnail = image
            }
        }
    }

    private func loadFileIconIfNeeded() {
        guard item.kind != .image, fileIconImage == nil else { return }

        if let cachedIcon = Self.fileIconCache.object(forKey: item.storedPath as NSString) {
            fileIconImage = cachedIcon
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: item.storedPath)
        icon.size = NSSize(width: 38, height: 38)
        Self.fileIconCache.setObject(icon, forKey: item.storedPath as NSString)
        fileIconImage = icon
    }

    nonisolated private static func makeThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let fileIconCache = NSCache<NSString, NSImage>()
}
