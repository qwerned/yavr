#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-app.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def bundle(path, marker):
    (path / 'Contents').mkdir(parents=True)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': installer.NEW_ID, 'CFBundleExecutable': 'YAVR'}))
    (path / 'Contents/version').write_text(marker)
    return path


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = bundle(self.root / 'source.app', 'new')
        self.target = bundle(self.root / 'YAVR.app', 'previous')
        self.backups = self.root / 'backups'

    def test_foreign_bundle_rejected_before_stop(self):
        (self.target / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'other.app', 'CFBundleExecutable': 'YAVR'}))
        with patch.object(installer, 'validate'), patch.object(installer, 'stop') as stop:
            with self.assertRaises(ValueError):
                installer.install(self.source, self.target, self.backups, False)
            stop.assert_not_called()
        self.assertTrue(self.target.exists())

    def test_wrong_executable_rejected(self):
        (self.target / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': installer.NEW_ID, 'CFBundleExecutable': 'Other'}))
        with self.assertRaises(ValueError):
            installer.metadata(self.target)

    def test_success_discards_previous_app(self):
        with patch.object(installer, 'validate'), patch.object(installer, 'read_preferences', return_value=None), \
             patch.object(installer, 'stop') as stop:
            backup = installer.install(self.source, self.target, self.backups, False)
        stop.assert_called_once_with(self.target, 'YAVR')
        self.assertEqual((self.target / 'Contents/version').read_text(), 'new')
        self.assertFalse((backup / 'YAVR.app').exists())
        self.assertEqual(list(self.root.glob('.yavr-install-*')), [])

    def test_preferences_are_backed_up_without_modification(self):
        current = {'language': 'en', 'useDictionary': False}
        with patch.object(installer, 'validate'), patch.object(installer, 'read_preferences', return_value=current), \
             patch.object(installer, 'stop'):
            backup = installer.install(self.source, self.target, self.backups, False)
        saved = plistlib.loads((backup / 'current-preferences.plist').read_bytes())
        self.assertEqual(saved, current)

    def test_failed_validation_restores_previous_app(self):
        def validate(path):
            if path == self.target:
                raise RuntimeError('injected final validation failure')
        with patch.object(installer, 'validate', side_effect=validate), patch.object(installer, 'stop'), \
             patch.object(installer, 'read_preferences', return_value=None):
            with self.assertRaises(RuntimeError):
                installer.install(self.source, self.target, self.backups, False)
        self.assertEqual((self.target / 'Contents/version').read_text(), 'previous')
        self.assertEqual(list(self.root.glob('.yavr-install-*')), [])


if __name__ == '__main__':
    unittest.main()
