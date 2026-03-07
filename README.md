# PassWall Installer Builder

通过 GitHub Actions 自动编译 [PassWall](https://github.com/Openwrt-Passwall/openwrt-passwall) 及其全部依赖，打包为 `.run` 自解压安装文件。

Automatically compiles PassWall and all dependencies via GitHub Actions into a self-extracting `.run` installer.

## 特性 | Features

- 从 OpenWrt SDK 交叉编译全部依赖（C/C++、Go、Rust、预编译）
- 生成自解压 `.run` 安装包，一键部署到 OpenWrt 设备
- 支持自定义 SDK 版本和架构
- 每次执行完整构建，无增量编译，确保产物一致性
- **Rust 编译优化**（并行代码生成、优化 RUSTFLAGS）
- 编译自动降级（并行 → 单线程）
- 适配 OpenWrt 25.12+ APK 包管理器
- 自动分析 luci-app-passwall 选择的功能包并本地编译 PassWall 相关组件
- 对缺失的系统依赖 APK 自动从官方 OpenWrt 源拉取并并入 `.run`
- 每日自动检查上游 PassWall 稳定版并在有新版本时自动触发构建

## 快速开始 | Quick Start

1. **Fork 仓库**
2. **配置 SDK** — 编辑 `config/openwrt-sdk.conf`，设置与目标设备匹配的 SDK 下载地址
3. **触发构建** — push tag 或手动触发 workflow
   ```bash
   git tag 26.2.6-1 && git push origin 26.2.6-1
   ```
4. **下载产物** — 在 Actions 或 Releases 页面下载 `.run` 文件
5. **安装到设备**
   ```bash
   scp passwall_*.run root@openwrt:/tmp/
   ssh root@openwrt 'cd /tmp && chmod +x passwall_*.run && ./passwall_*.run'
   /etc/init.d/passwall restart
   ```

## 项目结构 | Structure

```
├── .github/workflows/
│   ├── build-installer.yml    # 构建工作流（单文件多步骤）
│   └── sync-passwall-tag.yml  # 每日同步上游稳定版 tag
├── config/
│   └── openwrt-sdk.conf       # SDK URL 配置
├── scripts/
│   └── utils.sh               # 工具函数库（日志、重试、make 封装等）
├── payload/
│   └── install.sh             # 设备安装脚本
└── README.md
```

## 配置 | Configuration

### `config/openwrt-sdk.conf`

| 变量 Variable | 必填 Required | 说明 Description |
|---------------|---------------|------------------|
| `OPENWRT_SDK_URL` | ✅ | SDK 下载地址 |

### Workflow 手动触发参数 | Workflow Dispatch Inputs

手动触发 workflow 时无额外输入参数，工作流始终执行完整构建。

## 系统要求 | Requirements

- OpenWrt **25.12+**（APK 包管理器）
- SDK 架构必须与目标设备一致
- GitHub Actions runner（`ubuntu-latest`）

## 构建流程 | Build Pipeline

```
build-installer.yml (single file, multi-step)
  → Setup Environment → Install Toolchains (Go/Rust) → Setup SDK
  → Configure Feeds & Patches → Compile Packages → Collect APKs
  → Build .run Installer → Upload & Release
```

所有构建逻辑内联在 `build-installer.yml` 工作流的各个步骤中，共享函数通过 `scripts/utils.sh` 提供。

工作流会从 `luci-app-passwall` 的 Makefile 自动分析已启用的功能开关，生成 PassWall 根包列表。本地优先编译 `openwrt-passwall-packages` 中的相关组件；对递归依赖闭包里缺失的系统 APK，再从与 SDK 同版本同架构的官方 OpenWrt 源拉取并打包进 `.run`。

## 性能优化 | Performance

### Rust 编译加速

自动应用以下优化以加快 Rust 组件编译：

- **增量编译**: 禁用 `CARGO_INCREMENTAL=0`，避免生成无用增量产物占用磁盘
- **并行代码生成**: 默认 `-C codegen-units=8`，在编译时间与运行时性能间平衡
- **LTO 可选**: 默认关闭 `-C lto`，避免与 `embed-bitcode=no` 冲突，可通过 `RUST_LTO_MODE=thin/fat` 显式开启
- **优化级别**: 默认 `-C opt-level=3`，提升运行时性能
- **减少调试信息**: `CARGO_PROFILE_RELEASE_DEBUG=0` 加速编译和链接

由于每次构建均为全新流程（无 Build Cache），增量编译已禁用；并行代码生成可减少 Rust 组件的编译时间。

## 常见问题 | FAQ

### 为什么 shadow-tls 体积不大却编译很久？

- shadow-tls 本身代码量不多，但依赖链很重：主要依赖 `ring`，而 `ring` 会内置构建 BoringSSL/汇编优化代码，跨架构交叉编译时会完整编译一遍。
- Rust 交叉编译会同时构建目标架构的标准库和所有依赖的 release 版本，首次构建需要下载/编译完整的 crate 栈。
- 本仓库启用了并行代码生成（`-C codegen-units=8`）并禁用了增量编译（每次均为全新构建，无缓存复用）。Rust 组件（尤其是 shadow-tls、shadowsocks-rust）首次编译耗时较长属正常现象。

### 如何更换目标架构？

修改 `config/openwrt-sdk.conf` 中的 `OPENWRT_SDK_URL`，使用与目标设备匹配的 SDK。例如 aarch64 设备使用 `aarch64_cortex-a53` 对应的 SDK。

### xray-plugin 编译失败？

xray-plugin 可能因为其依赖 `github.com/sagernet/sing` 与较新版本的 Go（如 Go 1.25+）不兼容而编译失败，报错类似 `invalid reference to net.errNoSuchInterface`。这是上游依赖兼容性问题，需要等待 [openwrt-passwall-packages](https://github.com/Openwrt-Passwall/openwrt-passwall-packages) 更新 xray-plugin 或其依赖版本后才能解决。xray-plugin 编译失败不影响其他包的正常构建。

## License

遵循上游仓库 LICENSE。感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)。
