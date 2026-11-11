# Linux 构建与发布设计

## 基线与架构

| 目标 | 初始兼容目标 | 决策 |
| --- | --- | --- |
| x64 | Ubuntu 18.04 / glibc 2.27 | 原生 Ubuntu 18.04 容器构建 |
| ARM64 | Ubuntu 18.04 / glibc 2.27 | ARM64 runner 上原生容器构建 |
| MIPS64EL | 优先调查 2.27；已知参考为 Loongnix / glibc 2.28 | 明确 little-endian、n64、CPU 指令集后固定 sysroot |
| LoongArch64 | 选择可用的最低发行版基线，版本待调查 | 区分新旧世界 ABI、浮点 ABI、动态加载器及目标发行版；不复用 glibc 2.43 的参考依赖栈 |

Ubuntu 18.04 是构建宿主环境，不表示它存在 LoongArch64 目标发行版。跨架构产物的运行要求由目标 sysroot 决定。MIPS、龙芯的最终兼容范围必须在文档中单列，禁止统一声称兼容 glibc 2.27。

## 工具链与 C++20

使用 Clang 编译，统一 libstdc++；Qt 可以保留自身所需的 C++ 标准，业务样例按 C++20 编译。Clang 18 / GCC 13 libstdc++ 仅为原生目标候选，最终需验证宿主 glibc、目标支持与 Qt 5.15 头文件兼容性。C++20 验证至少覆盖 concepts、协程、span、ranges；所需功能清单及未支持功能写入文档，不承诺未经验证的完整标准覆盖。

编译器可使用经校验的兼容预构建包；若必须构建新版 libstdc++，使用旧目标 sysroot。显式固定 Clang 的 GCC 工具链搜索路径，避免混用不同版本的头文件和运行库。Clang/GCC 混合链接使用普通目标文件，不跨编译器使用 LTO。

区分宿主 qmake、moc 等工具与目标库。交叉构建中 pkg-config 只读取目标 sysroot。LoongArch Qt 5.15 架构识别、原子操作和 QtQml JIT 支持需先验证；如需禁用不受支持的 JIT，则记录具体功能限制，不默默降低能力。

## 打包与兼容性检查

Qt、静态 OpenSSL、插件及随包运行库全部使用对应目标基线构建。应用私有目录携带必要的 libstdc++/libgcc 运行库，配置工具程序的加载路径，文档说明 SDK 消费者的运行库部署要求；不携带或替换系统 glibc。

release/debug 产物均在上传前提取调试符号，执行目标架构的 strip --strip-unneeded，添加 debuglink，分别生成运行包和符号包。保留开发头文件、mkspecs、静态库所需的链接符号，不能通过 strip --strip-all 破坏 SDK。

验证使用 ELF 的版本需求记录，不把自身导出的 GLIBCXX 符号误判为 glibc 要求。检查每个发布 ELF（包括工具、插件及运行库）的架构、glibc 上限和 DT_NEEDED；审计 libstdc++/CXXABI 需求是否由部署运行库满足。原生目标在干净旧系统环境运行工具和 Qt GUI/网络/TLS 样例，交叉目标以 QEMU 验证工具链探针及可运行的 Qt 样例。QEMU 不代替目标机器的桌面和 GPU 验收。

## CI 与发布

workflow_dispatch 提供 linux/all 选择，默认 linux。Linux 矩阵覆盖四种架构及明确的构建变体；全平台模式的其他平台通过 needs 依赖 Linux 成功。Linux-only 模式无需等待跳过的平台即可汇总发布；全平台模式只在全部所选任务成功时发布。构建前的 checkout/upload 等 Actions 在较新宿主运行，旧容器只负责构建，避免 Actions Node 运行时要求影响基线。

固定工具链 URL、SHA256、镜像标识，按架构/版本/配置缓存，禁止失败后回退到未经验证的最新工具链。先触发 Linux-only 验证并修复，成功后才验证其他平台。

## 尚待实现阶段确认

- LoongArch 最低可用 sysroot、ABI 以及目标发行版范围。
- MIPS 是否存在满足目标运行系统、Clang 与 C++20 的更低基线组合。
- 兼容 Ubuntu 18.04 的现代 Clang/libstdc++ 获取方式及构建成本。
- 新增架构所需的 Qt 5.15 补丁、QML 功能限制和图形后端。
