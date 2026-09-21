#!/usr/bin/env python3
"""Apply the .app resource lookup compatibility patch to the pinned Hub source.

Patching generated SwiftPM accessors is unreliable: replanning overwrites them.
Keep this patch explicit and fail if an upstream change needs review.
"""
from pathlib import Path

path = Path('.build/checkouts/swift-transformers/Sources/Hub/Hub.swift')
source = path.read_text()
marker = '// YAVR: resolve packaged tokenizer resources without a build-directory fallback.'
old = '        guard let url = Bundle.module.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {'
new = '''        // YAVR: resolve packaged tokenizer resources without a build-directory fallback.
        let resourceBundle: Bundle?
        if Bundle.main.bundleURL.pathExtension == "app" {
            resourceBundle = Bundle.main.resourceURL.flatMap {
                Bundle(url: $0.appendingPathComponent("swift-transformers_Hub.bundle"))
            }
        } else {
            resourceBundle = Bundle.module
        }
        guard let url = resourceBundle?.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {'''
if marker not in source:
    if source.count(old) != 1:
        raise SystemExit('Hub resource lookup changed upstream; review the compatibility patch')
    # SwiftPM checkouts mark source files read-only. Only this generated local
    # checkout copy is made writable; the patch is reapplied on fresh resolution.
    path.chmod(path.stat().st_mode | 0o200)
    path.write_text(source.replace(old, new))
    print('Prepared Hub resource lookup for a standalone macOS app')
