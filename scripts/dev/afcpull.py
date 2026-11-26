#!/usr/bin/env python3
"""List, pull and remove files in an iOS app's Documents folder over USB
(house_arrest + AFC through libimobiledevice via ctypes).

usage: afcpull.py BUNDLE_ID ls PATH
       afcpull.py BUNDLE_ID pull REMOTE_DIR LOCAL_DIR
       afcpull.py BUNDLE_ID rm PATH
       afcpull.py BUNDLE_ID put LOCAL_FILE REMOTE_PATH
       afcpull.py BUNDLE_ID mkdir PATH
"""
import ctypes
import os
import sys

lib = ctypes.CDLL("libimobiledevice.so.6")
c_void_pp = ctypes.POINTER(ctypes.c_void_p)

lib.idevice_new.argtypes = [c_void_pp, ctypes.c_char_p]
lib.house_arrest_client_start_service.argtypes = [ctypes.c_void_p, c_void_pp, ctypes.c_char_p]
lib.house_arrest_send_command.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lib.house_arrest_get_result.argtypes = [ctypes.c_void_p, c_void_pp]
lib.afc_client_new_from_house_arrest_client.argtypes = [ctypes.c_void_p, c_void_pp]
lib.afc_read_directory.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p))]
lib.afc_file_open.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_uint64)]
lib.afc_file_read.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
lib.afc_file_write.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
lib.afc_file_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
lib.afc_remove_path.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.afc_make_directory.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

AFC_FOPEN_RDONLY = 1
AFC_FOPEN_WRONLY = 3


def connect(bundle):
    dev = ctypes.c_void_p()
    if lib.idevice_new(ctypes.byref(dev), None) != 0:
        sys.exit("no device")
    ha = ctypes.c_void_p()
    if lib.house_arrest_client_start_service(dev, ctypes.byref(ha), b"afcpull") != 0:
        sys.exit("house_arrest failed")
    # VendContainer (whole sandbox) works for development-signed apps;
    # VendDocuments only exposes Documents.
    vend = os.environ.get("AFC_VEND", "VendDocuments").encode()
    if lib.house_arrest_send_command(ha, vend, bundle.encode()) != 0:
        sys.exit("send command failed")
    res = ctypes.c_void_p()
    lib.house_arrest_get_result(ha, ctypes.byref(res))
    afc = ctypes.c_void_p()
    if lib.afc_client_new_from_house_arrest_client(ha, ctypes.byref(afc)) != 0:
        sys.exit("afc failed (is UIFileSharingEnabled set and the bundle id right?)")
    return afc


def listdir(afc, path):
    out = ctypes.POINTER(ctypes.c_char_p)()
    if lib.afc_read_directory(afc, path.encode(), ctypes.byref(out)) != 0:
        return None
    names = []
    i = 0
    while out[i]:
        n = out[i].decode()
        if n not in (".", ".."):
            names.append(n)
        i += 1
    return names


def read_file(afc, path):
    h = ctypes.c_uint64()
    if lib.afc_file_open(afc, path.encode(), AFC_FOPEN_RDONLY, ctypes.byref(h)) != 0:
        return None
    chunks = []
    buf = ctypes.create_string_buffer(1 << 20)
    n = ctypes.c_uint32()
    while True:
        if lib.afc_file_read(afc, h, buf, 1 << 20, ctypes.byref(n)) != 0 or n.value == 0:
            break
        chunks.append(buf.raw[: n.value])
    lib.afc_file_close(afc, h)
    return b"".join(chunks)


def pull(afc, remote, local):
    os.makedirs(local, exist_ok=True)
    names = listdir(afc, remote) or []
    count = 0
    for name in names:
        rpath = remote.rstrip("/") + "/" + name
        sub = listdir(afc, rpath)
        if sub is not None and read_file(afc, rpath) is None:
            count += pull(afc, rpath, os.path.join(local, name))
            continue
        data = read_file(afc, rpath)
        if data is not None:
            with open(os.path.join(local, name), "wb") as f:
                f.write(data)
            count += 1
    return count


def main():
    bundle, cmd = sys.argv[1], sys.argv[2]
    afc = connect(bundle)
    if cmd == "ls":
        print("\n".join(listdir(afc, sys.argv[3]) or ["(empty or missing)"]))
    elif cmd == "pull":
        print("pulled", pull(afc, sys.argv[3], sys.argv[4]), "files")
    elif cmd == "rm":
        print("rm", lib.afc_remove_path(afc, sys.argv[3].encode()))
    elif cmd == "mkdir":
        print("mkdir", lib.afc_make_directory(afc, sys.argv[3].encode()))
    elif cmd == "put":
        data = open(sys.argv[3], "rb").read()
        h = ctypes.c_uint64()
        if lib.afc_file_open(afc, sys.argv[4].encode(), AFC_FOPEN_WRONLY, ctypes.byref(h)) != 0:
            sys.exit("open for write failed")
        n = ctypes.c_uint32()
        lib.afc_file_write(afc, h, data, len(data), ctypes.byref(n))
        lib.afc_file_close(afc, h)
        print("wrote", n.value)


if __name__ == "__main__":
    main()
