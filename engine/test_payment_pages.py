from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image
from reportlab.lib.units import mm
from payment_pages import build_payment_pages
from payment_pages import resolve_payment_layout
from reportlab.lib.pagesizes import A4, landscape


class PaymentLayoutTests(unittest.TestCase):
    def test_custom_grids_preserve_page_bounds_aspect_order_and_tail_size(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            files = [root/'phone.png', root/'wide.png']
            for file, size in zip(files, [(300,650), (650,300)]):
                Image.new('RGB', size, 'white').save(file)
            for orientation in ['portrait', 'landscape']:
                for rows, columns in [(1,1),(1,4),(3,2),(4,3),(8,8)]:
                    per_page = rows * columns
                    pictures = [{'path': str(files[(i if i < per_page else 0)%2]), 'number': f'{i+1:03d}'} for i in range(per_page+1)]
                    width, height = landscape(A4) if orientation == 'landscape' else A4
                    for draft in [False, True]:
                        with self.subTest(orientation=orientation,rows=rows,columns=columns,draft=draft), patch('payment_pages.canvas.Canvas') as factory:
                            build_payment_pages(pictures, root/'out.pdf', draft, {'orientation':orientation, 'rows':rows, 'columns':columns})
                            self.assertEqual(factory.call_args.kwargs['pagesize'], (width,height))
                            page = factory.return_value
                            self.assertEqual(page.showPage.call_count, 1)
                            self.assertEqual([c.args[-1] for c in page.drawCentredString.call_args_list], [p['number'] for p in pictures])
                            draws = page.drawInlineImage.call_args_list
                            boxes = []
                            for i, call in enumerate(draws):
                                image,x,y,w,h = call.args
                                self.assertAlmostEqual(w/h, image.width/image.height)
                                self.assertGreaterEqual(x, 6*mm-0.01)
                                self.assertGreaterEqual(y, 6*mm)
                                self.assertLessEqual(x+w, width-6*mm+0.01)
                                self.assertLessEqual(y+h, height-(13 if draft else 6)*mm+0.01)
                                self.assertGreaterEqual(page.drawCentredString.call_args_list[i].args[1], 6*mm)
                                if i % per_page == 0: boxes = []
                                for a,b,c,d in boxes:
                                    self.assertTrue(x+w<=a+0.01 or a+c<=x+0.01 or y+h<=b+0.01 or b+d<=y+0.01)
                                boxes.append((x,y,w,h))
                            # 尾页首图与满页同一张图使用完全相同的格子。
                            first, last = draws[0].args, draws[-1].args
                            for a,b in zip(first[1:],last[1:]): self.assertAlmostEqual(a,b)

    def test_invalid_layout_rejected_before_creating_pdf(self):
        for layout in [{}, [], 'portrait', {'orientation':'portrait','rows':True,'columns':2},
                       {'orientation':'portrait','rows':2.0,'columns':2},
                       {'orientation':'landscape','rows':0,'columns':4},
                       {'orientation':'landscape','rows':2,'columns':9},
                       {'orientation':'square','rows':2,'columns':4}]:
            with self.subTest(layout=layout), patch('payment_pages.canvas.Canvas') as factory:
                with self.assertRaises(ValueError): build_payment_pages([], 'unused.pdf', layout=layout)
                factory.assert_not_called()
        self.assertEqual(resolve_payment_layout()[1:], (2,4))

    def test_complete_and_partial_pages_preserve_images_numbers_and_print_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            sizes=[(1272,2772),(1400,700),(600,1800)]
            paths=[]
            for i,size in enumerate(sizes):
                file=root/f'{i}.png';Image.new('RGB',size,'white').save(file);paths.append(file)
            for count in [1,2,3,4,5,8,9,10,16]:
                for draft in [False,True]:
                    pictures=[{'number':f'{i+1:03d}','path':str(paths[i%3])} for i in range(count)]
                    with self.subTest(count=count,draft=draft),patch('payment_pages.canvas.Canvas') as factory:
                        build_payment_pages(pictures,root/'output.pdf',draft)
                        page=factory.return_value
                        draws=page.drawInlineImage.call_args_list
                        self.assertEqual(len(draws),count)
                        self.assertEqual([call.args[-1] for call in page.drawCentredString.call_args_list],[p['number'] for p in pictures])
                        self.assertEqual(page.showPage.call_count,(count-1)//8)
                        boxes=[]
                        for index,call in enumerate(draws):
                            image,x,y,w,h=call.args
                            self.assertEqual(image.size,sizes[index%3])
                            self.assertAlmostEqual(w/h,image.width/image.height)
                            self.assertGreaterEqual(x,6*mm-0.01);self.assertGreaterEqual(y,6*mm)
                            self.assertLessEqual(x+w,291*mm+0.01);self.assertLessEqual(y+h,(204-(7 if draft else 0))*mm+0.01)
                            label=page.drawCentredString.call_args_list[index].args
                            self.assertGreaterEqual(label[1],6*mm)
                            if index%8==0:boxes=[]
                            for a,b,c,d in boxes:
                                self.assertTrue(x+w<=a+0.01 or a+c<=x+0.01 or y+h<=b+0.01 or b+d<=y+0.01)
                            boxes.append((x,y,w,h))

    def test_screenshot_size_is_identical_for_full_pages_and_all_partial_page_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);file=root/'phone.png';Image.new('RGB',(1272,2772),'white').save(file)
            for draft in [False,True]:
                expected=None
                for count in range(1,17):
                    pictures=[{'number':str(i),'path':str(file)} for i in range(count)]
                    with self.subTest(count=count,draft=draft),patch('payment_pages.canvas.Canvas') as factory:
                        build_payment_pages(pictures,root/'output.pdf',draft)
                        draws=factory.return_value.drawInlineImage.call_args_list
                        if expected is None:expected=draws[0].args[1:]
                        for index,call in enumerate(draws):
                            self.assertAlmostEqual(call.args[3],expected[2])
                            self.assertAlmostEqual(call.args[4],expected[3])
                            if index%8==0:
                                self.assertAlmostEqual(call.args[1],expected[0])
                                self.assertAlmostEqual(call.args[2],expected[1])

if __name__=='__main__':unittest.main()
