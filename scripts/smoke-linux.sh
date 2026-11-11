#!/usr/bin/env bash
set -euo pipefail
sdk="$1"
work="$2"
qmake="$sdk/bin/qmake"
[[ -z "${QT_CROSS_QEMU:-}" ]] || qmake="$sdk/host/bin/qmake"
mkdir -p "$work"
cat >"$work/main.cpp" <<'EOF'
#include <QtCore/QString>
#include <QtGui/QGuiApplication>
#include <QtGui/QFontDatabase>
#include <QtNetwork/QSslSocket>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlEngine>
#include <QtCore/QScopedPointer>
#include <algorithm>
#include <concepts>
#include <coroutine>
#include <exception>
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
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData("import QtQml 2.0\nQtObject { property int answer: 6 * 7 }", QUrl());
    QScopedPointer<QObject> object(component.create());
    return !(QString::number(result) == QStringLiteral("42") && QSslSocket::supportsSsl()
             && object && object->property("answer").toInt() == 42
             && !QFontDatabase().families().isEmpty());
}
EOF
cat >"$work/smoke.pro" <<'EOF'
QT += core gui network qml
TEMPLATE = app
TARGET = smoke
CONFIG += console c++2a
CONFIG -= app_bundle
SOURCES += main.cpp
EOF
(
  cd "$work"
  # Exercise the installed qmake/mkspecs and SDK relocation, not only
  # compilation with manually supplied include/library search paths.
  env -u LD_LIBRARY_PATH "$qmake" smoke.pro \
    "QMAKE_CC=${CC:-clang}" "QMAKE_CXX=${CXX:-clang++}" \
    "QMAKE_LINK=${CXX:-clang++}" "QMAKE_LFLAGS+=-Wl,-rpath,$sdk/lib"
  make -j2
)
if [[ -n "${QT_CROSS_QEMU:-}" ]]; then
  env -u LD_LIBRARY_PATH QT_QPA_PLATFORM=offscreen QML2_IMPORT_PATH="$sdk/qml" \
    "$QT_CROSS_QEMU" -L "${QT_CROSS_SYSROOT:?target sysroot required}" "$work/smoke"
else
  env -u LD_LIBRARY_PATH QT_QPA_PLATFORM=offscreen QML2_IMPORT_PATH="$sdk/qml" "$work/smoke"
fi
