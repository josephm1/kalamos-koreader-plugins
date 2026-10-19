#!/usr/bin/env python3
"""Generate original EPUBs exercising nested TOCs, spine cuts and final pages."""
from pathlib import Path
import sys
from zipfile import ZipFile, ZIP_DEFLATED

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
container = '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
def html(body):
    return '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>TOC fixture</title></head><body>' + body + '</body></html>'
def create(name, files, nav, version=3):
    manifest = ''.join(f'<item id="f{i}" href="{p}" media-type="application/xhtml+xml"/>' for i,p in enumerate(files))
    if version == 3:
        manifest += '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        navigation = html('<nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc">' + nav + '</nav>')
        nav_name='nav.xhtml'; spine_attr=''
    else:
        manifest += '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        navigation = '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>TOC fixture</text></docTitle><navMap>' + nav + '</navMap></ncx>'
        nav_name='toc.ncx'; spine_attr=' toc="ncx"'
    refs=''.join(f'<itemref idref="f{i}"/>' for i in range(len(files)))
    opf=f'<package xmlns="http://www.idpf.org/2007/opf" version="{version}.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">fixture-{name}</dc:identifier><dc:title>TOC fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-15T00:00:00Z</meta></metadata><manifest>{manifest}</manifest><spine{spine_attr}>{refs}</spine></package>'
    with ZipFile(out/name,'w',compression=ZIP_DEFLATED) as z:
        z.writestr('mimetype','application/epub+zip',compress_type=0)
        z.writestr('META-INF/container.xml',container)
        z.writestr('EPUB/content.opf',opf)
        z.writestr('EPUB/'+nav_name,navigation)
        for path,content in files.items(): z.writestr('EPUB/'+path,content)
long_tail=''.join('<p>Final chapter paragraph %d. Original test prose for page layout.</p>'%i for i in range(100))
body='<p>BEFORE_TOC_FRONT_MATTER.</p><h1 id="one">Chapter One</h1><p>ONE_ONLY.</p><h2 id="a">Section A</h2><p>A_ONLY café.</p><h2 id="b">Section B</h2><p>B_ONLY.</p><h1 id="two">Chapter Two</h1><p>TWO_ONLY.</p><h2 id="c">Section C</h2><p>C_ONLY.</p><h1 id="three">Chapter Three</h1><p>THREE_ONLY.</p>'+long_tail+'<p>FINAL_END café Ελληνικά 中文！</p>'
nav='<ol><li><a href="book.xhtml#one">Chapter One</a><ol><li><a href="book.xhtml#a">Section A</a></li><li><a href="book.xhtml#b">Section B</a></li></ol></li><li><a href="book.xhtml#two">Chapter Two</a><ol><li><a href="book.xhtml#c">Section C</a></li></ol></li><li><a href="book.xhtml#three">Chapter Three</a></li></ol>'
create('nested.epub',{'book.xhtml':html(body)},nav)
files={'first.xhtml':html('<h1 id="one">Chapter One</h1><p>SPINE_ONE_ONLY.</p>'), 'second.xhtml':html('<p>CHAPTER_ONE_CONTINUED.</p><h1 id="two">Chapter Two</h1><p>SPINE_TWO_ONLY.</p><p>SPLIT_FINAL_END!</p>')}
nav='<navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="first.xhtml#one"/></navPoint><navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="second.xhtml#two"/></navPoint>'
create('split.epub',files,nav,2)
create('single.epub',{'book.xhtml':html('<h1 id="one">Only Chapter</h1><p>SINGLE_START.</p>'+long_tail+'<p>SINGLE_FINAL_END！</p>')},'<ol><li><a href="book.xhtml#one">Only Chapter</a></li></ol>')
create('no-toc.epub',{'book.xhtml':html('<p>UNTABLED_START.</p><p>Entire short text.</p><p>UNTABLED_END！</p>')},'<ol></ol>')
large='<p>LARGE_START.</p>'+('<p>'+('Original prose for large sharing fixture. '*25)+'</p>')*4400+'<p>LARGE_FINAL_END！</p>'
create('large.epub',{'book.xhtml':html(large)},'<ol></ol>')
print('Created 5 original EPUB fixtures in',out)
