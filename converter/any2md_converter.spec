from PyInstaller.utils.hooks import collect_all, collect_data_files


datas, binaries, hiddenimports = collect_all("markitdown")
datas += collect_data_files("magika")

a = Analysis(
    ["worker.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "azure",
        "pydub",
        "speech_recognition",
        "youtube_transcript_api",
    ],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="any2md_converter",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=True,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    name="any2md_converter",
)
