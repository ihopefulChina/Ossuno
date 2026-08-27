import SwiftUI

struct BrowserObjectContextMenu: View {
    var model: AppModel
    var object: OSSObject
    var showsRevealInFolder = false

    var body: some View {
        Button("快速查看") {
            model.selectForContextMenu(object.key)
            Task { await model.quickLook(object) }
        }
        .onAppear { model.selectForContextMenu(object.key) }
        Button(model.deleteMenuTitle(clickedKey: object.key), role: .destructive) {
            model.requestDeleteSelection(
                keys: model.menuActionKeys(clickedKey: object.key),
                deferConfirmation: true
            )
        }
        .disabled(model.isOrganizingCloud)
        if showsRevealInFolder {
            Button("显示所在文件夹") {
                Task { await model.openSearchResult(object) }
            }
        }
        Divider()
        Button("复制链接") {
            model.selectForContextMenu(object.key)
            model.copyURLs(style: .plain)
        }
        Button("复制 Markdown") {
            model.selectForContextMenu(object.key)
            model.copyURLs(style: .markdown)
        }
        Button("复制") {
            model.selectForContextMenu(object.key)
            model.copyCloudSelection(clickedKey: object.key)
        }
        Button("剪切") {
            model.selectForContextMenu(object.key)
            model.cutCloudSelection(clickedKey: object.key)
        }
        if !showsRevealInFolder {
            Button(model.pasteMenuTitle) {
                model.paste()
            }
            .disabled(!model.canPaste)
        }
        Button(model.downloadMenuTitle(clickedKey: object.key)) {
            model.selectForContextMenu(object.key)
            model.downloadSelection()
        }
        Button("重命名") {
            model.requestRename(key: object.key)
        }
        .disabled(model.isOrganizingCloud)
        Button("对象属性") {
            model.selectForContextMenu(object.key)
            model.presentObjectProperties(for: object)
        }
    }
}
