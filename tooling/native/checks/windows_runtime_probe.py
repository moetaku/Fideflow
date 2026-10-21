"""Load the staged DLLs with the Windows loader and check the real native ABI."""
import ctypes
import json
import os
import pathlib
import sys
from sqlite_probe import probe_sqlite

directory = pathlib.Path(sys.argv[1]).resolve()
with os.add_dll_directory(str(directory)):
    codec_path = next(directory.glob("avcodec-*.dll"))
    codec = ctypes.CDLL(str(codec_path))
    codec.avcodec_configuration.restype = ctypes.c_char_p
    configuration = codec.avcodec_configuration().decode()
    assert "--disable-openssl" in configuration, configuration
    assert "--disable-network" in configuration, configuration
    format_lib = ctypes.CDLL(str(next(directory.glob("avformat-*.dll"))))
    format_lib.avio_enum_protocols.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_int]
    format_lib.avio_enum_protocols.restype = ctypes.c_char_p
    cursor = ctypes.c_void_p()
    protocols = set()
    while protocol := format_lib.avio_enum_protocols(ctypes.byref(cursor), 0):
        protocols.add(protocol.decode())
    assert protocols == {"file", "pipe"}, protocols
    library = ctypes.CDLL(str(directory / "ff_media_core.dll"))

    class OwnedBytes(ctypes.Structure):
        _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_size_t)]

    library.ff_media_core_abi_version.restype = ctypes.c_uint32
    library.ff_media_core_capabilities_json.restype = OwnedBytes
    library.ff_owned_bytes_free.argtypes = [OwnedBytes]
    library.ff_player_new.restype = ctypes.c_void_p
    library.ff_player_free.argtypes = [ctypes.c_void_p]
    assert library.ff_media_core_abi_version() == 3
    owned = library.ff_media_core_capabilities_json()
    try:
        capabilities = json.loads(ctypes.string_at(owned.data, owned.length))
    finally:
        library.ff_owned_bytes_free(owned)
    assert capabilities["decoder"]["available"], capabilities
    assert capabilities["output"]["deviceSelection"], capabilities
    assert capabilities["sourceSchemes"] == ["file", "ffinput"], capabilities
    player = library.ff_player_new()
    assert player, "create native player"
    library.ff_player_free(player)
    manifest = json.loads((directory / "sources.manifest.json").read_text(encoding="utf-8-sig"))
    sqlite = probe_sqlite(directory / "sqlite3.dll", manifest["platforms"]["windows"]["sqlite"]["version"])
    assert not list(directory.glob("*ssl*.dll")), "OpenSSL DLL packaged"
    assert not list(directory.glob("*crypto*.dll")), "OpenSSL crypto DLL packaged"
    assert not (directory / "ssl").exists(), "obsolete CA directory packaged"
    print(json.dumps({"probe": "windows-runtime", "abi": 3, "decoder": True,
                      "sqlite": sqlite, "protocols": sorted(protocols), "openssl": False, "failures": []}))
