// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JMComic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JMComic",
            path: "Sources/JMComic",
            // 让二进制如实记录编译用的 SDK 版本（27.0）。
            // SwiftPM 默认会把 "最低系统" 写进 LC_BUILD_VERSION 的 sdk 字段，
            // 与真实使用的 SDK 不符（macOS 会据此提示"为旧版本构建"）。
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", "14.0",
                    "-Xlinker", "27.0",
                ])
            ]
        )
    ]
)
