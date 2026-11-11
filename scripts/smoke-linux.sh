#!/usr/bin/env bash
set -euo pipefail
sdk="$1"
work="$2"
qmake="$sdk/bin/qmake"
[[ -z "${QT_CROSS_QEMU:-}" ]] || qmake="$sdk/host/bin/qmake"
mkdir -p "$work"
cp "$(dirname "${BASH_SOURCE[0]}")/smoke-tls/server.crt" "$work/"
cp "$(dirname "${BASH_SOURCE[0]}")/smoke-tls/server.key" "$work/"
cat >"$work/tls.qrc" <<'EOF'
<RCC><qresource prefix="/tls"><file>server.crt</file><file>server.key</file></qresource></RCC>
EOF
cat >"$work/main.cpp" <<'EOF'
#include <QtCore/QString>
#include <QtCore/QDebug>
#include <QtCore/QEventLoop>
#include <QtCore/QTimer>
#include <QtGui/QGuiApplication>
#include <QtGui/QFontDatabase>
#include <QtNetwork/QSslSocket>
#include <QtNetwork/QSslKey>
#include <QtNetwork/QTcpServer>
#include <QtNetwork/QHostAddress>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlEngine>
#include <QtCore/QScopedPointer>
#include <algorithm>
#include <exception>
#include <string>
#include <utility>
static_assert(__cplusplus >= 201703L, "The SDK consumer must use C++17 or later");

void probe(int value, int &result) {
    // C++17 language support does not require a new GNU standard library.
    auto [first, second] = std::make_pair(value, value + 1);
    result = std::max(first, second);
}
class TlsServer : public QTcpServer {
public:
    QSslSocket *peer = nullptr;
    QByteArray received;
protected:
    void incomingConnection(qintptr descriptor) override {
        peer = new QSslSocket(this);
        if (!peer->setSocketDescriptor(descriptor))
            return;
        peer->setLocalCertificate(QStringLiteral(":/tls/server.crt"));
        peer->setPrivateKey(QStringLiteral(":/tls/server.key"), QSsl::Rsa);
        peer->setProtocol(QSsl::TlsV1_2);
        connect(peer, &QSslSocket::readyRead, peer, [this] {
            received += peer->readAll();
            if (received == "qt-sdk-client")
                peer->write("qt-sdk-tls");
        });
        peer->startServerEncryption();
    }
};
bool tlsProbe() {
    TlsServer server;
    if (!server.listen(QHostAddress::LocalHost, 0))
        return false;
    QSslSocket client;
    // This public test fixture checks encryption, not CA trust or host identity.
    client.setPeerVerifyMode(QSslSocket::VerifyNone);
    client.setProtocol(QSsl::TlsV1_2);
    QEventLoop loop;
    QByteArray received;
    QObject::connect(&client, &QSslSocket::encrypted, &client, [&] {
        client.write("qt-sdk-client");
    });
    QObject::connect(&client, &QSslSocket::readyRead, &loop, [&] {
        received += client.readAll();
        if (received == "qt-sdk-tls")
            loop.quit();
    });
    QTimer::singleShot(15000, &loop, &QEventLoop::quit);
    client.connectToHostEncrypted(QStringLiteral("127.0.0.1"), server.serverPort());
    loop.exec();
    bool passed = client.isEncrypted() && server.peer && server.peer->isEncrypted()
                  && received == "qt-sdk-tls" && server.received == "qt-sdk-client";
    if (!passed)
        qWarning() << "Loopback TLS exchange failed:" << client.errorString();
    return passed;
}
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    const std::string message = "qt-sdk-standard-string";
    const bool stringsMatch = QString::fromStdString(message).toStdString() == message;
    const std::wstring wideMessage = L"qt-sdk-wide-string-\u4e2d\u6587-\U0001f642";
    const bool wideStringsMatch = QString::fromStdWString(wideMessage).toStdWString() == wideMessage
            && QString().toStdWString().empty();
    int result = 0;
    probe(41, result);
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData("import QtQml 2.0\nQtObject { property int answer: 6 * 7 }", QUrl());
    QScopedPointer<QObject> object(component.create());
    return !(stringsMatch && wideStringsMatch && QString::number(result) == QStringLiteral("42") && QSslSocket::supportsSsl() && tlsProbe()
             && QString::number(1.25, 'f', 2) == QStringLiteral("1.25")
             && object && object->property("answer").toInt() == 42
             && !QFontDatabase().families().isEmpty());
}
EOF
cat >"$work/smoke.pro" <<'EOF'
QT += core gui network qml
TEMPLATE = app
TARGET = smoke
CONFIG += console c++17
CONFIG -= app_bundle
SOURCES += main.cpp
RESOURCES += tls.qrc
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
  python3 "$(dirname "${BASH_SOURCE[0]}")/linux_cross_runtime.py" smoke \
    "${QT_CROSS_SYSROOT:?target sysroot required}" "$QT_CROSS_QEMU" "$work/smoke" --sdk "$sdk"
else
  env -u LD_LIBRARY_PATH QT_QPA_PLATFORM=offscreen QML2_IMPORT_PATH="$sdk/qml" "$work/smoke"
fi
