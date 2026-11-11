#!/usr/bin/env bash
set -euo pipefail
sdk="$1"
work="$2"
mkdir -p "$work"
cat >"$work/main.cpp" <<'EOF'
#include <QtCore/QString>
#include <QtGui/QGuiApplication>
#include <QtNetwork/QSslSocket>
#include <concepts>
#include <coroutine>
#include <ranges>
#include <span>

struct Done {
    struct promise_type {
        Done get_return_object() { return {}; }
        std::suspend_never initial_suspend() noexcept { return {}; }
        std::suspend_never final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { std::terminate(); }
    };
};
Done probe(std::integral auto value, int &result) {
    int values[]{value, value + 1};
    result = *std::ranges::find(std::span{values}, value + 1);
    co_return;
}
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    int result = 0;
    probe(41, result);
    return !(QString::number(result) == QStringLiteral("42") && QSslSocket::supportsSsl());
}
EOF
"${CXX:-clang++}" -std=c++20 -fPIC "$work/main.cpp" \
  -I"$sdk/include" -L"$sdk/lib" -Wl,-rpath,"$sdk/lib" \
  -lQt5Gui -lQt5Network -lQt5Core -o "$work/smoke"
env -u LD_LIBRARY_PATH QT_QPA_PLATFORM=offscreen "$work/smoke"
