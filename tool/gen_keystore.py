#!/usr/bin/env python3
"""生成 Android 发布签名用的 PKCS12 密钥库（本机无 JDK，用 cryptography 直出）。

输出：<目标目录>/yingshu-release.p12 + keystore-info.txt（密码/别名，别提交到仓库）
"""
from __future__ import annotations

import datetime as dt
import pathlib
import secrets
import string

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

TARGET = pathlib.Path(r"C:\Users\Administrator\Doubao\chats\2026-11-21\new-chat\.signing")
TARGET.mkdir(parents=True, exist_ok=True)

ALIAS = "yingshu"


def rand_password(length: int = 20) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def main() -> None:
    password = rand_password()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "YingShu CineHub"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "YingShu"),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Android Release"),
        x509.NameAttribute(NameOID.COUNTRY_NAME, "CN"),
    ])

    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=365 * 30))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )

    p12 = pkcs12.serialize_key_and_certificates(
        name=ALIAS.encode(),
        key=key,
        cert=cert,
        cas=None,
        encryption_algorithm=serialization.BestAvailableEncryption(password.encode()),
    )

    keystore = TARGET / "yingshu-release.p12"
    keystore.write_bytes(p12)

    info = TARGET / "keystore-info.txt"
    info.write_text(
        "别名(alias): {alias}\n"
        "密钥库密码(storePassword): {pwd}\n"
        "密钥密码(keyPassword): {pwd}\n"
        "文件: {path}\n"
        "SHA-256 指纹: {fp}\n".format(
            alias=ALIAS,
            pwd=password,
            path=keystore,
            fp=cert.fingerprint(hashes.SHA256()).hex(),
        ),
        encoding="utf-8",
    )
    print(f"生成 {keystore} ({len(p12)} bytes)，密码见 {info}")


if __name__ == "__main__":
    main()
