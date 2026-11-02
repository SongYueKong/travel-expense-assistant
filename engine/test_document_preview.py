import hashlib
from pathlib import Path
import tempfile
import unittest
from PIL import Image
from reportlab.pdfgen import canvas
from document_preview import preview_pdf


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'invoice.pdf'
        c = canvas.Canvas(str(self.source), pagesize=(3000, 2000))
        c.drawString(30, 1800, 'FIRST PAGE')
        c.showPage()
        c.drawString(30, 1800, 'SECOND PAGE')
        c.save()

    def tearDown(self):
        self.temp.cleanup()

    def test_multi_page_preview_is_bounded_cached_and_read_only(self):
        original = hashlib.sha256(self.source.read_bytes()).hexdigest()
        result = preview_pdf(str(self.source), str(self.root / 'cache'))
        self.assertEqual(result['pages'], 2)
        self.assertEqual(result['pageIndex'], 0)
        self.assertIn('FIRST PAGE', result['text'])
        self.assertIn('SECOND PAGE', result['text'])
        with Image.open(result['path']) as image:
            self.assertLessEqual(max(image.size), 1600)
            self.assertGreater(min(image.size), 0)
        modified = Path(result['path']).stat().st_mtime_ns
        again = preview_pdf(str(self.source), str(self.root / 'cache'))
        self.assertEqual(again['path'], result['path'])
        self.assertEqual(Path(result['path']).stat().st_mtime_ns, modified)
        second = preview_pdf(str(self.source), str(self.root / 'cache'), 1)
        self.assertNotEqual(second['path'], result['path'])
        self.assertEqual(second['pageIndex'], 1)
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), original)

    def test_invalid_page_does_not_create_cache(self):
        for index in [-1, 2, True, '0']:
            with self.subTest(index=index), self.assertRaises(ValueError):
                preview_pdf(str(self.source), str(self.root / 'cache'), index)
        self.assertFalse((self.root / 'cache').exists())

    def test_replaced_pdf_does_not_reuse_stale_page(self):
        first = preview_pdf(str(self.source), str(self.root / 'cache'))
        c = canvas.Canvas(str(self.source))
        c.drawString(30, 700, 'REPLACEMENT')
        c.save()
        second = preview_pdf(str(self.source), str(self.root / 'cache'))
        self.assertNotEqual(first['path'], second['path'])
        self.assertIn('REPLACEMENT', second['text'])


if __name__ == '__main__':
    unittest.main()
