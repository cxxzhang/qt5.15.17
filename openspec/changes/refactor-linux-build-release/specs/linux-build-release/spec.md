## ADDED Requirements

### Requirement: 固定旧 glibc 基线
系统 SHALL 使用固定版本 Clang 与 libstdc++ 构建 Linux SDK。x64、ARM64、MIPS64EL 的运行 glibc 要求不得超过 2.17；龙芯旧世界和新世界分别构建，旧世界不得超过 2.28，新世界按用户 2026-11-11 授权的后备方案不得超过 2.36。不得擅自升级基线或修改 ELF 版本元数据来通过验收。

#### Scenario: 原生目标兼容旧系统
- **WHEN** 构建 x64、ARM64 或 MIPS64EL 产物
- **THEN** 所有发布 ELF 的 glibc 版本需求均不超过 2.17，并在对应旧系统环境完成运行验证。

#### Scenario: 独立交叉目标基线
- **WHEN** 构建 LoongArch64 旧世界或新世界
- **THEN** 系统分别使用固定且经校验的工具链与目标 sysroot，检查对应 ELF ABI、加载器及旧世界 glibc 2.28、新世界 glibc 2.36 上限，并执行实际目标运行探针。

### Requirement: 低版本 GNU 运行库与编译器互操作
系统 SHALL 优先复用各目标基准系统的旧版 libstdc++/libgcc 和 GNU 头文件，不得为了额外的 C++20 功能抬高运行库要求。C++20 消费能力不再是验收条件（用户 2026-11-11 明确取消）。Qt 仍由 Clang 编译。

#### Scenario: 旧系统运行库满足 SDK
- **WHEN** 一个目标 SDK 准备发布
- **THEN** 记录并检查实际需要的 GLIBCXX、CXXABI、GCC 和 GLIBC 符号，验证基准系统提供的运行库能解析全部依赖，不能仅通过随包携带新版 libstdc++ 宣称兼容旧系统。

#### Scenario: 较新编译器消费已有 Qt 库
- **WHEN** 使用 Clang 或 GCC 编译消费程序
- **THEN** 使用匹配目标 ABI 的 GNU 支持文件链接同一份 Qt SDK，并运行 GUI/QML/字体/TLS 消费样例，记录实际测试的编译器版本。不能保证未知未来编译器，或使用新标准库 API 的业务程序仍能在旧系统运行。

### Requirement: 发布前剥离与审计
系统 SHALL 在上传 Linux 产物前使用对应目标工具提取调试符号、执行 strip 并检查 ELF 运行依赖，保留 SDK 链接所需符号。

#### Scenario: 发布 SDK 与符号包
- **WHEN** 一个 release 或 debug 构建准备上传
- **THEN** 运行产物已移除调试信息、关联独立符号文件，SDK 仍可链接应用，且架构、符号版本和依赖审计全部成功。

### Requirement: Linux 优先执行
系统 SHALL 默认支持仅执行 Linux 构建，全平台模式 SHALL 在必要 Linux 任务全部成功后才启动其他平台。

#### Scenario: Linux-only 发布
- **WHEN** 用户选择仅构建 Linux
- **THEN** Windows/macOS 不执行，Linux 全部成功且检查通过后可发布其产物和符号包。

#### Scenario: Linux 失败阻止后续构建
- **WHEN** 全平台模式中任一必要 Linux 任务失败
- **THEN** Windows/macOS 不启动，且不发布不完整版本。
