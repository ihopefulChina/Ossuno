import Foundation

enum PathTemplate {
    static func expand(_ template: String, now: Date = .now, filename: String) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        let hour = String(format: "%02d", parts.hour ?? 0)
        let minute = String(format: "%02d", parts.minute ?? 0)
        let second = String(format: "%02d", parts.second ?? 0)
        // For folder uploads `filename` is a relative path such as
        // "Folder/sub/x.txt"; the {name}/{ext} tokens describe the leaf file.
        let leaf = lastComponent(filename)
        let name = (leaf as NSString).deletingPathExtension
        let ext = (leaf as NSString).pathExtension

        var result = template
        let replacements: [String: String] = [
            "{yyyy}": year,
            "{MM}": month,
            "{dd}": day,
            "{HH}": hour,
            "{mm}": minute,
            "{ss}": second,
            "{name}": name,
            "{ext}": ext,
            "{filename}": filename
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return sanitizeKey(result)
    }

    static func join(_ prefix: String, key: String) -> String {
        let head = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let tail = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if head.isEmpty { return tail }
        if tail.isEmpty { return head.isEmpty ? "" : head + "/" }
        return head + "/" + tail
    }

    static func lastComponent(_ key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? key
    }

    static func parentPrefix(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        var parts = trimmed.split(separator: "/").map(String.init)
        _ = parts.popLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    static func destinationKey(prefix: String, filename: String, applyTemplate: Bool, template: String) -> String {
        guard applyTemplate, prefix.isEmpty, !template.isEmpty else {
            return join(prefix, key: filename)
        }
        let extra = expand(template, filename: filename)
        // Templates that already name the object ({filename} / {name}) are the
        // full relative key. Date-only prefixes still get the filename appended.
        if template.contains("{filename}") || template.contains("{name}") {
            return extra
        }
        return join(extra, key: filename)
    }

    static func replacingLastComponent(_ path: String, with name: String) -> String {
        join(parentPrefix(path), key: name)
    }

    static func nestedRelative(rootName: String, rootPath: String, filePath: String) -> String {
        let root = (rootPath as NSString).standardizingPath
        let file = (filePath as NSString).standardizingPath
        var rel = file
        if file.hasPrefix(root) {
            rel = String(file.dropFirst(root.count))
        }
        while rel.hasPrefix("/") {
            rel = String(rel.dropFirst())
        }
        return join(rootName, key: rel)
    }

    static func relative(_ key: String, under prefix: String) -> String {
        if prefix.isEmpty { return key }
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return lastComponent(key)
    }

    static func crumbs(bucket: String, prefix: String) -> [(title: String, prefix: String)] {
        var items: [(String, String)] = [(bucket, "")]
        if prefix.isEmpty { return items }
        let parts = prefix.split(separator: "/").map(String.init)
        var running = ""
        for part in parts where !part.isEmpty {
            running += part + "/"
            items.append((part, running))
        }
        return items
    }

    static func sanitizeKey(_ key: String) -> String {
        var result = key
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
