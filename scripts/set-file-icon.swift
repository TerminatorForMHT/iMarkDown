import AppKit

// 用官方 NSWorkspace 接口给任意文件（这里用于 .dmg）挂自定义图标，
// 避免依赖已废弃的 Rez/SetFile 资源叉写法或 Finder 的 PICT 转换。
// 用法：swift set-file-icon.swift <图标图片> <目标文件>

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("用法：swift set-file-icon.swift <图标图片> <目标文件>\n".utf8))
    exit(2)
}
let iconPath = arguments[1]
let targetPath = arguments[2]
guard let image = NSImage(contentsOfFile: iconPath) else {
    FileHandle.standardError.write(Data("无法读取图标：\(iconPath)\n".utf8))
    exit(1)
}
guard FileManager.default.fileExists(atPath: targetPath) else {
    FileHandle.standardError.write(Data("目标文件不存在：\(targetPath)\n".utf8))
    exit(1)
}
guard NSWorkspace.shared.setIcon(image, forFile: targetPath, options: []) else {
    FileHandle.standardError.write(Data("设置图标失败：\(targetPath)\n".utf8))
    exit(1)
}

// SetFile -a C 在当前 Command Line Tools 下不生效，直接改 FinderInfo 的
// kHasCustomIcon 位（0x0400，位于第 8 字节），Finder 才会绘制自定义图标。
let finderInfoName = "com.apple.FinderInfo"
var info = [UInt8](repeating: 0, count: 32)
let readSize = getxattr(targetPath, finderInfoName, &info, info.count, 0, 0)
if readSize < 0 && errno != ENOENT {
    FileHandle.standardError.write(Data("读取 FinderInfo 失败：\(targetPath)\n".utf8))
    exit(1)
}
info[8] |= 0x04
let writeResult = info.withUnsafeBytes { buffer in
    setxattr(targetPath, finderInfoName, buffer.baseAddress, info.count, 0, 0)
}
guard writeResult == 0 else {
    FileHandle.standardError.write(Data("写入 FinderInfo 失败：\(targetPath)\n".utf8))
    exit(1)
}
