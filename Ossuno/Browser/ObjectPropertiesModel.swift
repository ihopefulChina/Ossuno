import Foundation
import Observation

@MainActor
@Observable
final class ObjectPropertiesModel {
    let object: OSSObject
    var draft = ObjectPropertiesDraft.empty
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var saveUnavailableMessage: String?
    var tagsUnavailable = false
    private var original = ObjectPropertiesDraft.empty
    private var loadedSnapshot: OSSObjectSnapshot?
    private let client: OSSClient
    private let onSaved: @MainActor () -> Void
    private let canMutate: @MainActor () -> Bool

    init(
        object: OSSObject,
        client: OSSClient,
        onSaved: @escaping @MainActor () -> Void,
        canMutate: @escaping @MainActor () -> Bool = { true }
    ) {
        self.object = object
        self.client = client
        self.onSaved = onSaved
        self.canMutate = canMutate
    }

    var canSave: Bool {
        !isLoading && !isSaving && !tagsUnavailable && saveUnavailableMessage == nil
            && loadedSnapshot != nil && draft.isValid && draft != original
            && canMutate()
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        saveUnavailableMessage = nil
        do {
            let snapshot = try await client.objectSnapshot(key: object.key)
            let head = snapshot.head
            let tags = snapshot.tags
            let loaded = ObjectPropertiesDraft(
                contentType: head.contentType ?? "",
                cacheControl: head.cacheControl ?? "",
                contentDisposition: head.contentDisposition ?? "",
                metadata: head.userMetadata.sorted(by: { $0.key < $1.key }).map {
                    EditableProperty(key: $0.key, value: $0.value)
                },
                tags: tags.map { EditableProperty(key: $0.key, value: $0.value) }
            )
            draft = loaded
            original = loaded
            loadedSnapshot = snapshot
            tagsUnavailable = false
            do {
                let status = try await client.bucketVersioningStatus()
                saveUnavailableMessage = status == .enabled
                    ? nil
                    : "安全保存对象属性要求 Bucket 已开启版本控制（当前：\(status.rawValue)）"
            } catch {
                saveUnavailableMessage = "无法确认 Bucket 版本控制状态，已禁用保存"
            }
        } catch {
            loadedSnapshot = nil
            tagsUnavailable = true
            saveUnavailableMessage = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func save() async -> Bool {
        guard canMutate() else {
            errorMessage = "请等待当前云端整理完成"
            return false
        }
        guard canSave, var snapshot = loadedSnapshot else { return false }
        isSaving = true
        errorMessage = nil
        do {
            guard try await client.objectMatchesSnapshot(
                key: object.key,
                expected: snapshot
            ) else {
                throw OSSServiceError(
                    statusCode: 0,
                    code: "ObjectChanged",
                    message: "对象已在其他位置发生变化，请重新打开属性后再保存",
                    requestId: ""
                )
            }
            if draft.properties != original.properties {
                let versionID = try await client.replaceMetadata(
                    key: object.key,
                    properties: draft.properties,
                    expected: snapshot
                )
                snapshot = try await client.objectSnapshot(
                    key: object.key,
                    versionID: versionID
                )
                loadedSnapshot = snapshot
                // Track what actually reached the cloud, so a later failure
                // doesn't pretend the metadata edit never happened.
                original.contentType = draft.contentType
                original.cacheControl = draft.cacheControl
                original.contentDisposition = draft.contentDisposition
                original.metadata = draft.metadata
            }
            if !tagsUnavailable, draft.tags != original.tags {
                // Metadata replacement can create a new object version. Verify
                // it is still current, then write tags to that exact version so
                // a concurrent writer never receives this form's tags.
                guard try await client.objectMatchesSnapshot(
                    key: object.key,
                    expected: snapshot
                ) else {
                    throw OSSServiceError(
                        statusCode: 0,
                        code: "ObjectChanged",
                        message: "对象在保存期间发生变化，标签未写入新版本",
                        requestId: ""
                    )
                }
                try await client.putObjectTags(
                    key: object.key,
                    tags: draft.objectTags,
                    versionID: snapshot.head.versionID
                )
                var taggedSnapshot = snapshot
                taggedSnapshot.tags = draft.objectTags
                guard try await client.objectMatchesSnapshot(
                    key: object.key,
                    expected: taggedSnapshot
                ) else {
                    throw OSSServiceError(
                        statusCode: 0,
                        code: "ObjectChanged",
                        message: "标签已提交，但对象随后发生变化，请重新打开属性确认",
                        requestId: ""
                    )
                }
                snapshot = try await client.objectSnapshot(
                    key: object.key,
                    versionID: taggedSnapshot.head.versionID
                )
                loadedSnapshot = snapshot
                original.tags = draft.tags
            }
            original = draft
            loadedSnapshot = snapshot
            onSaved()
            isSaving = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
            return false
        }
    }
}
