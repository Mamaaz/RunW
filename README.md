# RunW

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-blue" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" />
  <img src="https://img.shields.io/badge/License-MIT-green" />
</p>

**RunW** 是一款 macOS 应用级代理管理工具，让你轻松控制哪些应用走代理。

## ✨ 功能特点

- 🖱️ **拖拽添加** - 直接从 Finder 拖入 .app 文件
- 🎯 **精准控制** - 为每个应用设置代理/直连/拒绝规则
- 🔄 **Surge 集成** - 通过 HTTP API 自动同步规则到 Surge
- 🎨 **简洁界面** - 原生 SwiftUI，macOS 风格

## 📸 截图

<!-- TODO: 添加截图 -->

## 🚀 使用方法

### 前置要求

- macOS 14.0+
- [Surge](https://nssurge.com/) 已安装并开启 HTTP API

### 快速开始

1. 下载并运行 RunW
2. 确保 Surge 已开启 HTTP API（设置 → HTTP API）
3. 点击「连接 Surge」
4. 拖入需要代理的应用
5. 点击「同步规则」

## 🔧 技术原理

RunW 通过 Surge HTTP API 管理 `PROCESS-NAME` 规则：

```ini
# 自动生成的规则示例
PROCESS-NAME,Claude,Proxy
PROCESS-NAME,ChatGPT,Proxy
PROCESS-NAME,Safari,DIRECT
```

> ⚠️ `PROCESS-NAME` 规则需要 Surge 开启**增强模式**才能生效

## 📋 开发计划

- [x] 拖拽添加应用
- [x] Surge HTTP API 集成
- [x] 规则同步
- [ ] 流量统计
- [ ] 独立 Network Extension（无需 Surge）

## 📄 License

MIT License © 2026 [Mamaaz](https://github.com/Mamaaz)
