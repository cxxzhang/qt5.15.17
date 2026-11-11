# Change: 重构 Linux 构建与发布

## Why
现有 Linux 流水线直接在 Ubuntu 22.04 上使用 GCC 构建，无法保证产物兼容 Ubuntu 18.04；发布前未显式检查 strip 和 ELF 运行依赖，也缺少 LoongArch64、MIPS64EL 目标。所有平台同时构建，不利于优先验证 Linux 并节省 CI 资源。

## What Changes
- Linux 使用 Ubuntu 18.04 构建环境、固定版本 Clang 与 libstdc++，x64、ARM64 的 glibc 上限为 2.27；不升级宿主或目标 glibc 来适配构建工具。
- 新增 LoongArch64、MIPS64EL 交叉构建，参考只读仓库 `E:\YooDeskGroup\desk` 的下载校验、工具链隔离及 QEMU 验证方法，不直接复用其高版本 LoongArch sysroot。
- 分别确定各目标架构的最低可用 sysroot、ABI 和 glibc 上限；在通过验证之前不宣称支持某个发行版。
- 将 C++20 能力验证与 Qt 自身的编译标准分开；选择兼容旧 glibc 的现代 Clang/libstdc++，提供消费 Qt SDK 的 C++20 样例验证。
- 汇总 Linux 构建逻辑，隔离架构、编译器与 debug/release 输出；发布前使用匹配目标架构的 strip，调试符号单独归档。
- 增加 ELF 架构、符号版本、运行依赖检查及运行测试；实际随包发布的 C++ 运行库一并检查。
- 支持仅构建 Linux；全平台模式中 Windows/macOS 在全部必要 Linux 检查成功后启动，失败时不发布不完整版本。

## Impact
- Affected specs: linux-build-release（新增）。
- Affected code: `.github/workflows/BuildBinaries.yml`、四个 Linux 一键构建脚本、新增构建环境/交叉工具链/打包与验证脚本及使用文档。
- YY-Thunks 二进制更新作为独立提交，不包含在 Linux 重构中。
- 当前仅提交提案，批准后实现；工具链版本与下载 SHA256 在实现验证后固定。
