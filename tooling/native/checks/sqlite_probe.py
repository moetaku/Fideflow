"""Verify the actual Windows SQLite DLL, independently of Python's own SQLite."""
import ctypes
import json
import pathlib
import sys


def probe_sqlite(path, expected_version):
    library = ctypes.CDLL(str(pathlib.Path(path).resolve()))
    library.sqlite3_libversion.restype = ctypes.c_char_p
    version = library.sqlite3_libversion().decode()
    if version != expected_version:
        raise RuntimeError(f"SQLite version mismatch: {version}, expected {expected_version}")
    library.sqlite3_compileoption_used.argtypes = [ctypes.c_char_p]
    library.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    library.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p,
                                   ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
    library.sqlite3_close.argtypes = [ctypes.c_void_p]
    library.sqlite3_free.argtypes = [ctypes.c_void_p]
    database = ctypes.c_void_p()
    try:
        if library.sqlite3_open(b":memory:", ctypes.byref(database)) != 0:
            raise RuntimeError("SQLite could not open an in-memory database")
        error = ctypes.c_char_p()
        result = library.sqlite3_exec(
            database, b"CREATE TABLE probe (id INTEGER PRIMARY KEY, value TEXT); "
            b"BEGIN; INSERT INTO probe VALUES (1, 'ok'); COMMIT; SELECT * FROM probe;",
            None, None, ctypes.byref(error))
        if result != 0:
            message = error.value.decode() if error.value else str(result)
            library.sqlite3_free(ctypes.cast(error, ctypes.c_void_p))
            raise RuntimeError(f"SQLite SQL probe failed: {message}")
    finally:
        if database.value:
            library.sqlite3_close(database)
    return {"version": version,
            "fts5": bool(library.sqlite3_compileoption_used(b"ENABLE_FTS5")),
            "rtree": bool(library.sqlite3_compileoption_used(b"ENABLE_RTREE"))}


if __name__ == "__main__":
    print(json.dumps({"probe": "sqlite", **probe_sqlite(sys.argv[1], sys.argv[2])}))
