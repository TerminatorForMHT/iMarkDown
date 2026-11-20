import Foundation

enum EditorMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: return "源码"
        case .split: return "分栏"
        case .preview: return "预览"
        }
    }

    var symbol: String {
        switch self {
        case .source: return "square.and.pencil"
        case .split: return "rectangle.split.2x1"
        case .preview: return "doc.richtext"
        }
    }

    var shortcut: String {
        switch self {
        case .source: return "1"
        case .split: return "2"
        case .preview: return "3"
        }
    }
}

extension EditorMode: Equatable {}
